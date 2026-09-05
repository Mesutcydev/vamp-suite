import CaptureEngine
import Combine
import Diagnostics
import Discovery
import EncodeEngine
import Foundation
import Permissions
import SharedModels
import SharedProtocol
import SharedUtilities
import TransportWebRTC
import os

/// Determines whether an incoming attachment belongs to the device that owns
/// the active session. The signed public-key fingerprint is the durable trust
/// identity; the UUID remains a fast path for legacy peers.
enum HostClientAttachmentIdentity {
    static func matches(
        activeClientID: UUID?,
        activeClientFingerprint: String?,
        candidate: SignalingPeer
    ) -> Bool {
        if let activeClientID, activeClientID == candidate.id {
            return true
        }

        let activeFingerprint = normalized(activeClientFingerprint)
        let candidateFingerprint = normalized(candidate.publicKeyFingerprint)
        guard PublicKeyFingerprint.isValid(activeFingerprint),
              PublicKeyFingerprint.isValid(candidateFingerprint) else {
            return false
        }
        return activeFingerprint == candidateFingerprint
    }

    static func matchesRevokedPeer(activeClientID: UUID?, activeClientFingerprint: String?, peer: TrustedPeer) -> Bool {
        if activeClientID == peer.id { return true }
        let active = normalized(activeClientFingerprint)
        let revoked = normalized(peer.fingerprint)
        return PublicKeyFingerprint.isValid(active) && PublicKeyFingerprint.isValid(revoked) && active == revoked
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}

/// Orchestrates the complete host session lifecycle:
///
/// 1. Start Bonjour advertising + signaling listener
/// 2. Accept incoming signaling connection from a client
/// 3. Run the trust gate for peer approval
/// 4. Exchange SDP offer/answer via signaling
/// 5. Prepare and start the capture → encode → transport pipeline
/// 6. Monitor connection state for teardown/reconnect
///
/// Owns the `SignalingWebRTCBridge` for this session and coordinates
/// between `HostStreamingCoordinator`, `HostInputCommandRouter`, and `PeerTrustGate`.
@MainActor
final class HostSessionCoordinator: ObservableObject {
    enum SessionPhase: String, Equatable {
        case idle
        case advertising
        case awaitingClient
        case signalingConnected
        case trustPending
        case negotiating
        case pipelineStarting
        case streaming
        case error
    }

    @Published private(set) var phase: SessionPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            connectionDebugger.record("phase", phase.rawValue)
        }
    }
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var connectedClientName: String?
    @Published private(set) var errorMessage: String?
    /// Non-nil only while an app window is actively captured. Vamp Sync uses
    /// this to distinguish an attached client from a real video stream.
    @Published private(set) var activeApplicationName: String?
    /// Stable device identity that owns `activeSessionID`. A reconnect from the same device may
    /// replace its stale transport, but a different device must not evict a healthy session.
    private var activeClientID: UUID?
    /// The cryptographic identity is authoritative. Older Mac clients used a
    /// random peer UUID on each launch, so ID-only replacement rejected the
    /// same paired Mac during the disconnect grace period.
    private var activeClientFingerprint: String?
    private var trustRevision: UInt64 = 0
    private var revokingFingerprints: Set<String> = []

    // Dependencies
    private let hostIdentity: HostIdentity
    private let captureEngine: any CaptureEngineProtocol
    private let encoderPipeline: any EncoderPipelineProtocol
    private let displayLayoutProvider: any DisplayLayoutProviding
    private let permissionService: any PermissionServiceProtocol
    private let webRTCSessionManager: any WebRTCSessionManaging
    private let peerTrustGate: PeerTrustGate
    private let streamingCoordinator: HostStreamingCoordinator
    private let inputCommandRouter: HostInputCommandRouter
    private let eventLogStore: any EventLogStoreProtocol
    private let signalingService: any SessionCoordinatorSignaling
    private let sessionModeController: HostSessionModeController
    private let performanceStateController: HostPerformanceStateController
    private let fileTransferManager: HostFileTransferManager
    private let productMode: HostProductMode
    /// Opens an ECIES-sealed session token (raw 32 bytes) with the host's
    /// identity-derived key-agreement key. `nil` when the host has no identity
    /// (legacy), in which case offers fall back to the plaintext token.
    private let sessionTokenUnsealer: ((Data) -> Data?)?
    #if os(macOS)
    var audioPipeline: HostAudioCapturePipeline?
    /// Extra displays streamed in parallel to the primary, keyed by display ID. The primary
    /// keeps the existing pipeline (wire displayID 0); these get wire IDs 1, 2, … in the
    /// order the client requested via SetActiveDisplays.
    private var secondaryStreamers: [String: SecondaryDisplayStreamer] = [:]
    #endif
    /// Returns the current host lock state. Set by HostAppEnvironment on macOS.
    /// Defaults to unlocked so non-macOS targets and tests work without wiring.
    var lockStateProvider: @Sendable () -> HostLockState = { .unlockedActiveSession }
    /// Publishes lock state changes. Set by HostAppEnvironment on macOS so the
    /// coordinator can push a `hostStatus` update to the client on every transition.
    var lockStatePublisher: AnyPublisher<HostLockState, Never>?
    private let ensureDiscoveryAdvertising: @MainActor @Sendable () async -> Void

    private var bridgeEventTask: Task<Void, Never>?
    private var connectionObserverTask: Task<Void, Never>?
    private var dataChannelObserverTask: Task<Void, Never>?
    private var disconnectGraceTask: Task<Void, Never>?
    private var clientActivityObserverTask: Task<Void, Never>?
    private var livenessWatchdogTask: Task<Void, Never>?
    private var captureStateObserverTask: Task<Void, Never>?
    private var captureFailureRestartAttempted = false
    /// Stamped on every inbound data-channel message; nil until the first one.
    /// Lock-backed and updated OFF the main actor on purpose: the client pings every 2 s,
    /// but a main-actor stamp freezes whenever the main thread is blocked — for
    /// example, an NSOpenPanel/NSSavePanel `.runModal()` or a synchronous operation
    /// causing a beachball — while pings keep arriving off-main. A frozen stamp makes
    /// the watchdog below tear down a perfectly live session. Keeping it off-main makes
    /// liveness immune to main-thread stalls.
    private let clientActivityLock = NSLock()
    private nonisolated(unsafe) var _lastClientActivityAt: Date?
    nonisolated private var lastClientActivityAt: Date? {
        get { clientActivityLock.lock(); defer { clientActivityLock.unlock() }; return _lastClientActivityAt }
        set { clientActivityLock.lock(); _lastClientActivityAt = newValue; clientActivityLock.unlock() }
    }
    /// Transient `.disconnected` events get this long to recover before teardown.
    /// Must exceed the client's LAN TCP retry budget (6 attempts, ~15.5 s of
    /// backoff in LANPeerConnection.scheduleReconnectIfNeeded) — with the old 8 s
    /// the host tore the session down while the client was still retrying, turning
    /// every brief Wi-Fi flap or app-switch into a full renegotiation.
    private let disconnectGraceSeconds: Double = 20.0
    /// No inbound client traffic for this long while streaming → client is gone.
    /// The client pings every 2 s, so a healthy session never goes quiet.
    /// Set well above a brief app-switch/lock on the client: iOS suspends the app
    /// (pings stop) but keeps the socket alive, and pings resume on foreground —
    /// the old 15 s killed sessions that would have resumed seamlessly.
    private let clientLivenessTimeoutSeconds: Double = 30.0
    private var displayLayoutObserverTask: Task<Void, Never>?
    private var pendingDisplayLayoutChangeTask: Task<Void, Never>?
    private var initialDataChannelRetryTask: Task<Void, Never>?
    private var adaptiveStreamingTask: Task<Void, Never>?
    private var lockStateObserver: AnyCancellable?
    private var isApplyingPerformanceProfile = false
    private var needsPerformanceProfileReapply = false
    private var latestObservedLayout: DisplayLayout?
    private var activeStreamDisplayRestartKey: DisplayRestartKey?
    private var requestedDynamicRange: StreamDynamicRange = .sdr
    private var hasPublishedInitialSessionState = false
    private var hasSentInitialDataChannelState = false
    /// The full host can serve either a remote-desktop client or a terminal
    /// client. Keep the negotiated session role separate from the host product
    /// so a terminal client never inherits video capabilities or permission
    /// requirements from Vamp Host.
    private var activeSessionIsTerminalOnly = false
    private let startupFirstFrameTimeoutSeconds: Double = 10.0
    private let initialDataChannelRetryAttempts = 80
    private let initialDataChannelRetryDelayMs: UInt64 = 250
    private let displayLayoutChangeDebounceMs: UInt64 = 250

    private struct DisplayRestartKey: Equatable {
        var displayID: String
        var logicalSize: DesktopSize
        var pixelSize: DesktopSize
        var scaleFactor: Double
        var rotation: Double
    }

    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "SessionCoordinator")
    /// Records connection-signal timeline; dumps a report on connection loss.
    private let connectionDebugger: ConnectionDebugger

    // MARK: - App Streaming
    /// Shared with the input service's layout provider: when a window is the stream target this
    /// holds the window's synthetic single-"display" layout so pointer input maps into the window.
    let streamWindowGeometry: StreamWindowGeometryStore
    #if os(macOS)
    let applicationRegistry = HostApplicationRegistry()
    /// The window currently streamed (nil ⇒ display streaming). Drives input geometry + loss detection.
    private var originalAppWindowBounds: [String: DesktopRect] = [:]
    var activeWindowTarget: WindowStreamTarget?
    /// Prevents the normal display-layout observer from racing a window capture restart/teardown.
    var isWindowStreamTransitioning = false
    /// Low-frequency task that keeps the window origin aligned for input and detects window loss.
    var windowTrackingTask: Task<Void, Never>?
    private var targetSwitchTask: Task<Void, Never>?
    private var applicationListSnapshot: [RemoteApplication] = []
    #endif

    init(
        hostIdentity: HostIdentity,
        captureEngine: any CaptureEngineProtocol,
        encoderPipeline: any EncoderPipelineProtocol,
        displayLayoutProvider: any DisplayLayoutProviding,
        permissionService: any PermissionServiceProtocol,
        webRTCSessionManager: any WebRTCSessionManaging,
        peerTrustGate: PeerTrustGate,
        streamingCoordinator: HostStreamingCoordinator,
        inputCommandRouter: HostInputCommandRouter,
        eventLogStore: any EventLogStoreProtocol,
        signalingService: any SessionCoordinatorSignaling,
        sessionModeController: HostSessionModeController,
        performanceStateController: HostPerformanceStateController,
        fileTransferManager: HostFileTransferManager,
        productMode: HostProductMode = .full,
        sessionTokenUnsealer: ((Data) -> Data?)? = nil,
        streamWindowGeometry: StreamWindowGeometryStore = StreamWindowGeometryStore(),
        ensureDiscoveryAdvertising: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.streamWindowGeometry = streamWindowGeometry
        self.hostIdentity = hostIdentity
        self.captureEngine = captureEngine
        self.encoderPipeline = encoderPipeline
        self.displayLayoutProvider = displayLayoutProvider
        self.permissionService = permissionService
        self.webRTCSessionManager = webRTCSessionManager
        self.peerTrustGate = peerTrustGate
        self.streamingCoordinator = streamingCoordinator
        self.inputCommandRouter = inputCommandRouter
        self.eventLogStore = eventLogStore
        self.signalingService = signalingService
        self.sessionModeController = sessionModeController
        self.performanceStateController = performanceStateController
        self.fileTransferManager = fileTransferManager
        self.productMode = productMode
        self.sessionTokenUnsealer = sessionTokenUnsealer
        self.ensureDiscoveryAdvertising = ensureDiscoveryAdvertising
        self.connectionDebugger = ConnectionDebugger(role: "host", eventLogStore: eventLogStore)
        self.connectionDebugger.snapshotProvider = { [weak self] in
            guard let self else { return [:] }
            let stream = self.webRTCSessionManager.streamDiagnostics
            var snapshot: [String: String] = [
                "phase": self.phase.rawValue,
                "peerState": self.webRTCSessionManager.peerConnectionState.rawValue,
                "dataChannel": self.webRTCSessionManager.dataChannelState.rawValue,
                "framesSent": String(stream.framesSent),
                "bytesSent": String(stream.bytesSent),
                "capturedFrames": String(self.captureEngine.diagnostics.capturedFrames),
                "encodedFrames": String(self.encoderPipeline.encoderDiagnostics.encodedFrames)
            ]
            if let sessionID = self.activeSessionID {
                snapshot["sessionID"] = sessionID.uuidString
            }
            if let clientName = self.connectedClientName {
                snapshot["client"] = clientName
            }
            if let lastSent = stream.lastFrameSentAt {
                snapshot["lastFrameSentAgo"] = String(format: "%.1fs", Date().timeIntervalSince(lastSent))
            }
            return snapshot
        }
    }

    // MARK: - Start / Stop

    /// Start listening for client connections.
    func startSession() async {
        guard phase == .idle || phase == .error else { return }

        // Clean up any leftover state from a previous error/session
        if phase == .error {
            await stopSession()
        }

        errorMessage = nil
        phase = .advertising
        hasPublishedInitialSessionState = false

        do {
            // Set stable host identity on the signaling service
            if let bonjourSig = signalingService as? BonjourSignalingService {
                bonjourSig.localPeer = SignalingPeer(
                    id: hostIdentity.id,
                    role: .host,
                    displayName: hostIdentity.displayName,
                    publicKeyFingerprint: hostIdentity.publicKeyFingerprint
                )
            }

            // Subscribe to signaling messages BEFORE starting the listener
            // to avoid a race where a fast client connects and sends an offer
            // before messageContinuation is set.
            listenForSignalingMessages()

            // Start the signaling listener on a known port.
            // `startListening` blocks on a DispatchSemaphore (up to 5s) waiting for the
            // NWListener to reach .ready. This coordinator is @MainActor, so calling it
            // directly would block the main thread. `BonjourSignalingService` is
            // @unchecked Sendable, so run the synchronous start off the main actor and
            // await the result. The continuation subscribed above is already in place,
            // so the listener-must-precede-later-calls ordering is preserved.
            let signalingPort = try await Task.detached(priority: .userInitiated) { [signalingService] in
                try signalingService.startListening(port: RemoteDesktopConstants.defaultSignalingPort)
            }.value
            logger.info("Signaling listener on port \(signalingPort)")

            // Start a TLS-PSK listener alongside the plain listener when the host has
            // a valid cryptographic identity.  Failure is non-fatal — older clients that
            // don't see the "stlsp" TXT key continue using the plain port.
            if let bonjourSig = signalingService as? BonjourSignalingService,
               RemoteDesktopConstants.isValidPublicKeyFingerprint(hostIdentity.publicKeyFingerprint) {
                let fingerprint = hostIdentity.publicKeyFingerprint
                var lastTLSError: Error?
                for attempt in 1...3 {
                    do {
                        let tlsPort = try await Task.detached(priority: .userInitiated) { [bonjourSig] in
                            try bonjourSig.startTLSListening(
                                pin: fingerprint,
                                port: RemoteDesktopConstants.defaultTLSSignalingPort
                            )
                        }.value
                        logger.info("TLS signaling listener on port \(tlsPort)")
                        lastTLSError = nil
                        break
                    } catch {
                        lastTLSError = error
                        logger.warning("TLS signaling listener attempt \(attempt)/3 failed: \(error.localizedDescription)")
                        if attempt < 3 {
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                    }
                }
                if let lastTLSError {
                    logger.error("TLS signaling listener could not start after retries (plain TCP remains for first-time clients): \(lastTLSError.localizedDescription)")
                    await eventLogStore.append(EventLogItem(
                        severity: .warning,
                        category: "Trust",
                        message: "Secure signaling on port 9473 failed to start. Discovered clients still require TLS; first-time typed addresses may use plaintext 9471 until a fingerprint is saved."
                    ))
                }
            }

            phase = .awaitingClient

            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Session",
                message: "Host listening for connections on port \(signalingPort)"
            ))

        } catch {
            phase = .error
            errorMessage = startFailureMessage(for: error)
            logger.error("Failed to start session: \(error.localizedDescription)")
        }
    }

    private func startFailureMessage(for error: Error) -> String {
        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("listener")
            || description.localizedCaseInsensitiveContains("address")
            || description.localizedCaseInsensitiveContains("in use") {
            let otherProduct: String
            switch productMode {
            case .full:
                otherProduct = "Vamp Terminal Host"
            case .terminalOnly:
                otherProduct = "Vamp Host"
            case .mini:
                otherProduct = "Vamp Host or Vamp Terminal Host"
            }
            return "\(productMode.productTitle) could not open port \(RemoteDesktopConstants.defaultSignalingPort). Quit \(otherProduct) if it is running, then restart this host."
        }
        return description
    }

    /// Tear down the active session.
    func stopSession() async {
        connectionDebugger.mark("stopSession (host-initiated)")
        cancelDisconnectGraceTimer()
        clientActivityObserverTask?.cancel()
        clientActivityObserverTask = nil
        livenessWatchdogTask?.cancel()
        livenessWatchdogTask = nil
        captureStateObserverTask?.cancel()
        captureStateObserverTask = nil
        let bridgeTask = bridgeEventTask
        let connTask = connectionObserverTask
        let dataTask = dataChannelObserverTask
        let displayTask = displayLayoutObserverTask
        let pendingLayoutTask = pendingDisplayLayoutChangeTask
        bridgeEventTask?.cancel()
        bridgeEventTask = nil
        connectionObserverTask?.cancel()
        connectionObserverTask = nil
        dataChannelObserverTask?.cancel()
        dataChannelObserverTask = nil
        displayLayoutObserverTask?.cancel()
        displayLayoutObserverTask = nil
        pendingDisplayLayoutChangeTask?.cancel()
        pendingDisplayLayoutChangeTask = nil
        initialDataChannelRetryTask?.cancel()
        initialDataChannelRetryTask = nil
        adaptiveStreamingTask?.cancel()
        adaptiveStreamingTask = nil
        lockStateObserver?.cancel()
        lockStateObserver = nil

        // Stop signaling BEFORE awaiting tasks so their streams terminate
        signalingService.stopListening()
        signalingService.disconnect()

        inputCommandRouter.stopListening()
        streamingCoordinator.stopCoordinating()

        #if os(macOS)
        targetSwitchTask?.cancel()
        await targetSwitchTask?.value
        targetSwitchTask = nil
        originalAppWindowBounds.removeAll()
        clearWindowStreaming()
        #endif
        // Await cancellation to ensure clean shutdown
        await bridgeTask?.value
        await connTask?.value
        await dataTask?.value
        await displayTask?.value
        await pendingLayoutTask?.value

        await webRTCSessionManager.closeSession()
        webRTCSessionManager.configureControlChannelAuth(sessionTokenHex: nil)
        await captureEngine.stopCapture()
        captureEngine.setAudioReceiver(nil)
        #if os(macOS)
        await audioPipeline?.deactivate()
        await stopAllSecondaryStreamers()
        #endif
        await encoderPipeline.stopEncoding()

        activeSessionID = nil
        activeClientID = nil
        activeClientFingerprint = nil
        activeSessionIsTerminalOnly = false
        connectedClientName = nil
        latestObservedLayout = nil
        activeStreamDisplayRestartKey = nil
        isApplyingPerformanceProfile = false
        needsPerformanceProfileReapply = false
        requestedDynamicRange = .sdr
        hasPublishedInitialSessionState = false
        hasSentInitialDataChannelState = false
        phase = .idle

        await eventLogStore.append(EventLogItem(
            severity: .info,
            category: "Session",
            message: "Session stopped"
        ))
    }

    // MARK: - Signaling

    private func listenForSignalingMessages() {
        // Call receiveMessages() SYNCHRONOUSLY here — the AsyncThrowingStream initialiser
        // invokes its closure synchronously, which sets messageContinuation on the signaling
        // service before this function returns.  That means the continuation is guaranteed to
        // be in place before startListening() is called, even though startListening() blocks
        // @MainActor via DispatchSemaphore.wait.  Without this, a fast reconnecting client
        // (or any IP-connect attempt) can deliver an offer while messageContinuation is still
        // nil, causing the offer to be silently dropped.
        let messageStream = signalingService.receiveMessages()
        bridgeEventTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in messageStream {
                    guard !Task.isCancelled else { break }
                    await self.handleSignalingMessage(message)
                }
            } catch {
                self.logger.warning("Signaling receive ended: \(error.localizedDescription)")
            }
        }
    }

    private func handleSignalingMessage(_ message: VersionedSignalingMessage) async {
        let event = message.envelope.event

        switch event {
        case .offer(let offer):
            guard message.envelope.sender.role == .client else {
                logger.warning("Rejected offer from non-client signaling role")
                return
            }
            if let activeSessionID,
               !HostClientAttachmentIdentity.matches(
                   activeClientID: activeClientID,
                   activeClientFingerprint: activeClientFingerprint,
                   candidate: message.envelope.sender
               ) {
                await rejectAdditionalClient(
                    offerSessionID: offer.sessionID,
                    activeSessionID: activeSessionID,
                    sender: message.envelope.sender
                )
                return
            }
            phase = .signalingConnected
            connectedClientName = message.envelope.sender.displayName
            await handleClientOffer(offer, sender: message.envelope.sender)

        case .iceCandidate(let candidate):
            guard candidate.sessionID == activeSessionID else {
                logger.debug("Ignoring ICE candidate for inactive session \(candidate.sessionID.uuidString)")
                return
            }
            do {
                try await webRTCSessionManager.addRemoteCandidate(candidate)
            } catch {
                logger.warning("Failed to add ICE candidate: \(error.localizedDescription)")
            }

        default:
            logger.info("Ignoring signaling event: \(event.kind.rawValue)")
        }
    }

    private func rejectAdditionalClient(
        offerSessionID: UUID,
        activeSessionID: UUID,
        sender: SignalingPeer
    ) async {
        let clientName = sender.displayName ?? "Unknown Client"
        do {
            try await sendSignalingEvent(
                .hostBusy(HostBusyMessage(
                    hostID: hostIdentity.id,
                    activeSessionID: nil,
                    retryAfter: 5
                )),
                sessionID: offerSessionID,
                recipient: sender
            )
        } catch {
            logger.warning("Could not send host-busy response to \(clientName): \(error.localizedDescription)")
        }
        signalingService.dropCurrentConnection()
        logger.info("Rejected additional client \(clientName); session \(activeSessionID.uuidString) remains active")
        await eventLogStore.append(EventLogItem(
            severity: .info,
            category: "Session",
            message: "Rejected additional client '\(clientName)' because another device is connected"
        ))
    }

    func revokePeer(_ peer: TrustedPeer, store: any TrustedPeerStoreProtocol) async throws {
        trustRevision &+= 1
        revokingFingerprints.insert(peer.fingerprint)
        defer { revokingFingerprints.remove(peer.fingerprint) }
        if HostClientAttachmentIdentity.matchesRevokedPeer(activeClientID: activeClientID, activeClientFingerprint: activeClientFingerprint, peer: peer) {
            // Synchronous invalidation precedes every suspension. stopListening detaches
            // terminals and releases held input; it does not destroy persistent sessions.
            inputCommandRouter.stopListening()
            activeSessionID = nil
            webRTCSessionManager.configureControlChannelAuth(sessionTokenHex: nil)
            await resetForNextClient(reason: "Device access revoked")
        }
        try await store.revokePeer(id: peer.id)
    }

    private func handleClientOffer(_ offer: SessionOfferMessage, sender: SignalingPeer) async {
        let revision = trustRevision
        guard !revokingFingerprints.contains(sender.publicKeyFingerprint ?? "") else { return }

        // Record the client's advertised decoder capabilities so codec negotiation
        // reflects what this specific client can actually decode (e.g. HEVC).
        advertisedClientCapabilities = offer.clientCapabilities
        // A compatible Mac client renders its own cursor immediately. Keep the
        // cursor in captured video for every older peer and non-Mac client.
        captureEngine.setShowsCursor(!negotiatedCapabilities.supportsCursorlessCapture)
        requestedDynamicRange = offer.preferredDynamicRange ?? .sdr
        webRTCSessionManager.configureVideoTransport(
            fragmentationEnabled: offer.clientCapabilities?.contains(.supportsVideoFragmentation) == true,
            fecEnabled: offer.clientCapabilities?.contains(.supportsVideoFEC) == true
        )

        // Trust evaluation
        phase = .trustPending
        let clientID = sender.id
        let clientName = sender.displayName ?? "Unknown Client"
        let isTerminalSession = offer.clientProductRole == .terminal
            && offer.clientCapabilities?.contains(.supportsTerminal) == true

        if productMode.isTerminalOnly {
            guard isTerminalSession else {
                try? await sendSignalingEvent(
                    .permissionBlocked(
                        PermissionBlockedMessage(
                            sessionID: offer.sessionID,
                            blockedPermissions: [],
                            reason: .terminalOnlyHost
                        )
                    ),
                    sessionID: offer.sessionID,
                    recipient: sender
                )
                logger.warning("Rejected non-terminal client '\(clientName)' from terminal-only host")
                signalingService.dropCurrentConnection()
                phase = .awaitingClient
                errorMessage = "This host accepts Vamp Terminal clients only."
                await eventLogStore.append(EventLogItem(
                    severity: .warning,
                    category: "Session",
                    message: "Rejected non-terminal client '\(clientName)' from Vamp Terminal Host"
                ))
                return
            }
        }

        // Require a real cryptographic fingerprint. A missing or empty fingerprint
        // means the client sent no public key — we cannot verify identity, so reject.
        guard let fingerprint = sender.publicKeyFingerprint, !fingerprint.isEmpty else {
            logger.warning("Rejected client '\(clientName)' — missing public key fingerprint")
            signalingService.dropCurrentConnection()
            phase = .awaitingClient
            await eventLogStore.append(EventLogItem(
                severity: .warning,
                category: "Trust",
                message: "Rejected connection from '\(clientName)': no public key fingerprint"
            ))
            return
        }

        let peerTrustGate = self.peerTrustGate
        let trusted: Bool
        do {
            trusted = try await withTimeout(seconds: RemoteDesktopConstants.trustPromptTimeout) {
                await peerTrustGate.evaluateAndPrompt(
                    peerID: clientID,
                    displayName: clientName,
                    fingerprint: fingerprint
                )
            }
        } catch {
            logger.warning("Trust prompt timed out for \(clientName)")
            // Clear the stuck trust gate so future connections aren't silently rejected
            await peerTrustGate.cancelPendingPrompt()
            signalingService.dropCurrentConnection()
            phase = .awaitingClient
            return
        }

        guard trusted else {
            logger.warning("Client \(clientName) rejected by trust gate")
            signalingService.dropCurrentConnection()
            phase = .awaitingClient
            let reason = await peerTrustGate.lastDenialReason
                ?? "Rejected connection from \(clientName)"
            await eventLogStore.append(EventLogItem(
                severity: .warning,
                category: "Trust",
                message: reason
            ))
            return
        }

        guard let sessionTokenHex = await resolveSessionToken(from: offer, clientName: clientName) else {
            signalingService.dropCurrentConnection()
            phase = .awaitingClient
            return
        }
        guard revision == trustRevision else { return }
        webRTCSessionManager.configureControlChannelAuth(sessionTokenHex: sessionTokenHex)

        // Proceed with session
        phase = .negotiating
        let sessionID = offer.sessionID
        activeSessionID = sessionID
        activeClientID = sender.id
        activeClientFingerprint = fingerprint
        activeSessionIsTerminalOnly = isTerminalSession
        hasPublishedInitialSessionState = false
        hasSentInitialDataChannelState = false

        do {
            let blockedPermissions = isTerminalSession
                ? []
                : await blockedRequiredPermissions()
            if !blockedPermissions.isEmpty {
                // Don't send specific permission details to unauthenticated clients
                try await sendSignalingEvent(
                    .permissionBlocked(PermissionBlockedMessage(sessionID: sessionID, blockedPermissions: [])),
                    sessionID: sessionID,
                    recipient: sender
                )
                phase = .awaitingClient
                errorMessage = "Host permissions are required before streaming can start."
                activeSessionID = nil
                activeClientID = nil
                activeClientFingerprint = nil
                logger.warning("Blocked session: \(blockedPermissions.count) missing permissions (details withheld from client)")
                return
            }

            guard revision == trustRevision else { return }
            // Prepare WebRTC session
            try await webRTCSessionManager.prepareSession(id: sessionID, role: .host)

            guard revision == trustRevision else { await webRTCSessionManager.closeSession(); return }

            // A fast reconnect flows through here on the SAME coordinator while the PREVIOUS
            // session's 8s disconnect-grace task is still armed. prepareSession has now closed
            // the old peer connection, so disarm that stale timer — otherwise it fires
            // mid-negotiation (connectionState == .connecting != .connected) and calls
            // resetForNextClient, tearing down this in-progress new session.
            cancelDisconnectGraceTimer()

            // Apply client offer and generate answer
            let answer = try await webRTCSessionManager.applyRemoteOffer(offer)
            guard revision == trustRevision else { await webRTCSessionManager.closeSession(); return }
            // Never put the session token on the signaling answer. The client
            // already holds the value it generated; echoing it re-exposes the
            // control-channel secret on plaintext 9471.

            // Start the streaming coordinator and state observers BEFORE
            // sending the answer so we don't miss early transport transitions.
            streamingCoordinator.startCoordinating()
            observeConnectionState()
            observeDataChannelState()
            if !isTerminalSession && !sessionStartsWithAppBrowser {
                observeDisplayLayoutChanges()
            }
            lastClientActivityAt = nil
            captureFailureRestartAttempted = false
            observeClientActivity()
            startLivenessWatchdog()
            if !isTerminalSession {
                observeCaptureState()
            }

            // Send answer back via signaling
            try await signalingService.sendAnswer(answer, to: ClientIdentity(
                displayName: clientName,
                deviceModel: "Unknown",
                osVersion: "Unknown",
                appVersion: "0.1",
                publicKeyFingerprint: fingerprint
            ))

            logger.info("SDP answer sent for session \(sessionID.uuidString)")

            guard revision == trustRevision else { return }
            // Start the capture → encode → transport pipeline
            await startPipeline(
                sessionID: sessionID,
                offer: offer,
                sessionTokenHex: sessionTokenHex,
                terminalOnly: isTerminalSession
            )

        } catch {
            let diagnostic = "\(String(reflecting: type(of: error))): \(error.localizedDescription)"
            logger.error("Session negotiation failed: \(diagnostic, privacy: .public)")
            await eventLogStore.append(EventLogItem(
                severity: .error,
                category: "Session",
                message: "Negotiation failed: \(diagnostic)"
            ))
            // Disconnect the signaling TCP so a new client connection can be accepted,
            // then return to awaitingClient so the listener keeps running.
            // (Using dropCurrentConnection instead of disconnect so the message stream
            // stays alive for the next incoming offer.)
            signalingService.dropCurrentConnection()
            await webRTCSessionManager.closeSession()
            activeSessionID = nil
            activeClientID = nil
            activeClientFingerprint = nil
            activeSessionIsTerminalOnly = false
            connectedClientName = nil
            phase = .awaitingClient
        }
    }

    /// Resolve the session token from an offer. Prefers the ECIES-sealed form
    /// (which only this host's identity key can open) and rejects the offer if
    /// it cannot be opened, so a client cannot silently downgrade to the
    /// plaintext path. Falls back to the legacy plaintext token only when the
    /// offer carries no seal at all.
    private func resolveSessionToken(from offer: SessionOfferMessage, clientName: String) async -> String? {
        if let sealed = offer.sealedSessionToken {
            guard let unseal = sessionTokenUnsealer,
                  let opened = unseal(sealed),
                  opened.count == 32 else {
                logger.warning("Rejected offer with unopenable sealed session token from \(clientName)")
                await eventLogStore.append(EventLogItem(
                    severity: .warning,
                    category: "Trust",
                    message: "Rejected connection from \(clientName): sealed session token could not be opened"
                ))
                return nil
            }
            let hex = ConnectionSecurity.tokenToHex(opened)
            logger.info("Offer session token opened from ECIES seal (\(clientName))")
            return hex
        }
        guard let plain = offer.sessionToken,
              let data = ConnectionSecurity.tokenFromHex(plain),
              data.count == 32 else {
            logger.warning("Rejected offer with missing/invalid session token from \(clientName)")
            await eventLogStore.append(EventLogItem(
                severity: .warning,
                category: "Trust",
                message: "Rejected connection from \(clientName) due to invalid session token"
            ))
            return nil
        }
        return plain
    }

    // MARK: - Pipeline

    private func startPipeline(
        sessionID: UUID,
        offer: SessionOfferMessage,
        sessionTokenHex: String?,
        terminalOnly: Bool
    ) async {
        guard activeSessionID == sessionID else { return }
        phase = .pipelineStarting

        // Wire the lock state provider into the input router BEFORE startListening, so an input
        // command processed during startup can't bypass the lock-screen gate. (startListening spawns
        // an async receive loop; if a command arrived before this assignment, the router's default
        // provider reports "unlocked" and would inject at the login window.)
        inputCommandRouter.lockStateProvider = lockStateProvider

        // Start the input command router regardless of capture/encode success
        inputCommandRouter.startListening(
            sessionID: sessionID,
            expectedSessionTokenHex: sessionTokenHex,
            terminalOnly: terminalOnly
        )
        inputCommandRouter.onQualityAdjust = { [weak self] preset in
            guard let self else { return }
            Task { await self.applyRuntimeQualityAdjust(preset) }
        }
        inputCommandRouter.onKeyframeRequest = { [weak self] in
            Task { [weak self] in
                await self?.handleKeyframeRequest()
            }
        }
        inputCommandRouter.onSetActiveDisplays = { [weak self] message in
            await self?.handleSetActiveDisplays(message)
        }

        if terminalOnly {
            // The terminal-only product still uses the authenticated WebRTC
            // data channel, but never starts ScreenCaptureKit, the encoder, or
            // the audio pipeline. The session-ready signal is enough for the
            // terminal client to mount its workspace.
            await publishInitialSessionState(sessionID: sessionID)
            return
        }

        // Observe lock state transitions and push a hostStatus update so the
        // iOS client can show the locked overlay immediately. Vamp Sync needs
        // this even before an app window starts streaming.
        lockStateObserver = lockStatePublisher?
            .removeDuplicates()
            .sink { [weak self] newState in
                guard let self else { return }
                Task { await self.publishHostStatusUpdate() }
                self.logger.info("Host lock state changed: \(newState.statusLabel, privacy: .public)")
            }

        if sessionStartsWithAppBrowser {
            // Match Vamp Assistant: establish trust, transport, input routing,
            // and the application browser without capturing the full display.
            // The first capture begins only after a streamTargetSwitch request
            // resolves a concrete application window.
            await captureEngine.stopCapture()
            await encoderPipeline.stopEncoding()
            // The idle host profile starts at Balanced. Using it as an input to
            // `minQualityPreset` silently capped every Vamp Stream request at 1080p
            // on H.264 and prevented native-resolution Ultra capture on HEVC. Apply
            // the client's request first; the controller still downgrades it for
            // low-power or thermal pressure.
            performanceStateController.setActivePreset(offer.qualityPreset)
            await publishInitialSessionState(sessionID: sessionID)
            return
        }

        do {
            // Fast reconnects can overlap teardown/startup for a short window.
            // Force a clean baseline so startCapture doesn't fail with "already running".
            await captureEngine.stopCapture()
            await encoderPipeline.stopEncoding()

            // Get display layout
            let layout = try await displayLayoutProvider.currentDisplayLayout()
            let displayID = offer.requestedDisplayID ?? layout.primaryDisplayID ?? layout.displays.first?.id
            let qualityPreset = performanceStateController.setActivePreset(offer.qualityPreset)

            guard let displayID else {
                throw CaptureEngineError.displayNotFound("No display available")
            }

            // Configure and start encoder
            guard let display = layout.display(withID: displayID) else {
                throw CaptureEngineError.displayNotFound("Display \(displayID) not found in layout")
            }
            try await encoderPipeline.configure(
                for: display,
                qualityPreset: qualityPreset,
                codec: negotiatedEncoderCodec,
                dynamicRange: negotiatedDynamicRange
            )
            try await encoderPipeline.startEncoding()

            // Wire audio pipeline before starting capture so it receives frames from the first buffer
            #if os(macOS)
            if let pipeline = audioPipeline {
                captureEngine.setAudioReceiver(pipeline)
                let sid = sessionID
                let sendFn: (DataChannelEnvelope) throws -> Void = { [weak webRTCSessionManager = self.webRTCSessionManager] env in
                    try webRTCSessionManager?.sendDataMessage(env)
                }
                let preferOpus = advertisedClientCapabilities?.contains(.supportsOpusAudio) == true
                await pipeline.activate(sessionID: sid, preferOpus: preferOpus, send: sendFn)
            }
            #endif

            // Start capture
            try await captureEngine.startCapture(
                displayID: displayID,
                qualityPreset: qualityPreset,
                allowsHighResolution: captureAllowsHighResolution,
                dynamicRange: captureDynamicRange
            )
            encoderPipeline.forceKeyframe()
            performanceStateController.setActivePreset(qualityPreset)
            startAdaptiveStreamingControl(for: qualityPreset)

            // Avoid hanging in "pipeline starting" when capture starts but frames never flow.
            // This can happen on some macOS setups when ScreenCaptureKit starts successfully
            // but no frames are produced (for example after display/runtime transitions).
            try await waitForFirstFrame(timeoutSeconds: startupFirstFrameTimeoutSeconds)
            markActiveStreamDisplay(display)

            logger.info("Pipeline started: capture → encode → transport")

            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Session",
                message: "Streaming pipeline started for display \(displayID)"
            ))

            // Publish session-ready as soon as the pipeline is confirmed running.
            // The signaling channel is the reliable path for unblocking the client UI;
            // data-channel messages remain best-effort inside publishInitialSessionState.
            if let sessionID = activeSessionID,
               !hasPublishedInitialSessionState {
                await publishInitialSessionState(sessionID: sessionID)
            }

        } catch {
            logger.error("Pipeline start failed: \(error.localizedDescription)")
            // Notify the client that the pipeline failed
            if let sessionID = activeSessionID {
                try? await sendSignalingEvent(
                    .permissionBlocked(PermissionBlockedMessage(sessionID: sessionID, blockedPermissions: [])),
                    sessionID: sessionID,
                    recipient: nil
                )
            }
            await eventLogStore.append(EventLogItem(
                severity: .error,
                category: "Session",
                message: "Pipeline failed: \(error.localizedDescription)"
            ))

            let isPermissionError: Bool
            if let captureError = error as? CaptureEngineError,
               case .permissionDenied = captureError {
                isPermissionError = true
            } else {
                isPermissionError = false
            }
            let userMessage = isPermissionError
                ? "Screen Recording permission required. Open System Settings → Privacy & Security → Screen Recording, enable this app, then ask the client to reconnect."
                : "Pipeline failed. Waiting for a new client."
            await resetForNextClient(
                reason: "Pipeline failed; host is listening for a new client",
                severity: .error,
                userErrorMessage: userMessage
            )
        }
    }

    private func waitForFirstFrame(timeoutSeconds: Double) async throws {
        let startedAt = Date()
        let initialCapturedFrames = captureEngine.diagnostics.capturedFrames
        let initialEncodedFrames = encoderPipeline.encoderDiagnostics.encodedFrames

        while Date().timeIntervalSince(startedAt) < timeoutSeconds {
            let capturedNow = captureEngine.diagnostics.capturedFrames
            let encodedNow = encoderPipeline.encoderDiagnostics.encodedFrames
            if capturedNow > initialCapturedFrames || encodedNow > initialEncodedFrames {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw CaptureEngineError.streamFailed("Timed out waiting for first captured/encoded frame")
    }

    // MARK: - Connection Monitoring

    private func observeConnectionState() {
        connectionObserverTask?.cancel()
        connectionObserverTask = Task { [weak self] in
            guard let self else { return }
            for await state in webRTCSessionManager.connectionStateUpdates() {
                guard !Task.isCancelled else { break }
                self.connectionDebugger.record("connection", state.rawValue, metadata: [
                    "peerState": self.webRTCSessionManager.peerConnectionState.rawValue,
                    "dataChannel": self.webRTCSessionManager.dataChannelState.rawValue,
                    "phase": self.phase.rawValue
                ])
                switch state {
                case .connected:
                    self.logger.info("Peer connected")
                    if self.disconnectGraceTask != nil {
                        self.cancelDisconnectGraceTimer()
                        self.connectionDebugger.mark("transient disconnect recovered within grace period")
                        self.logger.info("Transient disconnect recovered — teardown cancelled")
                    }
                    if let sessionID = self.activeSessionID,
                       (self.phase == .pipelineStarting || self.phase == .negotiating || self.phase == .streaming),
                       !self.hasPublishedInitialSessionState {
                        await self.publishInitialSessionState(sessionID: sessionID)
                    }
                case .disconnected:
                    self.inputCommandRouter.releaseHeldInput()
                    // TCP-level .disconnected is frequently transient (Wi-Fi roam,
                    // brief congestion) and the provider retries internally — give
                    // it a grace window instead of killing the session instantly.
                    self.logger.warning("Peer disconnected — grace period \(self.disconnectGraceSeconds)s before teardown")
                    self.startDisconnectGraceTimer()
                case .failed:
                    self.inputCommandRouter.releaseHeldInput()
                    // A flaky relay (e.g. Tailscale DERP) surfaces a brief path flap as a
                    // terminal `.failed` just as often as `.disconnected`. Treat it the same:
                    // give it the grace window instead of an instant teardown. If the client
                    // re-attaches within the window the `.connected` case above cancels the
                    // timer; if it's genuinely dead the grace failsafe tears down after
                    // \(disconnectGraceSeconds)s. Instant `resetForNextClient` here is what
                    // turned single relay blips into a reconnect storm — the teardown forced a
                    // full re-negotiation whose races (listener-port assignment, stale session
                    // token) cascaded into minutes of churn.
                    self.logger.warning("Peer connection failed — grace period \(self.disconnectGraceSeconds)s before teardown")
                    self.startDisconnectGraceTimer()
                default:
                    break
                }
            }
        }
    }

    // MARK: - Disconnect Grace + Liveness

    private func startDisconnectGraceTimer() {
        guard disconnectGraceTask == nil else { return }
        connectionDebugger.mark("disconnect grace timer started (\(disconnectGraceSeconds)s)")
        disconnectGraceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.disconnectGraceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.disconnectGraceTask = nil
            guard self.webRTCSessionManager.connectionState != .connected else { return }
            self.connectionDebugger.connectionLost(
                reason: "Peer disconnected and did not recover within \(self.disconnectGraceSeconds)s grace period"
            )
            await self.resetForNextClient(reason: "Client disconnected")
        }
    }

    private func cancelDisconnectGraceTimer() {
        disconnectGraceTask?.cancel()
        disconnectGraceTask = nil
    }

    /// Stamps `lastClientActivityAt` on every inbound control-channel message.
    /// The client sends a ping every 2 s, so silence means the client is gone
    /// even when the TCP transport still reports `.connected` (half-open path).
    private func observeClientActivity() {
        clientActivityObserverTask?.cancel()
        // Consume the stream OFF the main actor (Task.detached) so the activity stamp keeps
        // updating even when the main thread is blocked by a modal — see lastClientActivityAt.
        // The AsyncStream is Sendable (DataChannelEnvelope is); the manager itself is not, so
        // we capture the stream, not the manager.
        let messages = webRTCSessionManager.receiveDataMessages()
        clientActivityObserverTask = Task.detached { [weak self] in
            for await _ in messages {
                guard !Task.isCancelled else { break }
                self?.lastClientActivityAt = Date()
            }
        }
    }

    private func startLivenessWatchdog() {
        livenessWatchdogTask?.cancel()
        livenessWatchdogTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                guard self.phase == .streaming,
                      self.webRTCSessionManager.connectionState == .connected,
                      let lastActivity = self.lastClientActivityAt else { continue }
                let silentFor = Date().timeIntervalSince(lastActivity)
                guard silentFor > self.clientLivenessTimeoutSeconds else { continue }
                self.logger.error("Client liveness timeout — no inbound traffic for \(String(format: "%.0f", silentFor))s")
                self.connectionDebugger.connectionLost(
                    reason: "Client liveness timeout — no inbound traffic for \(String(format: "%.0f", silentFor))s while transport reported connected"
                )
                // Hop to a fresh task: resetForNextClient cancels this watchdog,
                // and running teardown on an already-cancelled task would make
                // its internal sleeps/awaits bail early.
                Task { await self.resetForNextClient(reason: "Client unresponsive — connection presumed lost") }
                break
            }
        }
    }

    /// Capture failures (display sleep, ScreenCaptureKit stream stop, permission
    /// revocation) previously stalled the stream silently while the host stayed
    /// in `.streaming`. Observe the engine state, attempt one in-place pipeline
    /// restart, and tear the session down cleanly if recovery fails.
    private func observeCaptureState() {
        captureStateObserverTask?.cancel()
        captureStateObserverTask = Task { [weak self] in
            guard let self else { return }
            for await state in captureEngine.stateChanges() {
                guard !Task.isCancelled else { break }
                self.connectionDebugger.record("capture", state.rawValue)
                guard self.phase == .streaming || self.phase == .pipelineStarting else { continue }
                switch state {
                case .failed:
                    await self.handleCaptureFailure()
                case .permissionBlocked:
                    self.connectionDebugger.connectionLost(reason: "Screen Recording permission revoked mid-session")
                    Task {
                        await self.resetForNextClient(
                            reason: "Screen Recording permission blocked",
                            severity: .error,
                            userErrorMessage: "Screen Recording permission was revoked. Re-grant it in System Settings."
                        )
                    }
                default:
                    break
                }
            }
        }
    }

    private func handleCaptureFailure() async {
        logger.error("Capture engine failed mid-session")
        guard !captureFailureRestartAttempted else {
            connectionDebugger.connectionLost(reason: "Screen capture failed again after a restart attempt")
            Task {
                await self.resetForNextClient(
                    reason: "Screen capture failed",
                    severity: .error,
                    userErrorMessage: "Screen capture failed. Waiting for a new client."
                )
            }
            return
        }
        captureFailureRestartAttempted = true
        connectionDebugger.mark("capture failed — attempting pipeline restart")

        // Let a concurrent display-change restart settle before re-checking.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard captureEngine.captureState == .failed else {
            connectionDebugger.mark("capture recovered on its own — restart skipped")
            captureFailureRestartAttempted = false
            return
        }

        do {
            #if os(macOS)
            if let target = activeWindowTarget {
                try await restartStreamingPipelineForWindow(
                    descriptor: target.descriptor,
                    windowID: target.windowID,
                    qualityPreset: currentQualityPreset
                )
                captureFailureRestartAttempted = false
                connectionDebugger.mark("application window pipeline restarted after capture failure")
                logger.info("Application window pipeline restarted after capture failure")
                await publishHostStatusUpdate()
                return
            }
            if sessionStartsWithAppBrowser {
                throw CaptureEngineError.streamFailed("No application window available for capture recovery")
            }
            #endif

            let layout = try await displayLayoutProvider.currentDisplayLayout()
            let displayID = captureEngine.diagnostics.currentDisplayID
            guard let display = displayID.flatMap({ layout.display(withID: $0) }) ?? layout.displays.first else {
                throw CaptureEngineError.streamFailed("No display available for capture recovery")
            }
            try await restartPipelineForCurrentDisplay(display: display, qualityPreset: currentQualityPreset)
            captureFailureRestartAttempted = false
            connectionDebugger.mark("pipeline restarted after capture failure")
            logger.info("Pipeline restarted after capture failure")
        } catch {
            connectionDebugger.connectionLost(reason: "Pipeline restart after capture failure failed: \(error.localizedDescription)")
            Task {
                await self.resetForNextClient(
                    reason: "Screen capture failed and could not be restarted",
                    severity: .error,
                    userErrorMessage: "Screen capture failed. Waiting for a new client."
                )
            }
        }
    }

    private func observeDataChannelState() {
        dataChannelObserverTask?.cancel()
        dataChannelObserverTask = Task { [weak self] in
            guard let self else { return }
            for await state in webRTCSessionManager.dataChannelStateUpdates() {
                guard !Task.isCancelled else { break }
                self.connectionDebugger.record("dataChannel", state.rawValue)
                guard state == .open else { continue }
                guard let sessionID = self.activeSessionID else { continue }
                guard self.hasPublishedInitialSessionState, !self.hasSentInitialDataChannelState else { continue }
                if self.productMode.isTerminalOnly {
                    self.hasSentInitialDataChannelState = true
                    continue
                }

                do {
                    let layout = try await self.displayLayoutProvider.currentDisplayLayout()
                    let didSend = self.sessionStartsWithAppBrowser
                        ? self.sendAppStreamingInitialState(layout: layout, sessionID: sessionID)
                        : self.sendInitialDataChannelState(layout: layout, sessionID: sessionID)
                    if didSend {
                        self.logger.info("Initial data channel messages sent on data-channel open")
                    }
                } catch {
                    self.logger.warning("Failed to fetch display layout for initial data-channel send: \(error.localizedDescription)")
                }
            }
        }
    }

    private func observeDisplayLayoutChanges() {
        displayLayoutObserverTask?.cancel()
        guard let observer = displayLayoutProvider as? any DisplayLayoutObserving else { return }
        displayLayoutObserverTask = Task { [weak self] in
            guard let self else { return }
            for await layout in observer.layoutChanges() {
                guard !Task.isCancelled else { break }
                guard let sessionID = self.activeSessionID else { continue }
                guard self.phase == .streaming || self.phase == .pipelineStarting else { continue }
                self.latestObservedLayout = layout
                self.pendingDisplayLayoutChangeTask?.cancel()
                self.pendingDisplayLayoutChangeTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(nanoseconds: self.displayLayoutChangeDebounceMs * 1_000_000)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    guard self.activeSessionID == sessionID else { return }
                    guard self.phase == .streaming || self.phase == .pipelineStarting else { return }
                    guard let latestLayout = self.latestObservedLayout else { return }
                    self.latestObservedLayout = nil
                    await self.handleObservedDisplayLayoutChange(latestLayout, sessionID: sessionID)
                }
            }
        }
    }

    private func blockedRequiredPermissions() async -> [PermissionState] {
        // Match the dashboard: only `.denied` blocks streaming. `.unknown` is a
        // transient probe miss (common right after granting on macOS 26) and must
        // not look like a permanent permission failure to the client.
        await permissionService.currentStates().filter { $0.authorizationState == .denied }
    }

    private func minQualityPreset(_ a: StreamQualityPreset, _ b: StreamQualityPreset) -> StreamQualityPreset {
        let ranking: [StreamQualityPreset] = [.performance, .balanced, .quality, .ultra]
        guard let ai = ranking.firstIndex(of: a), let bi = ranking.firstIndex(of: b) else {
            return a
        }
        return ranking[min(ai, bi)]
    }

    private func handleKeyframeRequest() {
        encoderPipeline.forceKeyframe()
        #if os(macOS)
        // Refresh secondary displays too, so a client focus-switch shows the newly-focused
        // display promptly rather than waiting for its next GOP.
        secondaryStreamers.values.forEach { $0.forceKeyframe() }
        #endif
    }

    private func startAdaptiveStreamingControl(for preset: StreamQualityPreset) {
        adaptiveStreamingTask?.cancel()
        guard let initialBitrate = encoderPipeline.encoderDiagnostics.configuredBitrate else {
            return
        }
        var controller = AdaptiveStreamingController(
            initialBitrate: initialBitrate,
            preferredFrameRate: EncoderConfiguration.frameRate(for: preset)
        )
        adaptiveStreamingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { return }
                let decision = controller.observe(
                    bufferedBytes: self.webRTCSessionManager.videoBufferedAmount,
                    lossPermille: self.webRTCSessionManager.lastReportedClientLossPermille,
                    now: Date().timeIntervalSinceReferenceDate
                )
                if let bitrate = decision.targetBitrate {
                    self.encoderPipeline.setBitrate(bitrate)
                    self.logger.info("Adaptive bitrate target: \(bitrate / 1_000) kbps")
                }
                if let frameRate = decision.frameRateLimit {
                    do {
                        try await self.captureEngine.updateFrameRateLimit(frameRate)
                    } catch {
                        self.logger.warning("Adaptive capture FPS update failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private var currentQualityPreset: StreamQualityPreset {
        captureEngine.diagnostics.qualityPreset ?? performanceStateController.profile.effectivePreset
    }

    private func displayRestartKey(for display: DisplayDescriptor) -> DisplayRestartKey {
        DisplayRestartKey(
            displayID: display.id,
            logicalSize: display.frame.size,
            pixelSize: display.pixelSize,
            scaleFactor: display.scaleFactor,
            rotation: display.rotation
        )
    }

    private func markActiveStreamDisplay(_ display: DisplayDescriptor) {
        activeStreamDisplayRestartKey = displayRestartKey(for: display)
    }

    private func currentDisplayStreamConfiguration(
        layout: DisplayLayout,
        overrideDisplay: DisplayDescriptor? = nil
    ) -> DisplayStreamConfiguration? {
        let display = overrideDisplay
            ?? captureEngine.diagnostics.currentDisplayID.flatMap { layout.display(withID: $0) }
            ?? layout.primaryDisplayID.flatMap { layout.display(withID: $0) }
            ?? layout.displays.first
        guard let display else { return nil }
        let streamWidth = Double(encoderPipeline.encoderDiagnostics.configuredWidth ?? Int(display.pixelSize.width))
        let streamHeight = Double(encoderPipeline.encoderDiagnostics.configuredHeight ?? Int(display.pixelSize.height))
        return DisplayStreamConfiguration(
            display: display,
            streamWidth: streamWidth,
            streamHeight: streamHeight
        )
    }

    private func sendDisplayStateMessages(
        layout: DisplayLayout,
        sessionID: UUID,
        reason: String? = nil,
        overrideDisplay: DisplayDescriptor? = nil
    ) -> Bool {
        guard activeSessionID == sessionID else { return false }
        do {
            let layoutEnvelope = try DataChannelEnvelope.displayLayout(DisplayLayoutMessage(layout: layout))
            try webRTCSessionManager.sendDataMessage(layoutEnvelope)

            if let configuration = currentDisplayStreamConfiguration(layout: layout, overrideDisplay: overrideDisplay) {
                let configurationEnvelope = try DataChannelEnvelope.displayConfigurationChanged(
                    DisplayConfigurationChangedMessage(
                        sessionID: sessionID,
                        configuration: configuration,
                        layout: layout,
                        reason: reason
                    )
                )
                try webRTCSessionManager.sendDataMessage(configurationEnvelope)
            }

            let selectedDisplayID = overrideDisplay?.id
                ?? captureEngine.diagnostics.currentDisplayID
                ?? layout.primaryDisplayID
            let statusEnvelope = try DataChannelEnvelope.hostStatus(
                HostStatusMessage(
                    hostID: hostIdentity.id,
                    connectionState: .connected,
                    activeSessionID: sessionID,
                    displayLayout: layout,
                    selectedDisplayID: selectedDisplayID,
                    sessionMode: sessionModeController.currentMode,
                    quality: nil,
                    thermalState: performanceStateController.thermalState,
                    lowPowerModeEnabled: performanceStateController.lowPowerModeEnabled,
                    lockState: lockStateProvider()
                )
            )
            try webRTCSessionManager.sendDataMessage(statusEnvelope)
            hasSentInitialDataChannelState = true
            initialDataChannelRetryTask?.cancel()
            initialDataChannelRetryTask = nil
            return true
        } catch {
            return false
        }
    }

    private func restartStreamingPipeline(
        for display: DisplayDescriptor,
        layout: DisplayLayout,
        sessionID: UUID,
        qualityPreset: StreamQualityPreset,
        reason: String
    ) async throws {
        streamingCoordinator.handleDisplayRestart()
        await captureEngine.stopCapture()
        await encoderPipeline.stopEncoding()
        try await encoderPipeline.configure(
            for: display,
            qualityPreset: qualityPreset,
            codec: negotiatedEncoderCodec,
            dynamicRange: negotiatedDynamicRange
        )
        _ = sendDisplayStateMessages(
            layout: layout,
            sessionID: sessionID,
            reason: "\(reason)_preflight",
            overrideDisplay: display
        )
        try await encoderPipeline.startEncoding()
        try await captureEngine.startCapture(
            displayID: display.id,
            qualityPreset: qualityPreset,
            allowsHighResolution: captureAllowsHighResolution,
            dynamicRange: captureDynamicRange
        )
        encoderPipeline.forceKeyframe()
        startAdaptiveStreamingControl(for: qualityPreset)
        try await waitForFirstFrame(timeoutSeconds: startupFirstFrameTimeoutSeconds)
        markActiveStreamDisplay(display)
        _ = sendDisplayStateMessages(
            layout: layout,
            sessionID: sessionID,
            reason: reason,
            overrideDisplay: display
        )
    }

    private func handleObservedDisplayLayoutChange(_ layout: DisplayLayout, sessionID: UUID) async {
        #if os(macOS)
        // A window stream has its own geometry/tracking loop. The normal display-layout
        // observer cannot resolve a window ID in the monitor layout and would otherwise
        // fall back to the primary display, silently replacing the app stream.
        if activeWindowTarget != nil || isWindowStreamTransitioning { return }
        #endif
        let requestedDisplayID = captureEngine.diagnostics.currentDisplayID ?? layout.primaryDisplayID ?? layout.displays.first?.id
        guard let requestedDisplayID else {
            _ = sendDisplayStateMessages(layout: layout, sessionID: sessionID, reason: "layout_changed_empty")
            return
        }

        guard let display = layout.display(withID: requestedDisplayID)
            ?? layout.primaryDisplayID.flatMap({ layout.display(withID: $0) })
            ?? layout.displays.first else {
            _ = sendDisplayStateMessages(layout: layout, sessionID: sessionID, reason: "layout_changed_missing_display")
            return
        }

        let requiresRestart = requestedDisplayID != display.id
            || activeStreamDisplayRestartKey == nil
            || activeStreamDisplayRestartKey != displayRestartKey(for: display)

        guard requiresRestart else {
            _ = sendDisplayStateMessages(
                layout: layout,
                sessionID: sessionID,
                reason: "display_layout_changed",
                overrideDisplay: display
            )
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Display",
                message: "Display layout changed; updated mapping without restarting stream for display \(display.id)"
            ))
            return
        }

        #if os(macOS)
        isWindowStreamTransitioning = true
        defer { isWindowStreamTransitioning = false }
        clearWindowStreaming()
        #endif
        do {
            try await restartStreamingPipeline(
                for: display,
                layout: layout,
                sessionID: sessionID,
                qualityPreset: currentQualityPreset,
                reason: requestedDisplayID == display.id ? "display_configuration_changed" : "selected_display_reassigned"
            )
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Display",
                message: "Display configuration changed; restarted stream for display \(display.id)"
            ))
        } catch {
            logger.warning("Display configuration restart failed: \(error.localizedDescription)")
            _ = sendDisplayStateMessages(layout: layout, sessionID: sessionID, reason: "display_configuration_restart_failed")
        }
    }

    private func restartPipelineForCurrentDisplay(display: DisplayDescriptor, qualityPreset: StreamQualityPreset) async throws {
        let displayID = display.id
        await captureEngine.stopCapture()
        await encoderPipeline.stopEncoding()
        try await encoderPipeline.configure(
            for: display,
            qualityPreset: qualityPreset,
            codec: negotiatedEncoderCodec,
            dynamicRange: negotiatedDynamicRange
        )
        try await encoderPipeline.startEncoding()
        try await captureEngine.startCapture(
            displayID: displayID,
            qualityPreset: qualityPreset,
            allowsHighResolution: captureAllowsHighResolution,
            dynamicRange: captureDynamicRange
        )
        encoderPipeline.forceKeyframe()
        startAdaptiveStreamingControl(for: qualityPreset)
        try await waitForFirstFrame(timeoutSeconds: startupFirstFrameTimeoutSeconds)
        markActiveStreamDisplay(display)
    }

    /// Applies a client-requested runtime quality change without restarting the
    /// active session. Only downgrades are honoured; the host-profile minimum
    /// is always enforced.
    @MainActor
    private func applyRuntimeQualityAdjust(_ requested: StreamQualityPreset) async {
        guard let sessionID = activeSessionID else { return }
        let effective = performanceStateController.setActivePreset(requested)
        #if os(macOS)
        if let target = activeWindowTarget, let clientID = activeClientID {
            guard !isWindowStreamTransitioning else { return }
            await handleStreamTargetSwitchRequest(StreamTargetSwitchRequestMessage(
                sessionID: sessionID, target: .window(String(target.windowID)),
                launchIfNeeded: false, senderDeviceID: clientID))
            return
        }
        if sessionStartsWithAppBrowser { return }
        #endif
        logger.info("Applying runtime quality adjust to \(effective.rawValue)")
        do {
            guard let displayID = captureEngine.diagnostics.currentDisplayID else { return }
            let layout = try await displayLayoutProvider.currentDisplayLayout()
            guard let display = layout.display(withID: displayID) else { return }
            try await restartPipelineForCurrentDisplay(display: display, qualityPreset: effective)
            performanceStateController.setActivePreset(effective)
            if let sessionID = activeSessionID {
                _ = sendDisplayStateMessages(layout: layout, sessionID: sessionID, reason: "quality_adjust", overrideDisplay: display)
            }
            await publishHostStatusUpdate()
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Quality",
                message: "Runtime quality adjusted to \(effective.rawValue)"
            ))
        } catch {
            logger.warning("Runtime quality adjust failed: \(error.localizedDescription)")
        }
    }

    private func resetForNextClient(
        reason: String,
        severity: EventSeverity = .warning,
        userErrorMessage: String? = nil
    ) async {
        connectionDebugger.mark("resetForNextClient: \(reason)")
        cancelDisconnectGraceTimer()
        clientActivityObserverTask?.cancel()
        clientActivityObserverTask = nil
        livenessWatchdogTask?.cancel()
        livenessWatchdogTask = nil
        captureStateObserverTask?.cancel()
        captureStateObserverTask = nil
        #if os(macOS)
        targetSwitchTask?.cancel()
        await targetSwitchTask?.value
        targetSwitchTask = nil
        #endif
        // Keep host runtime active after disconnect/failure by tearing down
        // only the current session and returning to awaitingClient.
        inputCommandRouter.stopListening()
        streamingCoordinator.stopCoordinating()

        await captureEngine.stopCapture()
        await encoderPipeline.stopEncoding()
        await webRTCSessionManager.closeSession()
        webRTCSessionManager.configureControlChannelAuth(sessionTokenHex: nil)

        // Drop stale signaling connection so the next client can attach cleanly.
        signalingService.dropCurrentConnection()
        performanceStateController.resetActivePreset()

        activeSessionID = nil
        activeClientID = nil
        activeClientFingerprint = nil
        activeSessionIsTerminalOnly = false
        connectedClientName = nil
        hasPublishedInitialSessionState = false
        hasSentInitialDataChannelState = false
        pendingDisplayLayoutChangeTask?.cancel()
        pendingDisplayLayoutChangeTask = nil
        initialDataChannelRetryTask?.cancel()
        initialDataChannelRetryTask = nil
        latestObservedLayout = nil
        activeStreamDisplayRestartKey = nil
        #if os(macOS)
        // A window stream must not outlive its session — clear input geometry + tracking so a
        // reconnect never inherits a stale window layout.
        clearWindowStreaming()
        #endif
        isApplyingPerformanceProfile = false
        needsPerformanceProfileReapply = false
        errorMessage = userErrorMessage
        phase = .awaitingClient

        await ensureDiscoveryAdvertising()

        await eventLogStore.append(EventLogItem(
            severity: severity,
            category: "Session",
            message: reason
        ))
    }

    // MARK: - Capability Negotiation

    /// Flags this host advertises to clients. HEVC is advertised only when this
    /// machine has a hardware HEVC encoder, so the host never negotiates HEVC it
    /// can't encode efficiently (mirrors the client's hardware-decode gate).
    private static let fullHostCapabilityFlags: HostCapabilityFlags = {
        var flags: HostCapabilityFlags = [
            .supportsH264,
            .supportsMultiDisplay,
            .supportsMacClient,
            .supportsCursorlessCapture,
            .supportsAudioLater,
            .supportsVideoFragmentation,
            .supportsTerminal,
            .supportsMultipleTerminals,
            .supportsTerminalChat,
            .supportsTaskPlans,
            .supportsWorkspaces
        ]
        if VideoEncoderCapabilities.supportsHardwareHEVCEncode {
            flags.insert(.supportsHEVC)
            if #available(macOS 15.0, *) {
                flags.insert(.supportsHDR10)
            }
        }
        // App Streaming (window capture) needs ScreenCaptureKit APIs added in macOS 14.
        if #available(macOS 14, *) {
            flags.insert(.supportsAppStreaming)
        }
        return flags
    }()
    /// Assumed client capabilities for older clients that don't advertise their own
    /// (preserves the prior behaviour: all first-party clients decode HEVC in hardware).
    private static let assumedClientCapabilityFlags: HostCapabilityFlags =
        [
            .supportsH264,
            .supportsHEVC,
            .supportsMultiDisplay,
            .supportsAudioLater,
            .supportsTerminal,
            .supportsMultipleTerminals,
            .supportsTerminalChat,
            .supportsTaskPlans,
            .supportsWorkspaces
        ]

    /// Capabilities the connected client advertised in its session offer, if any.
    /// `nil` until an offer with capabilities arrives (older clients leave it nil).
    private var advertisedClientCapabilities: HostCapabilityFlags?

    private var sessionStartsWithAppBrowser: Bool {
        productMode.startsWithAppBrowser(for: effectiveClientCapabilities)
    }

    private var hostCapabilityFlags: HostCapabilityFlags {
        if productMode.isTerminalOnly || activeSessionIsTerminalOnly {
            return HostProductMode.terminalOnly.advertisedCapabilities
        }
        if productMode == .mini {
            return productMode.sessionCapabilities(for: effectiveClientCapabilities)
        }
        return Self.fullHostCapabilityFlags
    }

    /// The client capabilities to negotiate against: the client's own advertisement
    /// when present, otherwise the assumed baseline for older clients.
    private var effectiveClientCapabilities: HostCapabilityFlags {
        advertisedClientCapabilities ?? Self.assumedClientCapabilityFlags
    }

    /// Capabilities agreed between host and client. Falls back to an H.264-only
    /// baseline if negotiation ever fails, so a session always has a usable codec.
    private var negotiatedCapabilities: NegotiatedCapabilities {
        CapabilityNegotiator.negotiate(host: hostCapabilityFlags, client: effectiveClientCapabilities)
            ?? NegotiatedCapabilities(videoCodec: .h264, supportsMultiDisplay: false, supportsAudio: false, supportsMacClient: false)
    }

    /// Codec the encoder should produce, mapped from the negotiated capabilities.
    /// HEVC when both peers support it (decodes higher resolutions in hardware on
    /// iOS than H.264, and compresses better at the same bitrate); H.264 otherwise.
    private var negotiatedEncoderCodec: EncodedFrameCodec {
        switch negotiatedCapabilities.videoCodec {
        case .hevc: return .hevc
        case .h264: return .h264
        }
    }

    /// Whether capture should run at high resolution (4K for balanced/quality).
    /// Derived from the encoder's *actual* configured codec — not the negotiated one —
    /// so it tracks the H.264 fallback in `configure` and keeps capture and encode
    /// dimensions in lockstep. Always read after `encoderPipeline.configure(...)`.
    private var captureAllowsHighResolution: Bool {
        encoderPipeline.encoderDiagnostics.configuredCodec == .hevc
    }

    private var negotiatedDynamicRange: StreamDynamicRange {
        requestedDynamicRange == .hdr10 && negotiatedCapabilities.supportsHDR10
            ? .hdr10
            : .sdr
    }

    private var captureDynamicRange: StreamDynamicRange {
        encoderPipeline.encoderDiagnostics.configuredCodec == .hevc
            ? negotiatedDynamicRange
            : .sdr
    }

    private func publishInitialSessionState(sessionID: UUID) async {
        guard !hasPublishedInitialSessionState else { return }
        hasPublishedInitialSessionState = true

        do {
            if productMode.isTerminalOnly || activeSessionIsTerminalOnly {
                try await sendSignalingEvent(
                    .sessionReady(
                        SessionReadyMessage(
                            sessionID: sessionID,
                            selectedDisplayID: nil,
                            negotiatedCapabilities: negotiatedCapabilities,
                            lockState: lockStateProvider()
                        )
                    ),
                    sessionID: sessionID,
                    recipient: nil
                )
                phase = .streaming
                return
            }

            if sessionStartsWithAppBrowser {
                try await sendSignalingEvent(
                    .sessionReady(
                        SessionReadyMessage(
                            sessionID: sessionID,
                            selectedDisplayID: nil,
                            negotiatedCapabilities: negotiatedCapabilities,
                            lockState: lockStateProvider()
                        )
                    ),
                    sessionID: sessionID,
                    recipient: nil
                )

                let layout = try await displayLayoutProvider.currentDisplayLayout()
                let sentImmediately = sendAppStreamingInitialState(layout: layout, sessionID: sessionID)
                if !sentImmediately {
                    scheduleAppStreamingInitialStateRetry(layout: layout, sessionID: sessionID)
                }
                phase = .streaming
                return
            }

            let layout = try await displayLayoutProvider.currentDisplayLayout()
            let selectedDisplayID = captureEngine.diagnostics.currentDisplayID ?? layout.primaryDisplayID

            // Use real capability negotiation
            let negotiated = negotiatedCapabilities

            // Send session-ready via signaling (reliable path)
            try await sendSignalingEvent(
                .sessionReady(
                    SessionReadyMessage(
                        sessionID: sessionID,
                        selectedDisplayID: selectedDisplayID,
                        negotiatedCapabilities: negotiated,
                        lockState: lockStateProvider()
                    )
                ),
                sessionID: sessionID,
                recipient: nil
            )

            let sentImmediately = sendInitialDataChannelState(layout: layout, sessionID: sessionID)
            if !sentImmediately {
                logger.info("Data channel messages deferred (channels not yet open). Scheduling retry.")
                scheduleInitialDataChannelStateRetry(layout: layout, sessionID: sessionID)
            }

            phase = .streaming
        } catch {
            hasPublishedInitialSessionState = false
            logger.warning("Failed to publish initial session state: \(error.localizedDescription)")
        }
    }

    private func sendInitialDataChannelState(layout: DisplayLayout, sessionID: UUID) -> Bool {
        sendDisplayStateMessages(layout: layout, sessionID: sessionID, reason: "initial")
    }

    /// Publish only connection/layout state for Vamp Sync. Sending a display
    /// configuration here would tell the client that the primary display is the
    /// active stream even though no capture exists yet.
    private func sendAppStreamingInitialState(layout: DisplayLayout, sessionID: UUID) -> Bool {
        guard activeSessionID == sessionID else { return false }
        do {
            try webRTCSessionManager.sendDataMessage(
                try DataChannelEnvelope.displayLayout(DisplayLayoutMessage(layout: layout))
            )
            try webRTCSessionManager.sendDataMessage(
                try DataChannelEnvelope.hostStatus(
                    HostStatusMessage(
                        hostID: hostIdentity.id,
                        connectionState: .connected,
                        activeSessionID: sessionID,
                        displayLayout: layout,
                        selectedDisplayID: nil,
                        sessionMode: sessionModeController.currentMode,
                        quality: nil,
                        thermalState: performanceStateController.thermalState,
                        lowPowerModeEnabled: performanceStateController.lowPowerModeEnabled,
                        lockState: lockStateProvider()
                    )
                )
            )
            hasSentInitialDataChannelState = true
            initialDataChannelRetryTask?.cancel()
            initialDataChannelRetryTask = nil
            return true
        } catch {
            return false
        }
    }

    private func scheduleAppStreamingInitialStateRetry(layout: DisplayLayout, sessionID: UUID) {
        initialDataChannelRetryTask?.cancel()
        initialDataChannelRetryTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<initialDataChannelRetryAttempts {
                try? await Task.sleep(nanoseconds: initialDataChannelRetryDelayMs * 1_000_000)
                guard !Task.isCancelled, self.activeSessionID == sessionID else { return }
                if self.hasSentInitialDataChannelState { return }
                if self.sendAppStreamingInitialState(layout: layout, sessionID: sessionID) { return }
            }
        }
    }

    private func scheduleInitialDataChannelStateRetry(layout: DisplayLayout, sessionID: UUID) {
        initialDataChannelRetryTask?.cancel()
        initialDataChannelRetryTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<initialDataChannelRetryAttempts {
                try? await Task.sleep(nanoseconds: initialDataChannelRetryDelayMs * 1_000_000)
                guard !Task.isCancelled else { return }
                guard self.activeSessionID == sessionID else { return }
                if self.hasSentInitialDataChannelState { return }

                // Wait for transport readiness rather than burning retries while closed.
                if self.webRTCSessionManager.connectionState != .connected ||
                    self.webRTCSessionManager.dataChannelState != .open {
                    continue
                }

                if self.sendInitialDataChannelState(layout: layout, sessionID: sessionID) {
                    self.logger.info("Initial data channel messages sent after retry")
                    return
                }
            }
            self.logger.warning(
                "Initial data channel messages could not be sent after retries (connection=\(self.webRTCSessionManager.connectionState.rawValue), dataChannel=\(self.webRTCSessionManager.dataChannelState.rawValue))"
            )
        }
    }

    private func sendSignalingEvent(
        _ event: SignalingEvent,
        sessionID: UUID,
        recipient: SignalingPeer?
    ) async throws {
        let envelope = VersionedSignalingMessage(
            envelope: SignalingEnvelope(
                protocolVersion: RemoteDesktopConstants.protocolVersion,
                sessionID: sessionID,
                sender: SignalingPeer(
                    id: hostIdentity.id,
                    role: .host,
                    displayName: hostIdentity.displayName,
                    publicKeyFingerprint: hostIdentity.publicKeyFingerprint
                ),
                recipient: recipient,
                event: event
            )
        )
        try await signalingService.sendSignalingMessage(envelope)
    }

    func publishHostStatusUpdate() async {
        guard let sessionID = activeSessionID else { return }
        do {
            let displayLayout = try await displayLayoutProvider.currentDisplayLayout()
            #if os(macOS)
            let activeWindow = activeWindowTarget
            let layout = activeWindow.map {
                DisplayLayout(
                    displays: [$0.descriptor],
                    primaryDisplayID: $0.descriptor.id,
                    virtualBounds: $0.descriptor.frame
                )
            } ?? displayLayout
            let selectedDisplayID = activeWindow?.descriptor.id
                ?? captureEngine.diagnostics.currentDisplayID ?? layout.primaryDisplayID
            #else
            let layout = displayLayout
            let selectedDisplayID = captureEngine.diagnostics.currentDisplayID ?? layout.primaryDisplayID
            #endif
            let statusEnvelope = try DataChannelEnvelope.hostStatus(
                HostStatusMessage(
                    hostID: hostIdentity.id,
                    connectionState: webRTCSessionManager.connectionState,
                    activeSessionID: sessionID,
                    displayLayout: layout,
                    selectedDisplayID: selectedDisplayID,
                    sessionMode: sessionModeController.currentMode,
                    quality: nil,
                    thermalState: performanceStateController.thermalState,
                    lowPowerModeEnabled: performanceStateController.lowPowerModeEnabled,
                    lockState: lockStateProvider()
                )
            )
            try webRTCSessionManager.sendDataMessage(statusEnvelope)
        } catch {
            logger.info("Host status update deferred: \(error.localizedDescription)")
        }
    }

    /// Reconcile the set of additional displays streamed in parallel with the client's
    /// request. Index 0 of the request is the primary (the existing pipeline, wire ID 0);
    /// 1..n are streamed concurrently on wire IDs 1..n (capped to bound HW encoders).
    private func handleSetActiveDisplays(_ message: SetActiveDisplaysMessage) async {
        #if os(macOS)
        // Every step below logs to the event store (which the user can export) so a silently
        // dropped multi-display request names its exact reason instead of a black/blank screen.
        await eventLogStore.append(EventLogItem(
            severity: .info, category: "Display",
            message: "Multi-display request received: [\(message.displayIDs.joined(separator: ", "))]"))

        guard activeSessionID == message.sessionID else {
            await eventLogStore.append(EventLogItem(
                severity: .warning, category: "Display",
                message: "Multi-display request rejected: session-ID mismatch"))
            return
        }
        guard negotiatedCapabilities.supportsMultiDisplay else {
            await eventLogStore.append(EventLogItem(
                severity: .warning, category: "Display",
                message: "Multi-display request ignored: the peer didn't negotiate multi-display support"))
            return
        }
        let secondaryIDs = Array(message.displayIDs.dropFirst().prefix(3))

        // Stop streamers that are no longer requested.
        for (id, streamer) in secondaryStreamers where !secondaryIDs.contains(id) {
            await streamer.stop()
            secondaryStreamers[id] = nil
        }
        guard !secondaryIDs.isEmpty else {
            await eventLogStore.append(EventLogItem(
                severity: .info, category: "Display",
                message: "Multi-display: client requested no secondary displays — only the primary streams (it sent \(message.displayIDs.count) display ID(s); after de-duping the primary, none remained)"))
            return
        }
        guard let layout = try? await displayLayoutProvider.currentDisplayLayout() else {
            await eventLogStore.append(EventLogItem(
                severity: .warning, category: "Display",
                message: "Multi-display request ignored: couldn't read the host display layout"))
            return
        }
        await eventLogStore.append(EventLogItem(
            severity: .info, category: "Display",
            message: "Host sees \(layout.displays.count) display(s): [\(layout.displays.map { $0.id }.joined(separator: ", "))]; starting secondaries [\(secondaryIDs.joined(separator: ", "))]"))
        let preset = minQualityPreset(performanceStateController.profile.effectivePreset, .balanced)

        var updated: [String: SecondaryDisplayStreamer] = [:]
        for (offset, displayID) in secondaryIDs.enumerated() {
            let wireID = UInt8(offset + 1)
            // Reuse a running streamer whose wire ID is unchanged; otherwise (re)start it.
            if let existing = secondaryStreamers.removeValue(forKey: displayID), existing.wireDisplayID == wireID {
                existing.forceKeyframe()
                updated[displayID] = existing
                continue
            }
            if let stale = secondaryStreamers.removeValue(forKey: displayID) {
                await stale.stop()
            }
            guard let display = layout.display(withID: displayID) else {
                await eventLogStore.append(EventLogItem(
                    severity: .warning, category: "Display",
                    message: "Multi-display: requested display \(displayID) isn't in the host's layout — skipping (the client's display list is likely stale; reconnect to refresh it)"))
                continue
            }
            let streamer = SecondaryDisplayStreamer(
                wireDisplayID: wireID, displayID: displayID, webRTCSessionManager: webRTCSessionManager)
            do {
                try await streamer.start(display: display, preset: preset, codec: negotiatedEncoderCodec, dynamicRange: captureDynamicRange)
                updated[displayID] = streamer
                await eventLogStore.append(EventLogItem(
                    severity: .info, category: "Display",
                    message: "Secondary display “\(display.name)” streaming (wire \(wireID), \(captureDynamicRange == .hdr10 ? "HDR10" : "SDR"))"))
            } catch {
                logger.warning("Secondary display failed to start: \(error.localizedDescription, privacy: .public)")
                await eventLogStore.append(EventLogItem(
                    severity: .warning, category: "Display",
                    message: "Secondary display “\(display.name)” failed to start: \(error.localizedDescription)"))
            }
        }
        for (_, streamer) in secondaryStreamers { await streamer.stop() }
        secondaryStreamers = updated
        #endif
    }

    private func stopAllSecondaryStreamers() async {
        #if os(macOS)
        for (_, streamer) in secondaryStreamers { await streamer.stop() }
        secondaryStreamers.removeAll()
        #endif
    }

    func handleDisplaySwitchRequest(_ request: DisplaySwitchRequestMessage) async {
        guard activeSessionID == request.sessionID else { return }

        let startTime = Date()
        let currentDisplayID = captureEngine.diagnostics.currentDisplayID
        #if os(macOS)
        let previousWindow = activeWindowTarget
        let previousApplicationName = activeApplicationName
        let alreadyShowingDisplay = previousWindow == nil && currentDisplayID == request.targetDisplayID
        #else
        let alreadyShowingDisplay = currentDisplayID == request.targetDisplayID
        #endif

        if alreadyShowingDisplay {
            let result = DisplaySwitchResultMessage(
                sessionID: request.sessionID,
                selectedDisplayID: request.targetDisplayID,
                senderDeviceID: request.senderDeviceID,
                status: .completed,
                startedAt: startTime
            )
            if let envelope = try? DataChannelEnvelope.displaySwitchResult(result) {
                try? webRTCSessionManager.sendDataMessage(envelope)
            }
            return
        }

        guard let layout = try? await displayLayoutProvider.currentDisplayLayout(),
              let display = layout.display(withID: request.targetDisplayID) else {
            let result = DisplaySwitchResultMessage(
                sessionID: request.sessionID,
                selectedDisplayID: currentDisplayID ?? request.targetDisplayID,
                senderDeviceID: request.senderDeviceID,
                status: .failed,
                reason: "Display is no longer available.",
                startedAt: startTime
            )
            if let envelope = try? DataChannelEnvelope.displaySwitchResult(result) {
                try? webRTCSessionManager.sendDataMessage(envelope)
            }
            return
        }

        let qualityPreset = minQualityPreset(
            performanceStateController.profile.effectivePreset,
            .balanced
        )

        let accepted = DisplaySwitchResultMessage(
            sessionID: request.sessionID,
            selectedDisplayID: request.targetDisplayID,
            senderDeviceID: request.senderDeviceID,
            status: .accepted,
            startedAt: startTime
        )
        if let envelope = try? DataChannelEnvelope.displaySwitchResult(accepted) {
            try? webRTCSessionManager.sendDataMessage(envelope)
        }

        do {
            try await restartStreamingPipeline(
                for: display,
                layout: layout,
                sessionID: request.sessionID,
                qualityPreset: qualityPreset,
                reason: "display_switch"
            )
            await publishHostStatusUpdate()

            let completed = DisplaySwitchResultMessage(
                sessionID: request.sessionID,
                selectedDisplayID: request.targetDisplayID,
                senderDeviceID: request.senderDeviceID,
                status: .completed,
                startedAt: startTime
            )
            if let envelope = try? DataChannelEnvelope.displaySwitchResult(completed) {
                try? webRTCSessionManager.sendDataMessage(envelope)
            }
        } catch {
            #if os(macOS)
            if let previousWindow {
                do {
                    try await restartStreamingPipelineForWindow(descriptor: previousWindow.descriptor,
                        windowID: previousWindow.windowID, qualityPreset: qualityPreset)
                    activeWindowTarget = previousWindow
                    activeApplicationName = previousApplicationName
                    updateWindowInputGeometry(descriptor: previousWindow.descriptor)
                    startWindowTracking(sessionID: request.sessionID, senderDeviceID: request.senderDeviceID)
                } catch {
                    logger.warning("Could not restore window capture after display-switch failure")
                }
            }
            #endif
            if let fallbackID = currentDisplayID,
               let fallbackDisplay = layout.display(withID: fallbackID) {
                try? await encoderPipeline.configure(
                    for: fallbackDisplay,
                    qualityPreset: qualityPreset,
                    codec: negotiatedEncoderCodec,
                    dynamicRange: negotiatedDynamicRange
                )
                try? await encoderPipeline.startEncoding()
                try? await captureEngine.startCapture(
                    displayID: fallbackID,
                    qualityPreset: qualityPreset,
                    allowsHighResolution: captureAllowsHighResolution,
                    dynamicRange: captureDynamicRange
                )
                encoderPipeline.forceKeyframe()
                startAdaptiveStreamingControl(for: qualityPreset)
                markActiveStreamDisplay(fallbackDisplay)
                if let sessionID = activeSessionID {
                    _ = sendDisplayStateMessages(layout: layout, sessionID: sessionID, reason: "display_switch_fallback", overrideDisplay: fallbackDisplay)
                }
            }
            await publishHostStatusUpdate()

            let failed = DisplaySwitchResultMessage(
                sessionID: request.sessionID,
                selectedDisplayID: currentDisplayID ?? request.targetDisplayID,
                senderDeviceID: request.senderDeviceID,
                status: .failed,
                reason: "Could not switch displays. Keeping the previous screen.",
                startedAt: startTime
            )
            if let envelope = try? DataChannelEnvelope.displaySwitchResult(failed) {
                try? webRTCSessionManager.sendDataMessage(envelope)
            }
        }
    }

    func applyPerformanceProfileIfNeeded() async {
        guard let sessionID = activeSessionID else { return }
        guard phase == .streaming else { return }
        guard let displayID = captureEngine.diagnostics.currentDisplayID else { return }
        let targetPreset = performanceStateController.profile.effectivePreset

        guard captureEngine.diagnostics.qualityPreset != targetPreset else {
            await publishHostStatusUpdate()
            return
        }

        guard !isApplyingPerformanceProfile else {
            needsPerformanceProfileReapply = true
            return
        }
        isApplyingPerformanceProfile = true
        defer {
            isApplyingPerformanceProfile = false
            if needsPerformanceProfileReapply {
                needsPerformanceProfileReapply = false
                Task { @MainActor [weak self] in
                    await self?.applyPerformanceProfileIfNeeded()
                }
            }
        }

        do {
            let layout = try await displayLayoutProvider.currentDisplayLayout()
            guard activeSessionID == sessionID, phase == .streaming else { return }
            guard captureEngine.diagnostics.qualityPreset != targetPreset else {
                await publishHostStatusUpdate()
                return
            }
            guard let display = layout.display(withID: displayID) else { return }
            try await restartPipelineForCurrentDisplay(
                display: display,
                qualityPreset: targetPreset
            )
            _ = sendDisplayStateMessages(layout: layout, sessionID: sessionID, reason: "performance_profile", overrideDisplay: display)
            await publishHostStatusUpdate()

            await eventLogStore.append(EventLogItem(
                severity: performanceStateController.thermalState == .serious || performanceStateController.thermalState == .critical ? .warning : .info,
                category: "Performance",
                message: "Applied performance profile \(targetPreset.rawValue) for session \(sessionID.uuidString)",
                metadata: [
                    "thermalState": performanceStateController.thermalState.rawValue,
                    "lowPowerModeEnabled": performanceStateController.lowPowerModeEnabled ? "true" : "false"
                ]
            ))
        } catch {
            await eventLogStore.append(EventLogItem(
                severity: .warning,
                category: "Performance",
                message: "Failed to apply performance profile: \(error.localizedDescription)"
            ))
        }
    }
}

#if os(macOS)
import AppKit
import ApplicationServices

// MARK: - App Streaming (window target)
//
// These reuse the existing streaming pipeline wholesale. A window target differs from a display
// target in exactly three ways: the capture filter (ScreenCaptureEngine.startCapture(windowID:)),
// the encoder's `DisplayDescriptor` (synthesized from the window's pixel size), and the input
// layout (a synthetic single-"display" layout keyed to the window origin). Everything else —
// WebRTC session, data channel, encoder, adaptive control, input injection — is untouched, and
// the WebRTC connection is never torn down when the target changes.
extension HostSessionCoordinator {

    /// Client → host: publish the current application registry.
    func handleApplicationListRequest(_ message: ApplicationListRequestMessage) async {
        guard activeSessionID == message.sessionID else { return }
        if (message.offset ?? 0) == 0 {
            targetSwitchTask?.cancel()
            await targetSwitchTask?.value
            targetSwitchTask = nil
            applicationListSnapshot = applicationRegistry.snapshot()
        }
        // Returning to the app browser is also the explicit end of a window stream. Stop
        // capture before publishing the new inventory so the host does not keep encoding
        // an invisible window between app selections.
        if activeWindowTarget != nil {
            await stopActiveWindowStream()
        }
        if let envelope = Self.applicationListEnvelope(
            applications: applicationListSnapshot,
            sessionID: message.sessionID,
            senderDeviceID: message.senderDeviceID,
            offset: message.offset ?? 0,
            preservesIconsAcrossPages: message.offset != nil
        ) {
            try? webRTCSessionManager.sendDataMessage(envelope)
        }
    }

    /// The control channel drops any inbound message larger than 128 KB, and a Mac with a
    /// full /Applications encodes to several hundred KB once every icon is attached — the
    /// browser then waits forever for a snapshot that was thrown away in transit. Shed icons
    /// until the envelope fits; running apps keep theirs longest because that is the section
    /// people actually look at.
    nonisolated static func applicationListEnvelope(
        applications: [RemoteApplication], sessionID: UUID, senderDeviceID: UUID,
        offset: Int = 0, preservesIconsAcrossPages: Bool = true
    ) -> DataChannelEnvelope? {
        guard offset >= 0, offset <= applications.count else { return nil }
        let remaining = Array(applications.dropFirst(offset).prefix(512))
        var count = remaining.count
        while true {
            let page = Array(remaining.prefix(count))
            let legacyCandidates = count == remaining.count
                ? [page, page.map { $0.isRunning ? $0 : $0.withoutIcon }, page.map(\.withoutIcon)]
                : [page.map(\.withoutIcon)]
            // Page before shedding icons. Only an individually oversized icon may
            // be omitted; old clients without an offset retain their single-list fallback.
            let candidates = preservesIconsAcrossPages
                ? (count == 1 ? [page, page.map(\.withoutIcon)] : [page])
                : legacyCandidates
            for candidate in candidates {
                let next = offset + count
                let snapshot = ApplicationListSnapshotMessage(
                    sessionID: sessionID, senderDeviceID: senderDeviceID,
                    applications: candidate, offset: offset,
                    nextOffset: next < applications.count ? next : nil)
                guard let envelope = try? DataChannelEnvelope.applicationListSnapshot(snapshot),
                      let size = try? envelope.wireEncode().count else { return nil }
                if size <= applicationListByteBudget {
                    // Never emit a page that cannot advance. The caller's bounded retry
                    // reports an error for an individually unrepresentable entry.
                    guard count > 0 || offset == applications.count else { return nil }
                    return envelope
                }
            }
            guard count > 0 else { return nil }
            count /= 2
        }
    }

    /// Under `WebRTCSessionManager.maxInboundControlMessageBytes` (128 KB) with room for the
    /// authentication nonce/tag that `sendDataMessage` adds after this measurement.
    nonisolated static let applicationListByteBudget = 112 * 1024

    /// Client → host: quit a running application with a normal terminate request.
    func handleApplicationCloseRequest(_ message: ApplicationCloseRequestMessage) async {
        guard activeSessionID == message.sessionID else { return }
        let hostBundle = Bundle.main.bundleIdentifier
        guard let bundleID = ApplicationClosePolicy.normalizedBundleIdentifier(message.bundleIdentifier),
              ApplicationClosePolicy.canClose(bundleID, hostBundleIdentifier: hostBundle) else {
            sendCloseResult(
                request: message,
                status: .rejected,
                reason: "That application cannot be closed remotely."
            )
            return
        }

        if activeWindowTarget?.bundleIdentifier == bundleID {
            targetSwitchTask?.cancel()
            await targetSwitchTask?.value
            targetSwitchTask = nil
            await stopActiveWindowStream()
        }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.isEmpty {
            sendCloseResult(request: message, status: .completed, reason: nil)
            return
        }

        let displayName = running.first?.localizedName ?? bundleID
        await MainActor.run {
            for application in running {
                _ = application.terminate()
            }
        }

        var stillRunning = true
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                stillRunning = false
                break
            }
        }

        if stillRunning {
            sendCloseResult(
                request: message,
                status: .failed,
                reason: "\(displayName) did not quit. It may have unsaved changes."
            )
        } else {
            sendCloseResult(request: message, status: .completed, reason: nil)
        }
    }

    private func sendCloseResult(
        request: ApplicationCloseRequestMessage,
        status: DisplaySwitchStatus,
        reason: String?
    ) {
        let message = ApplicationCloseResultMessage(
            sessionID: request.sessionID,
            bundleIdentifier: request.bundleIdentifier,
            senderDeviceID: request.senderDeviceID,
            status: status,
            reason: reason,
            requestID: request.requestID
        )
        if let envelope = try? DataChannelEnvelope.applicationCloseResult(message) {
            try? webRTCSessionManager.sendDataMessage(envelope)
        }
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "AppStreaming",
                message: "Application close \(status.rawValue): \(request.bundleIdentifier)"
            ))
        }
    }

    /// Client → host: retarget the live stream. Reuses the proven display-switch path for a
    /// `.display` target; resolves + captures a window for `.window` / `.application`.
    func handleStreamTargetSwitchRequest(_ message: StreamTargetSwitchRequestMessage) async {
        guard activeSessionID == message.sessionID else { return }
        let previous = targetSwitchTask
        previous?.cancel()
        targetSwitchTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.activeSessionID == message.sessionID else { return }
            await self.performStreamTargetSwitch(message)
        }
    }

    private func performStreamTargetSwitch(_ message: StreamTargetSwitchRequestMessage) async {
        let startTime = Date()
        switch message.target.kind {
        case .display:
            if sessionStartsWithAppBrowser {
                sendTargetResult(
                    request: message,
                    resolved: message.target,
                    status: .rejected,
                    reason: "Vamp Sync streams application windows only.",
                    descriptor: nil,
                    startTime: startTime
                )
                return
            }
            // The display-switch path validates the target before releasing window
            // geometry, and restores the window if display capture cannot start.
            await handleDisplaySwitchRequest(DisplaySwitchRequestMessage(
                sessionID: message.sessionID,
                targetDisplayID: message.target.identifier,
                senderDeviceID: message.senderDeviceID,
                requestedAt: message.requestedAt
            ))
        case .window:
            await switchToWindow(windowIDString: message.target.identifier, request: message, startTime: startTime)
        case .application:
            await switchToApplication(
                bundleID: message.target.identifier,
                launchIfNeeded: message.launchIfNeeded,
                request: message,
                startTime: startTime
            )
        }
    }

    // MARK: Target resolution

    private func switchToWindow(windowIDString: String, request: StreamTargetSwitchRequestMessage, startTime: Date) async {
        guard let windowIDValue = CGWindowID(windowIDString),
              let info = applicationRegistry.windowInfo(windowID: windowIDValue) else {
            sendTargetResult(request: request, resolved: request.target, status: .failed,
                             reason: "That window is no longer available.", descriptor: nil, startTime: startTime)
            return
        }
        let owner = NSRunningApplication(processIdentifier: info.ownerPID)
        sendTargetResult(request: request, resolved: .window(windowIDString), status: .accepted,
                         reason: nil, descriptor: nil, startTime: startTime)
        await beginWindowStream(
            window: info,
            bundleID: owner?.bundleIdentifier ?? "",
            name: owner?.localizedName ?? "Application",
            request: request,
            startTime: startTime
        )
    }

    private func switchToApplication(bundleID: String, launchIfNeeded: Bool, request: StreamTargetSwitchRequestMessage, startTime: Date) async {
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if existing == nil && !launchIfNeeded {
            sendTargetResult(request: request, resolved: request.target, status: .failed,
                             reason: "\(bundleID) is not running.", descriptor: nil, startTime: startTime)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            sendTargetResult(request: request, resolved: request.target, status: .failed,
                             reason: "\(bundleID) is not installed.", descriptor: nil, startTime: startTime)
            return
        }

        sendTargetResult(request: request, resolved: request.target, status: .accepted,
                         reason: nil, descriptor: nil, startTime: startTime)

        // openApplication launches if needed and activates if already running — one API, no
        // deprecated activate(options:) and no launch/activate race to reason about.
        let runningApp: NSRunningApplication
        do {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            runningApp = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            sendTargetResult(request: request, resolved: request.target, status: .failed,
                             reason: "Could not launch \(bundleID): \(error.localizedDescription)", descriptor: nil, startTime: startTime)
            return
        }

        // Mirror Vamp Assistant's proven launch loop: accept an existing
        // shareable window, ask a windowless app to create one early, and keep
        // polling ScreenCaptureKit for a bounded ten seconds.
        var window: WindowInfo?
        var requestedNewWindow = false
        // A cold launch presents its own window; asking for another one a second in races the
        // app's own startup and can leave a stray extra window behind. Only an app that was
        // already running — hidden, minimised, or with every window closed — needs the nudge early.
        let nudgeAttempt = existing == nil ? 16 : 4
        for attempt in 0..<40 {
            guard !Task.isCancelled, activeSessionID == request.sessionID, !lockStateProvider().blocksRemoteInput else { return }
            if let candidate = applicationRegistry.streamableWindow(forPID: runningApp.processIdentifier),
               await applicationRegistry.isShareableWindow(candidate.windowID) {
                window = candidate
                break
            }
            if attempt == nudgeAttempt, !requestedNewWindow {
                requestedNewWindow = true
                Self.restoreOrCreateWindow(for: runningApp, bundleID: bundleID)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let window else {
            sendTargetResult(request: request, resolved: request.target, status: .failed,
                             reason: "\(runningApp.localizedName ?? bundleID) did not create a streamable window. Open a window on the Mac and try again.",
                             descriptor: nil, startTime: startTime)
            return
        }
        await beginWindowStream(
            window: window,
            bundleID: bundleID,
            name: runningApp.localizedName ?? "Application",
            request: request,
            startTime: startTime
        )
    }

    /// Restore a minimized focused window when possible; otherwise request the app's standard
    /// New Window/New Document action. Key events are posted only to the selected process.
    private static func restoreOrCreateWindow(
        for application: NSRunningApplication,
        bundleID: String
    ) {
        application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        // Finder is always running and its desktop is not a streamable normal window. Opening
        // the user's home folder is the supported way to make Finder present a real window;
        // relying on activation alone leaves the app stream waiting forever.
        if bundleID == "com.apple.finder" {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
            return
        }

        // Safari can materialize a real window through an open-document event,
        // exactly as Vamp Assistant does, without relying on a global key event.
        if bundleID == "com.apple.Safari",
           let applicationURL = application.bundleURL,
           let blankURL = URL(string: "about:blank") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [blankURL],
                withApplicationAt: applicationURL,
                configuration: configuration,
                completionHandler: nil
            )
            return
        }

        let axApp = AXUIElementCreateApplication(application.processIdentifier)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement], let window = windows.first {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 45, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 45, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // Deliver to the selected process only. The HID tap is global: if activation has not
        // landed yet, a Cmd+N there opens a window in whatever app happens to be frontmost.
        keyDown.postToPid(application.processIdentifier)
        keyUp.postToPid(application.processIdentifier)
    }

    // MARK: Capture

    private func beginWindowStream(window rawWindow: WindowInfo, bundleID: String, name: String, request: StreamTargetSwitchRequestMessage, startTime: Date) async {
        guard !Task.isCancelled, activeSessionID == request.sessionID, !lockStateProvider().blocksRemoteInput else { return }
        // Drain a canceled geometry restart before replacing its capture pipeline.
        let previousTracking = windowTrackingTask
        previousTracking?.cancel()
        await previousTracking?.value
        guard !Task.isCancelled, activeSessionID == request.sessionID, !lockStateProvider().blocksRemoteInput else { return }
        isWindowStreamTransitioning = true
        defer { isWindowStreamTransitioning = false }
        var window = rawWindow
        let originalKey = "\(request.sessionID)-\(window.ownerPID)-\(window.windowID)"
        let original = originalAppWindowBounds[originalKey] ?? window.bounds
        if originalAppWindowBounds.count >= 128, originalAppWindowBounds[originalKey] == nil {
            originalAppWindowBounds.removeAll()
        }
        originalAppWindowBounds[originalKey] = original
        var sizingNotice: String?
        if request.sizingMode != nil || request.clientViewportAspect != nil {
            let display = HostApplicationRegistry.displayBounds(containing:
                CGRect(x: window.bounds.origin.x, y: window.bounds.origin.y,
                       width: window.bounds.size.width, height: window.bounds.size.height))
            let available = DesktopSize(width: max(display.width - 48, 1), height: max(display.height - 76, 1))
            let aspect = request.clientViewportAspect ?? (window.bounds.size.width / window.bounds.size.height)
            let viewport = DesktopSize(width: request.viewportWidth ?? aspect, height: request.viewportHeight ?? 1)
            let desired = request.sizingMode == .original ? original.size : AdaptiveWindowSizing.size(
                original: original.size, available: available, viewport: viewport, bundleIdentifier: bundleID)
            if !Self.resizeWindow(pid: window.ownerPID, matching: window.bounds, toSize: desired, display: display) {
                sizingNotice = "The selected window could not be resized safely. Keeping its current size."
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let resized = applicationRegistry.windowInfo(windowID: window.windowID) { window = resized }
            if request.sizingMode == .original,
               abs(window.bounds.size.width - desired.width) > 2 || abs(window.bounds.size.height - desired.height) > 2 {
                sizingNotice = "The Mac constrained the original window size to its available space."
            }
            let actualAspect = window.bounds.size.width / max(window.bounds.size.height, 1)
            if sizingNotice == nil, request.sizingMode != .original,
               abs(actualAspect - viewport.width / max(viewport.height, 1)) > 0.05 {
                sizingNotice = "Keeping a usable app width. Zoom or pan for a closer view."
            }
        }
        guard !Task.isCancelled, activeSessionID == request.sessionID, !lockStateProvider().blocksRemoteInput else { return }
        let scale = applicationRegistry.windowScaleFactor(bounds: window.bounds)
        let descriptor = Self.windowDescriptor(windowID: window.windowID, name: name, bounds: window.bounds, scale: scale)
        // Preserve the quality negotiated for this session. The adaptive controller
        // can lower bitrate/FPS under congestion, and the performance controller can
        // downgrade for power or thermals; a fixed Balanced cap here only discarded
        // resolution before either adaptive system had a chance to operate.
        let preset = performanceStateController.profile.effectivePreset

        clearWindowStreaming()

        // Input must map into the window from the first frame.
        updateWindowInputGeometry(descriptor: descriptor)

        do {
            try await restartStreamingPipelineForWindow(descriptor: descriptor, windowID: window.windowID, qualityPreset: preset)
            guard !Task.isCancelled, activeSessionID == request.sessionID else {
                await stopWindowStreamPipeline()
                clearWindowStreaming()
                return
            }
            activeWindowTarget = WindowStreamTarget(
                windowID: window.windowID,
                ownerPID: window.ownerPID,
                bundleIdentifier: bundleID,
                descriptor: descriptor
            )
            activeApplicationName = name
            startWindowTracking(sessionID: request.sessionID, senderDeviceID: request.senderDeviceID)
            await publishHostStatusUpdate()
            sendTargetResult(request: request, resolved: .window(String(window.windowID)), status: .completed,
                             reason: sizingNotice, descriptor: descriptor, startTime: startTime)
        } catch {
            clearWindowStreaming()
            sendTargetResult(request: request, resolved: request.target, status: .failed,
                             reason: "Could not start window capture: \(error.localizedDescription)",
                             descriptor: nil, startTime: startTime)
        }
    }

    private func restartStreamingPipelineForWindow(descriptor: DisplayDescriptor, windowID: CGWindowID, qualityPreset: StreamQualityPreset) async throws {
        streamingCoordinator.handleDisplayRestart()
        await captureEngine.stopCapture()
        await encoderPipeline.stopEncoding()
        // Window capture is SDR-only (ScreenCaptureEngine.startCapture(windowID:)); pin the
        // encoder to SDR so capture/encode never disagree on bit depth.
        try await encoderPipeline.configure(
            for: descriptor,
            qualityPreset: qualityPreset,
            codec: negotiatedEncoderCodec,
            dynamicRange: .sdr
        )
        try await encoderPipeline.startEncoding()
        try await captureEngine.startCapture(
            windowID: String(windowID),
            qualityPreset: qualityPreset,
            allowsHighResolution: captureAllowsHighResolution
        )
        encoderPipeline.forceKeyframe()
        startAdaptiveStreamingControl(for: qualityPreset)
        try await waitForFirstFrame(timeoutSeconds: startupFirstFrameTimeoutSeconds)
        // The window descriptor's id is a windowID, so display-layout recovery never matches it —
        // a monitor reconfigure won't clobber the window stream (it drops to target-lost instead).
        markActiveStreamDisplay(descriptor)
    }

    // MARK: Window tracking (movement + loss)

    private func startWindowTracking(sessionID: UUID, senderDeviceID: UUID) {
        windowTrackingTask?.cancel()
        // Inherits @MainActor from the enclosing coordinator, so member access is main-isolated.
        windowTrackingTask = Task { [weak self] in
            var misses = 0
            var settling: WindowGeometrySample?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                guard let target = self.activeWindowTarget, self.activeSessionID == sessionID else { return }
                if let info = self.applicationRegistry.windowInfo(windowID: target.windowID) {
                    misses = 0
                    let scale = self.applicationRegistry.windowScaleFactor(bounds: info.bounds)
                    let sizeChanged = info.bounds.size != target.descriptor.frame.size
                    let scaleChanged = abs(scale - target.descriptor.scaleFactor) > 0.01
                    // Movement only needs a cheap geometry update. A resize or moving to a
                    // differently-scaled screen requires a fresh encoder/capture configuration
                    // so the video aspect and the input mapper stay in lockstep.
                    if sizeChanged || scaleChanged {
                        // Dragging a window edge changes the frame on every poll, and each
                        // reconfigure tears capture and encode down and builds them back up.
                        // Wait for the geometry to hold still for one tick, so a drag costs
                        // one restart at the end instead of one every 200 ms throughout.
                        let sample = WindowGeometrySample(size: info.bounds.size, scale: scale)
                        let settled = Self.hasSettled(previous: settling, current: sample)
                        settling = sample
                        guard settled else { continue }
                        settling = nil
                        await self.reconfigureWindowStream(
                            target: target,
                            bounds: info.bounds,
                            scale: scale,
                            sessionID: sessionID,
                            senderDeviceID: senderDeviceID
                        )
                    } else {
                        settling = nil
                        if info.bounds.origin != target.descriptor.frame.origin {
                            var updated = target
                            updated.descriptor.frame = DesktopRect(origin: info.bounds.origin, size: updated.descriptor.frame.size)
                            self.activeWindowTarget = updated
                            self.updateWindowInputGeometry(descriptor: updated.descriptor)
                        }
                    }
                } else {
                    // Require two consecutive misses (~400 ms) before declaring loss so a
                    // transient absence (Space switch, brief occlusion) isn't a false positive.
                    misses += 1
                    if misses >= 2 {
                        self.notifyTargetLost(sessionID: sessionID, senderDeviceID: senderDeviceID,
                                              target: .window(String(target.windowID)),
                                              reason: "The application window is no longer available.")
                        await self.stopWindowStreamPipeline()
                        self.clearWindowStreaming()
                        return
                    }
                }
            }
        }
    }

    /// One poll of a streamed window's shape. Scale is compared with a tolerance because it is
    /// a floating-point backing factor, not an exact value.
    struct WindowGeometrySample: Equatable, Sendable {
        let size: DesktopSize
        let scale: Double
    }

    /// True when two consecutive polls saw the same shape, meaning a resize has finished.
    nonisolated static func hasSettled(previous: WindowGeometrySample?, current: WindowGeometrySample) -> Bool {
        guard let previous else { return false }
        return previous.size == current.size && abs(previous.scale - current.scale) <= 0.01
    }

    func clearWindowStreaming() {
        activeWindowTarget = nil
        activeApplicationName = nil
        windowTrackingTask?.cancel()
        windowTrackingTask = nil
        streamWindowGeometry.set(nil)
        activeStreamDisplayRestartKey = nil
    }

    private func stopActiveWindowStream() async {
        guard activeWindowTarget != nil else { return }
        isWindowStreamTransitioning = true
        defer { isWindowStreamTransitioning = false }
        await stopWindowStreamPipeline()
        clearWindowStreaming()
    }

    private func stopWindowStreamPipeline() async {
        adaptiveStreamingTask?.cancel()
        adaptiveStreamingTask = nil
        await captureEngine.stopCapture()
        await encoderPipeline.stopEncoding()
    }

    private func reconfigureWindowStream(
        target: WindowStreamTarget,
        bounds: DesktopRect,
        scale: Double,
        sessionID: UUID,
        senderDeviceID: UUID
    ) async {
        guard !Task.isCancelled, activeSessionID == sessionID else { return }
        isWindowStreamTransitioning = true
        defer { isWindowStreamTransitioning = false }
        let descriptor = Self.windowDescriptor(
            windowID: target.windowID,
            name: target.descriptor.name,
            bounds: bounds,
            scale: scale
        )
        let transition = StreamTargetSwitchRequestMessage(
            sessionID: sessionID, target: .window(String(target.windowID)),
            launchIfNeeded: false, senderDeviceID: senderDeviceID)
        sendTargetResult(request: transition, resolved: transition.target, status: .accepted,
                         reason: nil, descriptor: nil, startTime: Date())
        do {
            try await restartStreamingPipelineForWindow(
                descriptor: descriptor,
                windowID: target.windowID,
                qualityPreset: currentQualityPreset
            )
            guard !Task.isCancelled, activeSessionID == sessionID else {
                await stopWindowStreamPipeline()
                clearWindowStreaming()
                return
            }
            activeWindowTarget = WindowStreamTarget(
                windowID: target.windowID,
                ownerPID: target.ownerPID,
                bundleIdentifier: target.bundleIdentifier,
                descriptor: descriptor
            )
            updateWindowInputGeometry(descriptor: descriptor)
            let request = StreamTargetSwitchRequestMessage(
                sessionID: sessionID,
                target: .window(String(target.windowID)),
                launchIfNeeded: false,
                senderDeviceID: senderDeviceID
            )
            sendTargetResult(
                request: request,
                resolved: .window(String(target.windowID)),
                status: .completed,
                reason: nil,
                descriptor: descriptor,
                startTime: Date()
            )
        } catch {
            await stopWindowStreamPipeline()
            clearWindowStreaming()
            let request = StreamTargetSwitchRequestMessage(
                sessionID: sessionID,
                target: .window(String(target.windowID)),
                launchIfNeeded: false,
                senderDeviceID: senderDeviceID
            )
            sendTargetResult(
                request: request,
                resolved: .window(String(target.windowID)),
                status: .failed,
                reason: "The app window changed size and could not be restarted.",
                descriptor: nil,
                startTime: Date()
            )
        }
    }

    // MARK: Helpers

    private func updateWindowInputGeometry(descriptor: DisplayDescriptor) {
        streamWindowGeometry.set(DisplayLayout(
            displays: [descriptor],
            primaryDisplayID: descriptor.id,
            virtualBounds: descriptor.frame
        ))
    }

    /// Resize only the selected window and honor the bounds actually accepted by macOS.
    /// A missing or ambiguous AX match leaves every window unchanged.
    private static func resizeWindow(pid: pid_t, matching bounds: DesktopRect,
                                     toSize size: DesktopSize, display: CGRect) -> Bool {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        guard let axWindow = axWindow(in: axApp, matching: bounds) else { return false }
        var requestedSize = CGSize(width: min(size.width, max(display.width - 48, 1)),
                                   height: min(size.height, max(display.height - 76, 1)))
        guard let value = AXValueCreate(.cgSize, &requestedSize),
              AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, value) == .success else { return false }
        // Position using the accepted bounds: applications can impose their own minimum size.
        let actual = axFrame(of: axWindow)?.size ?? requestedSize
        var position = CGPoint(x: max(display.minX + 24, min(bounds.origin.x, display.maxX - actual.width - 24)),
                               y: max(display.minY + 52, min(bounds.origin.y, display.maxY - actual.height - 24)))
        if let value = AXValueCreate(.cgPoint, &position) {
            _ = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, value)
        }
        return true
    }

    /// Resize only a unique AX bounds match for the selected capture window.
    private static func axWindow(in axApp: AXUIElement, matching bounds: DesktopRect) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        let target = CGRect(x: bounds.origin.x, y: bounds.origin.y,
                            width: bounds.size.width, height: bounds.size.height)
        guard let index = HostApplicationRegistry.matchingWindowIndex(frames: windows.map { axFrame(of: $0) }, target: target) else { return nil }
        return windows[index]
    }

    /// AX position/size, in the same global top-left point space as `kCGWindowBounds`.
    private static func axFrame(of axWindow: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
              let positionRef, CFGetTypeID(positionRef) == AXValueGetTypeID(),
              AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID(),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func windowDescriptor(windowID: CGWindowID, name: String, bounds: DesktopRect, scale: Double) -> DisplayDescriptor {
        DisplayDescriptor(
            id: String(windowID),
            name: name,
            frame: bounds, // points, CG top-left global — same space as CGEvent + display frames
            visibleFrame: bounds,
            pixelSize: DesktopSize(width: bounds.size.width * scale, height: bounds.size.height * scale),
            scaleFactor: scale,
            refreshRate: nil,
            rotation: 0,
            isPrimary: false,
            isActive: true
        )
    }

    private func notifyTargetLost(sessionID: UUID, senderDeviceID: UUID, target: StreamTarget, reason: String) {
        let message = StreamTargetSwitchResultMessage(
            sessionID: sessionID,
            resolvedTarget: target,
            senderDeviceID: senderDeviceID,
            status: .failed,
            reason: reason,
            startedAt: Date()
        )
        if let envelope = try? DataChannelEnvelope.streamTargetSwitchResult(message) {
            try? webRTCSessionManager.sendDataMessage(envelope)
        }
        Task { await eventLogStore.append(EventLogItem(
            severity: .info, category: "AppStreaming", message: "Stream target lost: \(reason)")) }
    }

    private func sendTargetResult(request: StreamTargetSwitchRequestMessage, resolved: StreamTarget, status: DisplaySwitchStatus, reason: String?, descriptor: DisplayDescriptor?, startTime: Date) {
        let message = StreamTargetSwitchResultMessage(
            sessionID: request.sessionID,
            resolvedTarget: resolved,
            senderDeviceID: request.senderDeviceID,
            status: status,
            reason: reason,
            width: descriptor.map { Int($0.frame.size.width.rounded()) },
            height: descriptor.map { Int($0.frame.size.height.rounded()) },
            scaleFactor: descriptor?.scaleFactor,
            startedAt: startTime,
            requestID: request.requestID,
            appliedSizingMode: request.sizingMode
        )
        if let envelope = try? DataChannelEnvelope.streamTargetSwitchResult(message) {
            try? webRTCSessionManager.sendDataMessage(envelope)
        }
    }
}
#endif
