import CryptoKit
import Diagnostics
import Discovery
import Foundation
import Network
import SharedModels
import SharedProtocol
import SharedUtilities
import TransportWebRTC
import os

/// Keeps HDR opt-in. Ultra controls resolution and frame rate; silently coupling it
/// to HDR makes SDR desktops pass through display-dependent tone mapping and can
/// leave the remote image looking gray or veiled.
enum ClientVideoDynamicRangePolicy {
    static func preferredDynamicRange(
        qualityPreset: StreamQualityPreset,
        clientCapabilities: HostCapabilityFlags?,
        hdrExplicitlyEnabled: Bool
    ) -> StreamDynamicRange? {
        guard hdrExplicitlyEnabled,
              qualityPreset == .ultra,
              clientCapabilities?.contains(.supportsHDR10) == true else {
            return nil
        }
        return .hdr10
    }
}

/// Orchestrates the complete client session lifecycle:
///
/// 1. Browse for hosts via Bonjour
/// 2. Connect to the selected host's signaling endpoint
/// 3. Exchange SDP offer/answer
/// 4. Receive and display video frames from the host
/// 5. Send input commands over the data channel
/// 6. Monitor connection state for reconnect
@MainActor
final class ClientSessionCoordinator: ObservableObject {
    enum SessionPhase: String, Equatable {
        case idle
        case connecting
        case signalingConnected
        case negotiating
        case waitingForMedia
        case receiving
        case error
    }

    /// How the active session is routed.
    enum ConnectionMode {
        case lan
        case tailscale
        case manual
        /// Display label shown in the UI badge.
        var label: String {
            switch self {
            case .lan:       return "LAN"
            case .tailscale: return "Tailscale"
            case .manual:    return "Manual"
            }
        }
        var systemImage: String {
            switch self {
            case .lan:       return "wifi"
            case .tailscale: return "shield.lefthalf.filled"
            case .manual:    return "network"
            }
        }
    }

    enum VPNStatus {
        case active
        case inactive

        var label: String {
            switch self {
            case .active: return "Active"
            case .inactive: return "Off"
            }
        }
    }

    @Published private(set) var phase: SessionPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            connectionDebugger.record("phase", phase.rawValue)
        }
    }
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var connectedHostName: String?
    @Published private(set) var connectedHostAddress: String?
    @Published private(set) var connectedSignalingPort: UInt16?
    @Published private(set) var connectedHostFingerprint: String?

    /// Derived from `connectedHostAddress`; `.lan` when no session is active.
    var connectionMode: ConnectionMode {
        guard let addr = connectedHostAddress else { return .lan }
        if addr.contains("ts.net") || addr.hasPrefix("100.") { return .tailscale }
        // Manual endpoints are tagged with appVersion == "unknown" at connect time;
        // we detect them by recognising non-mDNS hostnames (no .local suffix) that
        // are also not Tailscale addresses.
        let isLocal = addr.hasSuffix(".local") || addr.hasPrefix("169.254.")
            || addr.hasPrefix("192.168.") || addr.hasPrefix("10.")
            || addr.hasPrefix("172.")
        return isLocal ? .lan : .manual
    }
    @Published private(set) var activeQualityPreset: StreamQualityPreset = .balanced
    @Published private(set) var errorMessage: String?
    @Published private(set) var blockedState: ClientHostBlockedState?
    @Published private(set) var sessionMode: SessionControlMode = .fullControl
    @Published private(set) var hostLockState: HostLockState = .unlockedActiveSession
    @Published private(set) var networkQuality: NetworkQuality = .good
    @Published private(set) var lastRoundTripLatencyMs: Double?
    @Published private(set) var packetLossPercent: Double?
    @Published private(set) var tailscaleVPNStatus: VPNStatus = .inactive
    @Published private(set) var sessionStartedAt: Date?
    @Published private(set) var chatMessages: [SessionChatMessage] = []
    /// Capabilities returned by the host for the active authenticated session.
    /// This is especially important for manually entered Tailscale endpoints,
    /// whose Bonjour metadata is intentionally unknown before pairing.
    @Published private(set) var negotiatedCapabilities: NegotiatedCapabilities?
    /// True while the coordinator is tearing down and rebuilding a previous session.
    /// The Mac client uses this to keep its session view mounted during the brief
    /// `.idle` phase produced by `disconnect()` inside a reconnect attempt.
    @Published private(set) var isReconnectInProgress = false
    /// Whether this device currently has a satisfied network path. Lets the UI
    /// distinguish "your phone is offline" from "the Mac is quiet" while a
    /// reconnect is in flight, instead of showing one generic spinner.
    @Published private(set) var isNetworkPathSatisfied = true

    /// Terminal-session lifecycle, decoupled from the transport state. Views
    /// react to this instead of inferring end-of-session from socket events:
    /// a transient transport loss becomes `.suspended` (tabs stay mounted,
    /// remote shells keep running) while only an explicit user end becomes
    /// `.ended`.
    enum TerminalSessionLifecycle: Equatable {
        case inactive
        case connecting
        case active(UUID)
        case suspended(UUID)
        case ended
    }

    @Published private(set) var terminalSessionLifecycle: TerminalSessionLifecycle = .inactive
    /// The session ID preserved across transport reconnects so the host can
    /// reattach terminals to the same PTYs instead of spawning new shells.
    private var resumableSessionID: UUID?
    /// Highest journal sequence applied for the active session. Live events
    /// at or below this are duplicates (replay overlap) and are dropped.
    /// A live event ABOVE `lastApplied + 1` reveals a gap — the coordinator
    /// requests a sync replay to close it.
    private var lastAppliedJournalSequence: UInt64 = 0
    /// Whether the sync request for the current session activation was sent.
    private var syncRequestedForSessionID: UUID?
    /// UserDefaults key prefix for the per-session applied journal baseline.
    private static let journalBaselineKeyPrefix = "client.journal.baseline."
    var currentSessionTokenHex: String? { expectedSessionTokenHex }
    /// Called on MainActor when an audio frame arrives. Set by RemoteDesktopView.
    var onAudioFrame: ((AudioFrameMessage) -> Void)?
    /// Called on MainActor when a clipboard sync message arrives from the host.
    var onClipboardSync: ((ClipboardSyncMessage) -> Void)?
    /// Called on MainActor when a terminal output chunk arrives from the host.
    var onTerminalOutput: ((TerminalOutputMessage) -> Void)?
    /// Called on MainActor when the host signals the terminal closed (shell exited).
    var onTerminalClose: ((TerminalCloseMessage) -> Void)?
    /// Called on MainActor when the host has created a requested PTY.
    var onTerminalReady: ((TerminalReadyMessage) -> Void)?
    /// Called on MainActor when the host returns its cached workspace catalog.
    var onWorkspaceListResponse: ((WorkspaceListResponseMessage) -> Void)?
    /// Called on MainActor when the host returns a validated directory listing.
    var onWorkspaceDirectoryResponse: ((WorkspaceDirectoryResponseMessage) -> Void)?
    var onWorkspaceAccessResponse: ((WorkspaceAccessResponseMessage) -> Void)?
    /// Called on MainActor for semantic agent task-plan mutations. This path
    /// is intentionally distinct from terminal output and is routed by the
    /// authenticated session plus terminal ID.
    var onTaskPlanEvent: ((SessionTaskEventMessage) -> Void)?
    var onProviderSemanticEvent: ((ProviderSemanticEventMessage) -> Void)?
    /// Called on MainActor with the host's authoritative session snapshot
    /// (step E resume sync).
    var onSessionSnapshot: ((SessionSnapshotMessage) -> Void)?
    /// Called on MainActor with one replayed journal event (step E).
    var onSessionSyncEvent: ((SessionSyncEventMessage) -> Void)?
    var refreshEndpoint: ((ResolvedHostEndpoint) -> ResolvedHostEndpoint?)?
    /// Returns every distinct address we know for the physical host behind an endpoint
    /// (LAN + Tailscale relay sibling), ordered best-first. Used so reconnect can sweep
    /// across paths — e.g. fall back to the Tailscale address when the LAN address dies
    /// after the device leaves the home network.
    var candidateEndpoints: ((ResolvedHostEndpoint) -> [ResolvedHostEndpoint])?
    var onVerifiedHostIdentity: ((ResolvedHostEndpoint, UUID, String) -> ResolvedHostEndpoint?)?
    /// Returns the fingerprint we previously verified+stored for this host, if any. Used to pin
    /// host identity (TOFU): we verify the signed answer against this stored anchor rather than the
    /// fingerprint the current (attacker-influenceable) advertisement claims, so a same-LAN impostor
    /// re-advertising a trusted Mac's name can't be silently trusted.
    var trustedFingerprintProvider: ((ResolvedHostEndpoint) -> String?)?

    // Dependencies
    private let clientIdentity: ClientIdentity
    private let isMacClient: Bool
    private let hdrStreamingExplicitlyEnabled: Bool
    let clientProductRole: ClientProductRole
    private let webRTCSessionManager: any WebRTCSessionManaging
    private let peerConnectionProvider: LANPeerConnectionProvider
    private let eventLogStore: any EventLogStoreProtocol
    private let signalingService: any SessionCoordinatorSignaling
    private let displayLayoutViewModel: DisplayLayoutViewModel

    // Signaling
    private var signalingListenTask: Task<Void, Never>?
    private var connectionObserverTask: Task<Void, Never>?
    private var videoObserverTask: Task<Void, Never>?
    private var dataObserverTask: Task<Void, Never>?
    /// Terminal-only hosts intentionally do not publish a video track. Keep
    /// their authenticated data-channel session alive without waiting for a
    /// frame or surfacing the normal "no video" timeout.
    private var terminalOnlySession = false
    /// A host that negotiated App Streaming but has no display stream (Vamp
    /// Sync) deliberately starts no capture until the client names a window.
    /// Published so the session UI can show its app browser instead of waiting
    /// for video that will never arrive on its own.
    @Published private(set) var appStreamingOnlySession = false
    private var latencyProbeTask: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?
    private let qualityService = NetworkQualityIndicatorService()
    private var pendingPings: [UUID: Date] = [:]
    private var sentPingCount: UInt64 = 0
    private var receivedPongCount: UInt64 = 0
    private var lastPongReceivedAt: Date?
    private var lastLoggedQuality: NetworkQuality?

    // Resume context — kept so we can transparently reconnect after the device
    // sleeps, locks, or briefly loses network.
    private(set) var lastEndpoint: ResolvedHostEndpoint?
    private(set) var lastQualityPreset: StreamQualityPreset = .balanced
    /// Suppresses automatic resume after a policy-driven disconnect. It remains
    /// available to shared clients that need to require a deliberate fresh
    /// connection after terminating a session.
    var autoReconnectSuppressed = false
    private var resumeTask: Task<Void, Never>?
    private var reconnectOperationCount = 0

    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.mesutcy.remotedesktop.terminal.vpnmonitor")
    private var expectedSessionTokenHex: String?
    /// True when the current offer's session token was ECIES-sealed to the
    /// host's advertised key instead of sent in the clear. The host then
    /// omits the legacy token echo from its answer (echoing would re-expose
    /// the token on plaintext signaling), so the answer comparison is skipped.
    private var offerWasSealed = false
    /// Monotonic counter for authenticated host → client control messages.
    /// Host terminal and clipboard events must not be accepted merely because
    /// their payload/session IDs decode correctly.
    private var lastAcceptedInboundAuthCounter: UInt64 = 0
    private var expectedHostFingerprint: String?
    /// Last NWPath satisfaction state — used to detect heal transitions.
    private var lastPathWasSatisfied = true
    /// Consecutive recomputeQuality() calls that returned `.poor`.
    private var consecutivePoorQualitySamples: Int = 0
    private var consecutiveGoodQualitySamples: Int = 0
    private var lastUpgradeRequestPreset: StreamQualityPreset?
    /// Preset most recently sent as a downgrade request (avoids re-sending the same request).
    private var lastDowngradeRequestPreset: StreamQualityPreset?

    private let logger = Logger(subsystem: "com.mesutcy.remotedesktop.terminal", category: "SessionCoordinator")
    /// Records connection-signal timeline; dumps a report on connection loss.
    private let connectionDebugger: ConnectionDebugger
    private var debugChannelObserverTask: Task<Void, Never>?

    private func normalizedFingerprint(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private func isValidNormalizedFingerprint(_ value: String) -> Bool {
        RemoteDesktopConstants.isValidPublicKeyFingerprint(value)
    }

    private func normalizedHostAndPort(host: String, fallbackPort: UInt16) -> (host: String, port: UInt16) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (host, fallbackPort)
        }

        let parseInput = trimmed.contains("://") ? trimmed : "rdt://\(trimmed)"
        if let components = URLComponents(string: parseInput),
           let parsedHost = components.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
           !parsedHost.isEmpty {
            let parsedPort = components.port.flatMap(UInt16.init) ?? fallbackPort
            return (parsedHost, parsedPort)
        }

        return (trimmed, fallbackPort)
    }

    init(
        clientIdentity: ClientIdentity,
        isMacClient: Bool = false,
        hdrStreamingExplicitlyEnabled: Bool = false,
        clientProductRole: ClientProductRole = .remoteControl,
        webRTCSessionManager: any WebRTCSessionManaging,
        peerConnectionProvider: LANPeerConnectionProvider,
        eventLogStore: any EventLogStoreProtocol,
        signalingService: any SessionCoordinatorSignaling,
        displayLayoutViewModel: DisplayLayoutViewModel
    ) {
        self.clientIdentity = clientIdentity
        self.isMacClient = isMacClient
        self.hdrStreamingExplicitlyEnabled = hdrStreamingExplicitlyEnabled
        self.clientProductRole = clientProductRole
        self.webRTCSessionManager = webRTCSessionManager
        self.peerConnectionProvider = peerConnectionProvider
        self.eventLogStore = eventLogStore
        self.signalingService = signalingService
        self.displayLayoutViewModel = displayLayoutViewModel
        self.connectionDebugger = ConnectionDebugger(role: "client", eventLogStore: eventLogStore)
        self.connectionDebugger.snapshotProvider = { [weak self] in
            guard let self else { return [:] }
            let stream = self.webRTCSessionManager.streamDiagnostics
            var snapshot: [String: String] = [
                "phase": self.phase.rawValue,
                "peerState": self.webRTCSessionManager.peerConnectionState.rawValue,
                "dataChannel": self.webRTCSessionManager.dataChannelState.rawValue,
                "quality": self.networkQuality.rawValue,
                "vpn": self.tailscaleVPNStatus == .active ? "active" : "inactive",
                "pingsSent": String(self.sentPingCount),
                "pongsReceived": String(self.receivedPongCount),
                "pendingPings": String(self.pendingPings.count),
                "framesReceived": String(stream.framesReceived),
                "keyframesReceived": String(stream.keyframesReceived),
                "bytesReceived": String(stream.bytesReceived),
                "videoState": stream.receivingState.rawValue
            ]
            if let latency = self.lastRoundTripLatencyMs {
                snapshot["latencyMs"] = String(format: "%.0f", latency)
            }
            if let loss = self.packetLossPercent {
                snapshot["packetLossPercent"] = String(format: "%.1f", loss)
            }
            if let host = self.connectedHostAddress {
                snapshot["endpoint"] = "\(host):\(self.connectedSignalingPort.map(String.init) ?? "?")"
            }
            if let lastFrame = stream.lastFrameReceivedAt {
                snapshot["lastFrameAgo"] = String(format: "%.1fs", Date().timeIntervalSince(lastFrame))
            }
            return snapshot
        }
        startVPNMonitoring()
    }

    deinit {
        pathMonitor.cancel()
    }

    var isStreamVisiblyActive: Bool {
        phase == .receiving || webRTCSessionManager.streamDiagnostics.firstFrameReceivedAt != nil
    }

    // MARK: - Connect

    /// Connect to a discovered host by its resolved endpoint.
    func connect(to endpoint: ResolvedHostEndpoint, qualityPreset: StreamQualityPreset = .balanced, isReconnect: Bool = false) async {
        if let disconnectTask {
            await disconnectTask.value
        }
        guard phase == .idle || phase == .error else { return }

        // A deliberate (non-reconnect) connection re-enables auto-reconnect after a prior
        // host-busy response suppressed automatic retries.
        if !isReconnect {
            autoReconnectSuppressed = false
        }

        // Clean up any lingering state from a previous failed/error session
        if phase == .error {
            await disconnect()
        }

        // Remember where we connected so we can auto-resume after the device
        // sleeps, locks, or temporarily loses network.
        lastEndpoint = endpoint
        lastQualityPreset = qualityPreset

        phase = .connecting
        terminalSessionLifecycle = .connecting
        errorMessage = nil
        blockedState = nil
        negotiatedCapabilities = nil
        terminalOnlySession = false
        appStreamingOnlySession = false
        connectedHostName = endpoint.metadata.displayName
        let target = normalizedHostAndPort(host: endpoint.hostname, fallbackPort: endpoint.metadata.signalingPort)
        connectionDebugger.mark("connect → \(target.host):\(target.port)", metadata: [
            "host": endpoint.metadata.displayName,
            "preset": qualityPreset.rawValue
        ])
        connectedHostAddress = target.host
        connectedSignalingPort = target.port
        // Pin host identity to the fingerprint we previously verified+stored (TOFU), falling back
        // to the advertised one for a first-ever connection. If a known host now presents a
        // different key, the signed-answer check rejects it as an identity change instead of
        // silently adopting (and persisting) the new key.
        let advertisedFingerprint = normalizedFingerprint(endpoint.metadata.publicKeyFingerprint)
        let pinnedFingerprint = trustedFingerprintProvider?(endpoint).flatMap { $0.isEmpty ? nil : $0 }
        connectedHostFingerprint = pinnedFingerprint ?? advertisedFingerprint
        expectedHostFingerprint = pinnedFingerprint ?? advertisedFingerprint
        let effectiveQualityPreset = adjustedQualityPreset(requested: qualityPreset, endpoint: endpoint)
        activeQualityPreset = effectiveQualityPreset
        sessionStartedAt = nil
        sessionMode = .fullControl
        hostLockState = .unlockedActiveSession
        networkQuality = .good
        lastRoundTripLatencyMs = nil
        packetLossPercent = nil
        pendingPings.removeAll()
        sentPingCount = 0
        receivedPongCount = 0
        lastPongReceivedAt = nil
        lastLoggedQuality = nil
        chatMessages = []

        // The terminal-only product intentionally rejects remote-control offers.
        // Do this preflight before TLS/WebRTC so a stale saved host or a Tailscale
        // sibling cannot turn a product mismatch into the generic secure-handshake
        // error. The same check is used by iOS and the Mac remote-control client.
        if clientProductRole == .remoteControl,
           endpoint.metadata.capabilities.isTerminalOnlyHost {
            // A product mismatch is deterministic, not a transient network failure.
            // Suppress wake/network auto-reconnect until the user deliberately chooses
            // another host or taps Connect again.
            autoReconnectSuppressed = true
            blockedState = ClientHostBlockedState(terminalOnlyHostNamed: endpoint.metadata.displayName)
            phase = .error
            await eventLogStore.append(EventLogItem(
                severity: .warning,
                category: "Session",
                message: "Remote-control client cannot connect to terminal-only host \(endpoint.metadata.displayName)"
            ))
            return
        }

        do {
            // Set the remote host on the provider so the peer connection knows where to connect
            let connectionHost = StoreLANConnectionPolicy.requiresLAN
                ? try await StoreLANConnectionPolicy.validatedHost(target.host) : target.host
            peerConnectionProvider.setRemoteHost(connectionHost)

            // Set stable client identity on the signaling service so the host
            // can recognise us across reconnections (trust gate, pairing).
            if let bonjourSig = signalingService as? BonjourSignalingService {
                bonjourSig.localPeer = SignalingPeer(
                    id: clientIdentity.id,
                    role: .client,
                    displayName: clientIdentity.displayName,
                    publicKeyFingerprint: clientIdentity.publicKeyFingerprint
                )
            }

            // Connect signaling: prefer TLS when the host advertises a TLS port and
            // we have a fingerprint to use as the PSK.  If TLS fails, fall back to
            // the plain TCP port so older hosts and edge cases aren't broken.
            let sigSvc = self.signalingService
            // Reset any TLS state carried over from a previous connect on this shared
            // signaling service so each attempt is self-contained. Without this, a prior
            // successful TLS connect leaves requireTLS=true/connectionPIN set (they are only
            // cleared in the TLS-failure catch below, never on success), and a later plain
            // connect to a non-TLS host — most importantly a manually-typed Tailscale /
            // MagicDNS address, which advertises no secureTLSPort/fingerprint — would build
            // TLS-PSK params against the host's plain listener and fail the handshake every time.
            if let bonjourSig = sigSvc as? BonjourSignalingService {
                bonjourSig.requireTLS = false
                bonjourSig.connectionPIN = nil
            }
            let connectTimeout = signalingConnectTimeout(for: endpoint)
            var signalingConnected = false

            if let bonjourSig = sigSvc as? BonjourSignalingService,
               let advertisedFingerprint = endpoint.metadata.publicKeyFingerprint {
                let fingerprint = normalizedFingerprint(advertisedFingerprint)
                let tlsPort = endpoint.metadata.secureTLSPort ?? RemoteDesktopConstants.defaultTLSSignalingPort
                guard isValidNormalizedFingerprint(fingerprint) else {
                    logger.warning("Ignoring malformed advertised TLS fingerprint for \(endpoint.metadata.displayName)")
                    bonjourSig.requireTLS = false
                    bonjourSig.connectionPIN = nil
                    throw RemoteDesktopError.connectionFailed(
                        "The Mac advertised an invalid secure identity. Update the matching Vamp host, then try again."
                    )
                }
                bonjourSig.requireTLS = true
                bonjourSig.connectionPIN = fingerprint
                do {
                    try await withTimeout(seconds: connectTimeout) {
                        try await sigSvc.connect(host: connectionHost, port: tlsPort)
                    }
                    logger.info("Signaling connected via TLS on port \(tlsPort)")
                    signalingConnected = true
                } catch {
                    // A host advertising a TLS port IS TLS-capable, so refuse to silently downgrade
                    // to its plaintext listener — that downgrade is exactly how an on-path attacker
                    // would force the signaling exchange (SDP + session token) into the clear. Fail
                    // closed instead of falling back. (Genuinely old hosts advertise no TLS port and
                    // still take the plaintext path below.)
                    logger.warning("TLS signaling failed for a TLS-capable host; refusing plaintext downgrade: \(error.localizedDescription)")
                    bonjourSig.requireTLS = false
                    bonjourSig.connectionPIN = nil
                    sigSvc.disconnect()
                    throw RemoteDesktopError.connectionFailed(
                        "Secure connection to the Mac failed. Make sure Vamp Sync is open and up to date on that Mac, then try again."
                    )
                }
            }

            if !signalingConnected {
                try await withTimeout(seconds: connectTimeout) {
                    try await sigSvc.connect(host: connectionHost, port: target.port)
                }
            }
            phase = .signalingConnected

            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Session",
                message: "Signaling connected to \(endpoint.metadata.displayName)"
            ))

            // Start listening for signaling messages BEFORE sending the offer
            // so we don't miss the host's answer due to a race.
            // Reconnects reuse the prior session ID so the host can reattach
            // existing PTYs; a deliberate new connect starts a fresh session.
            let sessionID = isReconnect ? (resumableSessionID ?? UUID()) : UUID()
            resumableSessionID = sessionID
            activeSessionID = sessionID
            // A deliberate new session starts a fresh journal baseline; a
            // reconnect keeps the baseline so replay can resume exactly where
            // the client left off (including across app relaunches via the
            // persisted baseline).
            if !isReconnect {
                lastAppliedJournalSequence = 0
                syncRequestedForSessionID = nil
            } else {
                lastAppliedJournalSequence = max(
                    lastAppliedJournalSequence,
                    persistedJournalBaseline(for: sessionID)
                )
            }
            lastAcceptedInboundAuthCounter = 0
            listenForSignalingMessages(sessionID: sessionID, qualityPreset: qualityPreset)
            observeConnectionState(sessionID: sessionID)
            observeChannelStatesForDebugger(sessionID: sessionID)
            observeDataChannelMessages(sessionID: sessionID)
            startLatencyProbes()

            // Prepare WebRTC session
            try await webRTCSessionManager.prepareSession(id: sessionID, role: .client)

            // Create and send SDP offer
            phase = .negotiating
            var offer = try await webRTCSessionManager.createOffer(
                sessionID: sessionID,
                qualityPreset: effectiveQualityPreset,
                displayID: nil
            )
            let sessionTokenHex = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
            offerWasSealed = false
            if let kaPublicKey = endpoint.metadata.keyAgreementPublicKey,
               let kaKey = try? P256.KeyAgreement.PublicKey(x963Representation: kaPublicKey),
               let tokenData = ConnectionSecurity.tokenFromHex(sessionTokenHex),
               let sealed = try? SessionTokenSealing.seal(tokenData, to: kaKey) {
                // Seal the token to the host's advertised key-agreement key.
                // A passive observer on plaintext signaling never sees it.
                offer.sealedSessionToken = sealed
                offerWasSealed = true
            }
            if !offerWasSealed {
                offer.sessionToken = sessionTokenHex
            }
            offer.clientCapabilities = .currentClient(isMacClient: isMacClient)
            offer.clientProductRole = clientProductRole
            offer.preferredDynamicRange = ClientVideoDynamicRangePolicy.preferredDynamicRange(
                qualityPreset: effectiveQualityPreset,
                clientCapabilities: offer.clientCapabilities,
                hdrExplicitlyEnabled: hdrStreamingExplicitlyEnabled
            )
            expectedSessionTokenHex = sessionTokenHex
            webRTCSessionManager.configureControlChannelAuth(sessionTokenHex: sessionTokenHex)
            try await signalingService.sendOffer(offer, to: HostIdentity(
                displayName: endpoint.metadata.displayName,
                modelName: "Mac",
                osVersion: "",
                appVersion: endpoint.metadata.appVersion,
                publicKeyFingerprint: endpoint.metadata.publicKeyFingerprint ?? ""
            ))

            logger.info("Stream request sent for session \(sessionID.uuidString), quality=\(effectiveQualityPreset.rawValue)")

            // Wait for the negotiation to complete with a timeout.
            // A FIRST connect must wait out the host's trust prompt (~65s). An automatic
            // reconnect to an already-trusted host gets an immediate answer, so it uses a
            // much shorter ceiling — otherwise one unreachable candidate freezes the sweep
            // for up to a minute and reads as "reconnect is stuck".
            let negotiationDeadline = isReconnect
                ? RemoteDesktopConstants.reconnectNegotiationTimeout
                : RemoteDesktopConstants.negotiationTimeout
            let deadline = Date().addingTimeInterval(negotiationDeadline)
            while phase == .negotiating || phase == .signalingConnected {
                if Date() > deadline {
                    // Distinguish "host didn't approve" (we connected but no
                    // answer) from "host never replied" (probably offline /
                    // firewalled).  Phase tells us where we got stuck.
                    if phase == .signalingConnected {
                        throw RemoteDesktopError.timeout(
                            "Host didn't approve the connection. Open Vamp Host on your Mac and tap “Allow”."
                        )
                    }
                    throw RemoteDesktopError.timeout(
                        "No answer from the Mac. Make sure Vamp Host is running and that your firewall isn't blocking it."
                    )
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }

        } catch {
            // Only update phase if we haven't already moved past negotiating
            if phase == .connecting || phase == .signalingConnected || phase == .negotiating {
                phase = .error
                errorMessage = userFacingConnectionError(error, endpoint: endpoint)
                if terminalSessionLifecycle == .connecting {
                    terminalSessionLifecycle = .inactive
                }
            }
            logger.error("Connection failed: \(error.localizedDescription)")
            await eventLogStore.append(EventLogItem(
                severity: .error,
                category: "Session",
                message: "Connection failed: \(error.localizedDescription)"
            ))
        }
    }

    private func signalingConnectTimeout(for endpoint: ResolvedHostEndpoint) -> TimeInterval {
        isManualAddressEndpoint(endpoint)
            ? RemoteDesktopConstants.manualSignalingConnectTimeout
            : RemoteDesktopConstants.signalingConnectTimeout
    }

    private func isManualAddressEndpoint(_ endpoint: ResolvedHostEndpoint) -> Bool {
        endpoint.metadata.appVersion == "unknown"
    }

    private func isLikelyTailscaleEndpoint(_ endpoint: ResolvedHostEndpoint) -> Bool {
        endpoint.hostname.contains("ts.net")
            || endpoint.hostname.hasPrefix("100.")
            || endpoint.metadata.displayName.localizedCaseInsensitiveContains("tailscale")
    }

    private func adjustedQualityPreset(requested: StreamQualityPreset, endpoint: ResolvedHostEndpoint) -> StreamQualityPreset {
        // Let the user's chosen preset through — adaptive bitrate on the host and
        // runtime downgrade in `recomputeQuality()` handle Tailscale/relay paths.
        // Forcing `.performance` here made every Tailscale session half-res/low-bitrate
        // even on direct peer links with plenty of headroom.
        requested
    }

    private func userFacingConnectionError(_ error: Error, endpoint: ResolvedHostEndpoint) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        let nsError = error as NSError
        let isTimeout = nsError.code == NSURLErrorTimedOut || lower.contains("timed out")
        let isRefused = lower.contains("refused") || lower.contains("could not connect")
        let isUnreachable = lower.contains("unreachable") || lower.contains("not reachable")
        let isTLS = lower.contains("tls") || lower.contains("handshake") || lower.contains("certificate")

        if isTLS {
            return "Secure handshake with the Mac failed. Make sure the matching host is running: Vamp Sync or Vamp Assistant. Update it, then try again."
        }
        if isRefused {
            return "The Mac refused the connection. Open the Vamp host app on the Mac, then try again."
        }
        if isUnreachable {
            return "Can't reach the Mac. Check that you're on the same Wi-Fi (or that Tailscale is up if connecting remotely)."
        }
        if isTimeout {
            if isManualAddressEndpoint(endpoint) {
                return "Connection to \(endpoint.hostname):\(endpoint.port) timed out. Verify the host app is open and that the firewall allows ports 9471 and 9472."
            }
            // Already-actionable messages from the negotiation loop pass through.
            return raw
        }
        return raw
    }

    /// On macOS, tailscaled runs split-tunnel: the default route stays on Wi-Fi/Ethernet
    /// and the utun never appears in NWPath's interfaces, so the `.other` heuristic below
    /// reports Tailscale as off even while it's connected. Detect it directly instead by
    /// looking for an interface holding a Tailscale CGNAT address (100.64.0.0/10).
    nonisolated private static func hasTailscaleCGNATInterface() -> Bool {
#if os(macOS)
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var sin = sockaddr_in()
            memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
            let ip = UInt32(bigEndian: sin.sin_addr.s_addr)
            if (ip & 0xFFC0_0000) == 0x6440_0000 { return true }
        }
        return false
#else
        return false
#endif
    }

    private func startVPNMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let vpnActive = path.usesInterfaceType(.other)
                || path.availableInterfaces.contains(where: { $0.type == .other })
                || Self.hasTailscaleCGNATInterface()
            let pathStatus = String(describing: path.status)
            let interfaces = path.availableInterfaces
                .map { String(describing: $0.type) }
                .joined(separator: ",")
            Task { @MainActor in
                // Network path flaps (Wi-Fi → cellular, VPN up/down) right before a
                // drop are the most common root cause — keep them on the timeline.
                // Interfaces are part of the value so interface changes that keep
                // the path "satisfied" still register as transitions.
                self.connectionDebugger.record(
                    "networkPath",
                    "\(pathStatus) via [\(interfaces.isEmpty ? "none" : interfaces)]",
                    metadata: ["vpn": vpnActive ? "active" : "inactive"]
                )
                let oldStatus = self.tailscaleVPNStatus
                self.tailscaleVPNStatus = vpnActive ? .active : .inactive
                let pathRecovered = !self.lastPathWasSatisfied && pathStatus == "satisfied"
                self.lastPathWasSatisfied = pathStatus == "satisfied"
                self.isNetworkPathSatisfied = pathStatus == "satisfied"
                if oldStatus == .inactive && self.tailscaleVPNStatus == .active {
                    if self.phase == .error || self.phase == .idle {
                        await self.reconnectLast()
                    }
                } else if pathRecovered, self.phase == .error || self.phase == .idle, self.lastEndpoint != nil {
                    // Network heal (Wi-Fi back, cellular up) after the reconnect
                    // loop gave up — retry instead of waiting for user action.
                    self.connectionDebugger.mark("network path recovered — attempting reconnect")
                    await self.reconnectLast()
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// User-initiated end of session. Clears the resume context so we won't
    /// auto-reconnect when the device wakes.
    func endSession() async {
        connectionDebugger.mark("endSession (user-initiated)")
        resumeTask?.cancel()
        resumeTask = nil
        lastEndpoint = nil
        resumableSessionID = nil
        lastAppliedJournalSequence = 0
        syncRequestedForSessionID = nil
        await disconnect()
        terminalSessionLifecycle = .ended
    }

    /// Attempt to re-establish the most recent session — used when the app
    /// returns from background/sleep/lockscreen or when the network path
    /// recovers. Safe to call repeatedly; coalesces overlapping attempts.
    func reconnectLast() async {
        guard let endpoint = lastEndpoint else { return }
        // Don't auto-resume after the host rejected us as busy. Otherwise the
        // host-busy response and resume triggers can fight in a tight loop.
        // A deliberate user connect clears the flag.
        guard !autoReconnectSuppressed else { return }

        switch phase {
        case .receiving, .waitingForMedia, .negotiating, .signalingConnected, .connecting:
            return
        case .idle, .error:
            break
        }

        beginReconnectOperation()
        defer { endReconnectOperation() }

        if let existing = resumeTask, !existing.isCancelled {
            await existing.value
            // The awaited attempt may have exhausted its retries while a fresh trigger (network
            // heal, scene-active) arrived. Re-evaluate and fall through to a new attempt only if
            // we're still stranded — otherwise a just-recovered network's signal is swallowed.
            guard !autoReconnectSuppressed else { return }
            switch phase {
            case .receiving, .waitingForMedia, .negotiating, .signalingConnected, .connecting:
                return
            case .idle, .error:
                break
            }
        }

        let preset = lastQualityPreset
        let task = Task { [weak self] in
            guard let self else { return }
            // Bounded backoff retry: a single candidate sweep can fail because the host answers a
            // few seconds late (just-woken Mac, AP roam, NAT rebind) on a path that stays
            // "satisfied" so no external trigger re-fires. Retry with exponential backoff instead
            // of giving up after one pass. Cancellable via disconnect()/endSession().
            var attempt = 0
            while !Task.isCancelled {
                if self.phase != .idle {
                    await self.disconnect()
                }
                await self.connectSweepingCandidates(base: endpoint, qualityPreset: preset)
                if self.phase != .error { return }            // connected / negotiating → done
                if self.autoReconnectSuppressed { return }
                attempt += 1
                if attempt >= Self.reconnectMaxAttempts { return }
                try? await Task.sleep(nanoseconds: Self.reconnectBackoffNanos(attempt: attempt))
                guard !Task.isCancelled, self.phase == .error else { return }
            }
        }
        resumeTask = task
        await task.value
        resumeTask = nil
    }

    private static let reconnectMaxAttempts = 3
    private static func reconnectBackoffNanos(attempt: Int) -> UInt64 {
        // Exponential (2s, 4s, …) capped at 8s, plus up to 1s jitter to de-sync repeated attempts.
        let base = min(pow(2.0, Double(attempt)), 8.0)
        let jitter = Double.random(in: 0...1.0)
        return UInt64((base + jitter) * 1_000_000_000)
    }

    func forceReconnectLast() async throws {
        guard let endpoint = lastEndpoint else {
            throw RemoteDesktopError.connectionFailed("No previous host to reconnect.")
        }

        beginReconnectOperation()
        defer { endReconnectOperation() }

        resumeTask?.cancel()
        resumeTask = nil
        let preset = lastQualityPreset

        if phase != .idle {
            await disconnect()
        }
        await connectSweepingCandidates(base: endpoint, qualityPreset: preset)
        if phase == .error {
            throw RemoteDesktopError.connectionFailed(errorMessage ?? "Reconnect failed.")
        }

        // Receiving an SDP answer only means signaling succeeded. The old Mac
        // reconnect wrapper treated that as a restored session immediately,
        // even while the replacement TCP/WebRTC transport was still connecting.
        // Wait for the actual transport so a refused/stalled replacement remains
        // inside the backoff loop instead of showing a frozen session as healthy.
        if webRTCSessionManager.connectionState != .connected {
            let stateUpdates = webRTCSessionManager.connectionStateUpdates()
            try await withTimeout(seconds: RemoteDesktopConstants.reconnectNegotiationTimeout) {
                for await state in stateUpdates {
                    if state == .connected { return }
                    if state == .failed {
                        throw RemoteDesktopError.connectionFailed("Reconnect transport failed.")
                    }
                }
                throw RemoteDesktopError.connectionFailed("Reconnect transport ended before it connected.")
            }
        }
    }

    private func beginReconnectOperation() {
        reconnectOperationCount += 1
        isReconnectInProgress = true
    }

    private func endReconnectOperation() {
        reconnectOperationCount = max(0, reconnectOperationCount - 1)
        isReconnectInProgress = reconnectOperationCount > 0
    }

    /// Try every known address for the host (LAN, then Tailscale relay sibling, …) in
    /// turn until one connects. This is what lets the session survive the device moving
    /// off the home network: when the LAN address is unreachable on cellular, the sweep
    /// falls through to the host's Tailscale address.
    private func connectSweepingCandidates(base: ResolvedHostEndpoint, qualityPreset: StreamQualityPreset) async {
        let refreshed = refreshEndpoint?(base) ?? base
        var candidates = candidateEndpoints?(refreshed) ?? []
        if candidates.isEmpty {
            candidates = [refreshed]
        }
        // When the device has left the home Wi-Fi, the LAN 192.168.x address is
        // unreachable but its NWConnection sits in `.waiting` rather than failing fast,
        // so a LAN-first sweep burns the full connect timeout before reaching the working
        // tailnet address. If the live path has no Wi-Fi interface, promote Tailscale/relay
        // candidates ahead of the LAN one. On Wi-Fi the order is unchanged.
        if !pathMonitor.currentPath.usesInterfaceType(.wifi) {
            candidates = candidates.sorted { lhs, rhs in
                isLikelyTailscaleEndpoint(lhs) && !isLikelyTailscaleEndpoint(rhs)
            }
        }
        lastEndpoint = candidates.first ?? refreshed

        for candidate in candidates {
            // `connect` no-ops unless phase is .idle/.error; it tears down a prior
            // failed attempt itself, so the loop just needs to keep calling it.
            // This sweep is only reached from reconnectLast()/forceReconnectLast(), both
            // automatic reconnects, so use the shorter reconnect negotiation ceiling.
            await connect(to: candidate, qualityPreset: qualityPreset, isReconnect: true)
            if phase != .error {
                // Remember the address that actually worked so the next resume tries it first.
                lastEndpoint = candidate
                return
            }
            logger.warning("Reconnect candidate \(candidate.hostname):\(candidate.port) failed, trying next path")
        }
        // All candidates failed; keep the best-known endpoint for the next attempt.
        lastEndpoint = refreshed
    }

    /// Disconnect from the current session.
    func disconnect() async {
        if let disconnectTask {
            await disconnectTask.value
            return
        }

        let sessionID = activeSessionID
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
        let sigTask = signalingListenTask
        let connTask = connectionObserverTask
        let vidTask = videoObserverTask
        let dataTask = dataObserverTask
        let latencyTask = latencyProbeTask

        self.activeSessionID = nil
        // Transient transport end: the terminal workspace stays mounted and
        // the remote session keeps running. Only `endSession()` (user action)
        // produces `.ended` and tears tabs down.
        switch terminalSessionLifecycle {
        case .active(let sessionID):
            terminalSessionLifecycle = .suspended(sessionID)
        case .connecting:
            terminalSessionLifecycle = .inactive
        case .inactive, .suspended, .ended:
            break
        }

        signalingListenTask?.cancel()
        signalingListenTask = nil
        connectionObserverTask?.cancel()
        connectionObserverTask = nil
        videoObserverTask?.cancel()
        videoObserverTask = nil
        dataObserverTask?.cancel()
        dataObserverTask = nil
        latencyProbeTask?.cancel()
        latencyProbeTask = nil
        debugChannelObserverTask?.cancel()
        debugChannelObserverTask = nil

        // Never block @MainActor waiting for potentially stuck streams to terminate.
        // Await cancellation in the background so the UI disconnect action stays responsive.
        Task.detached(priority: .utility) {
            await sigTask?.value
            await connTask?.value
            await vidTask?.value
            await dataTask?.value
            await latencyTask?.value
        }

        await self.webRTCSessionManager.closeSession()
        self.signalingService.disconnect()

        self.connectedHostName = nil
        self.connectedHostAddress = nil
        self.connectedSignalingPort = nil
        self.connectedHostFingerprint = nil
        self.activeQualityPreset = .balanced
        self.errorMessage = nil
        self.blockedState = nil
        self.sessionMode = .fullControl
        self.hostLockState = .unlockedActiveSession
        self.networkQuality = .good
        self.lastRoundTripLatencyMs = nil
        self.packetLossPercent = nil
        self.sessionStartedAt = nil
        self.pendingPings.removeAll()
        self.sentPingCount = 0
        self.receivedPongCount = 0
        self.lastLoggedQuality = nil
        self.consecutivePoorQualitySamples = 0
        self.consecutiveGoodQualitySamples = 0
        self.lastUpgradeRequestPreset = nil
        self.lastDowngradeRequestPreset = nil
        self.expectedSessionTokenHex = nil
        self.offerWasSealed = false
        self.lastAcceptedInboundAuthCounter = 0
        self.expectedHostFingerprint = nil
        self.webRTCSessionManager.configureControlChannelAuth(sessionTokenHex: nil)
        self.chatMessages = []
        self.negotiatedCapabilities = nil
        self.terminalOnlySession = false
        self.appStreamingOnlySession = false
        self.phase = .idle

        await self.eventLogStore.append(EventLogItem(
            severity: .info,
            category: "Session",
            message: sessionID.map { "Disconnected session \($0.uuidString)" } ?? "Disconnected"
        ))
        }

        disconnectTask = task
        await task.value
        disconnectTask = nil
    }

    // MARK: - Signaling

    func restartSignalingListener(sessionID: UUID, qualityPreset: StreamQualityPreset) {
        signalingListenTask?.cancel()
        listenForSignalingMessages(sessionID: sessionID, qualityPreset: qualityPreset)
    }

    private func listenForSignalingMessages(sessionID: UUID, qualityPreset: StreamQualityPreset) {
        // Call receiveMessages() synchronously so messageContinuation is set immediately,
        // before the Task body executes.  This prevents a race where the host sends an
        // answer before the Task has had a chance to run on @MainActor.
        let messageStream = signalingService.receiveMessages()
        signalingListenTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in messageStream {
                    guard !Task.isCancelled else { break }
                    await self.handleSignalingMessage(message, sessionID: sessionID)
                }
                // Stream ended cleanly (host closed the connection).  If we haven't
                // finished negotiating yet, the host rejected the connection — surface
                // this immediately rather than letting the 65-second timeout expire.
                if self.activeSessionID == sessionID,
                   (self.phase == .negotiating || self.phase == .signalingConnected) {
                    self.phase = .error
                    self.errorMessage = "The Mac closed the pairing request. Click Vamp Sync in the Mac's menu bar, approve this device, then connect again."
                }
            } catch {
                self.logger.warning("Signaling receive ended: \(error.localizedDescription)")
                if self.activeSessionID == sessionID,
                   (self.phase == .negotiating || self.phase == .signalingConnected) {
                    self.phase = .error
                    self.errorMessage = "Approval timed out. Click Vamp Sync in the Mac's menu bar, approve this device, then connect again."
                }
            }
        }
    }

    private func handleSignalingMessage(_ message: VersionedSignalingMessage, sessionID: UUID) async {
        guard activeSessionID == sessionID else {
            logger.debug("Ignoring signaling message for stale local session \(sessionID.uuidString)")
            return
        }
        if let envelopeSessionID = message.envelope.sessionID, envelopeSessionID != sessionID {
            logger.debug("Ignoring signaling message for stale remote session \(envelopeSessionID.uuidString)")
            return
        }

        let event = message.envelope.event

        switch event {
        case .answer(let answer):
            let claimed = normalizedFingerprint(message.envelope.sender.publicKeyFingerprint)
            if let expected = expectedHostFingerprint, !expected.isEmpty {
                guard claimed == expected else {
                    logger.warning("Rejected answer due to host fingerprint mismatch expected=\(expected, privacy: .public) claimed=\(claimed, privacy: .public)")
                    phase = .error
                    errorMessage = "This Mac's identity changed since you last connected. If you reinstalled the Mac host, remove this saved Mac and reconnect; otherwise don't proceed."
                    await eventLogStore.append(EventLogItem(
                        severity: .warning,
                        category: "Trust",
                        message: "Rejected host answer due to fingerprint mismatch"
                    ))
                    await disconnect()
                    return
                }
            }
            guard answer.sessionID == sessionID else {
                logger.debug("Ignoring answer for stale session \(answer.sessionID.uuidString)")
                return
            }
            if isValidNormalizedFingerprint(claimed), var endpoint = lastEndpoint {
                endpoint.metadata.hostID = message.envelope.sender.id
                endpoint.metadata.publicKeyFingerprint = claimed
                endpoint = onVerifiedHostIdentity?(endpoint, message.envelope.sender.id, claimed) ?? endpoint
                lastEndpoint = endpoint
                connectedHostFingerprint = claimed
                expectedHostFingerprint = claimed
            }
            await handleHostAnswer(answer, sessionID: sessionID)

        case .iceCandidate(let candidate):
            guard candidate.sessionID == sessionID else {
                logger.debug("Ignoring ICE candidate for stale session \(candidate.sessionID.uuidString)")
                return
            }
            do {
                try await webRTCSessionManager.addRemoteCandidate(candidate)
            } catch {
                logger.warning("Failed to add ICE candidate: \(error.localizedDescription)")
            }

        case .sessionReady(let ready):
            guard ready.sessionID == sessionID else {
                logger.debug("Ignoring session-ready for stale session \(ready.sessionID.uuidString)")
                return
            }
            logger.info("Session ready: \(ready.sessionID.uuidString)")
            activeSessionID = ready.sessionID
            negotiatedCapabilities = ready.negotiatedCapabilities
            if let lockState = ready.lockState {
                hostLockState = lockState
            }
            terminalOnlySession = ready.negotiatedCapabilities.supportsTerminal
                && ready.negotiatedCapabilities.supportsMultipleTerminals
                && !ready.negotiatedCapabilities.supportsMultiDisplay
            appStreamingOnlySession = ready.negotiatedCapabilities.isAppStreamingOnly
            if terminalOnlySession {
                videoObserverTask?.cancel()
                videoObserverTask = nil
            }
            displayLayoutViewModel.markHostSelectedDisplay(id: ready.selectedDisplayID)
            phase = .waitingForMedia

        case .permissionBlocked(let blocked):
            guard blocked.sessionID == sessionID else {
                logger.debug("Ignoring permission-blocked for stale session \(blocked.sessionID.uuidString)")
                return
            }
            logger.warning("Host permissions blocked: \(blocked.blockedPermissions.map(\.kind.rawValue))")
            blockedState = ClientHostBlockedState(message: blocked)
            phase = .error

        case .hostBusy:
            logger.info("Host rejected session because another client is connected")
            autoReconnectSuppressed = true
            activeSessionID = nil
            expectedSessionTokenHex = nil
            lastAcceptedInboundAuthCounter = 0
            webRTCSessionManager.configureControlChannelAuth(sessionTokenHex: nil)
            await webRTCSessionManager.closeSession()
            signalingService.disconnect()
            phase = .error
            errorMessage = "This Mac is already connected to another device. Disconnect that session, then try again."
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Session",
                message: "Connection declined because the host is already in use"
            ))

        default:
            logger.info("Received signaling event: \(event.kind.rawValue)")
        }
    }

    private func handleHostAnswer(_ answer: SessionAnswerMessage, sessionID: UUID) async {
        do {
            guard activeSessionID == sessionID else {
                logger.debug("Ignoring host answer for inactive session \(sessionID.uuidString)")
                return
            }
            // Hosts no longer echo the session token (it would re-expose the
            // control-channel secret on plaintext signaling). If a legacy host
            // still echoes one, it must match what we sent.
            if let echoed = answer.sessionToken,
               let expected = expectedSessionTokenHex,
               echoed != expected {
                throw RemoteDesktopError.negotiationFailed("Host session token mismatch")
            }
            try await webRTCSessionManager.applyRemoteAnswer(answer)
            phase = .waitingForMedia
            logger.info("SDP answer applied — TCP connect initiated, waiting for media")
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Session",
                message: "Stream request approved — TCP connect initiated"
            ))

            // Wait for first frame via stream diagnostics (without consuming the video stream).
            if !terminalOnlySession {
                observeVideoFrames(sessionID: sessionID)
            }

            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Session",
                message: "Session negotiated, waiting for video"
            ))

        } catch {
            phase = .error
            errorMessage = error.localizedDescription
            logger.error("Stream error reason: \(error.localizedDescription)")
        }
    }

    // MARK: - Observation

    private func observeConnectionState(sessionID: UUID) {
        connectionObserverTask = Task { [weak self] in
            guard let self else { return }
            for await state in webRTCSessionManager.connectionStateUpdates() {
                guard !Task.isCancelled else { break }
                guard self.activeSessionID == sessionID else { continue }
                self.connectionDebugger.record("connection", state.rawValue, metadata: [
                    "peerState": self.webRTCSessionManager.peerConnectionState.rawValue,
                    "dataChannel": self.webRTCSessionManager.dataChannelState.rawValue,
                    "phase": self.phase.rawValue
                ])
                switch state {
                case .connected:
                    if self.terminalOnlySession {
                        self.phase = .receiving
                    } else if self.webRTCSessionManager.streamDiagnostics.firstFrameReceivedAt != nil {
                        self.phase = .receiving
                    } else if self.phase == .negotiating || self.phase == .waitingForMedia || self.phase == .error {
                        // .error included so a transient drop that recovers on its
                        // own (provider-level retry) doesn't strand the phase.
                        self.phase = .waitingForMedia
                    }
                    self.blockedState = nil
                    // Clear any stale failure banner — a transient drop that auto-recovered
                    // should not keep showing "Connection failed" once the socket is back.
                    self.errorMessage = nil
                    let dcState = self.webRTCSessionManager.dataChannelState
                    self.logger.info("Stream socket connected — dataChannel=\(dcState.rawValue)")
                    self.recomputeQuality()
                    // Data channel is open — send the control-channel auth handshake now.
                    if let sessionID = self.activeSessionID,
                       let token = self.expectedSessionTokenHex,
                       let envelope = try? DataChannelEnvelope.controlAuth(
                           ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
                       ) {
                        try? self.webRTCSessionManager.sendDataMessage(envelope)
                    }
                case .disconnected:
                    self.logger.warning("Peer disconnected")
                    self.networkQuality = .poor
                    self.connectionDebugger.connectionLost(reason: "Peer disconnected — host closed or network dropped")
                    // Mirror the .failed handling: without an .error phase the
                    // VPN/foreground/path-heal reconnect paths (guarded on
                    // phase == .idle || .error) refuse to run and the user is
                    // left on a frozen frame. A transient drop that recovers
                    // clears this in the .connected case above.
                    self.phase = .error
                    self.errorMessage = self.lastEndpoint != nil
                        ? "Connection lost — reconnecting…"
                        : "Connection failed"
                    await self.eventLogStore.append(EventLogItem(
                        severity: .warning,
                        category: "Session",
                        message: "Host disconnected"
                    ))
                case .failed:
                    self.connectionDebugger.connectionLost(reason: "Peer connection failed — transport-level error")
                    self.phase = .error
                    // When we still know where the host lives, reconnect will sweep its
                    // known addresses (LAN → Tailscale) automatically, so frame this as a
                    // recoverable drop rather than a dead end.
                    self.errorMessage = self.lastEndpoint != nil
                        ? "Connection lost — reconnecting…"
                        : "Connection failed"
                    self.networkQuality = .poor
                default:
                    break
                }
            }
        }
    }

    /// Debug-only observer: records control/video channel transitions on the
    /// connection-loss timeline. The client has no functional need to watch these
    /// streams, but channel state right before a drop is key evidence (e.g. data
    /// channel closing while the peer connection still reports connected).
    private func observeChannelStatesForDebugger(sessionID: UUID) {
        debugChannelObserverTask?.cancel()
        debugChannelObserverTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor [weak self] in
                    guard let self else { return }
                    for await state in self.webRTCSessionManager.dataChannelStateUpdates() {
                        guard !Task.isCancelled, self.activeSessionID == sessionID else { break }
                        self.connectionDebugger.record("dataChannel", state.rawValue)
                    }
                }
                group.addTask { @MainActor [weak self] in
                    guard let self else { return }
                    for await state in self.webRTCSessionManager.videoChannelStateUpdates() {
                        guard !Task.isCancelled, self.activeSessionID == sessionID else { break }
                        self.connectionDebugger.record("videoChannel", state.rawValue)
                    }
                }
            }
        }
    }

    private func observeVideoFrames(sessionID: UUID) {
        guard !terminalOnlySession else { return }
        videoObserverTask = Task { [weak self] in
            guard let self else { return }
            let startedWaiting = Date()
            var diagnosticFiredAt5s = false
            var keyframeRequestSentAt: Date?

            while !Task.isCancelled {
                guard self.activeSessionID == sessionID else { break }
                let diag = self.webRTCSessionManager.streamDiagnostics

                if diag.firstFrameReceivedAt != nil {
                    self.phase = .receiving
                    self.blockedState = nil
                    self.sessionStartedAt = self.sessionStartedAt ?? Date()
                    let elapsed = Date().timeIntervalSince(startedWaiting)
                    self.logger.info("First video frame received after \(String(format: "%.2f", elapsed))s")
                    await self.eventLogStore.append(EventLogItem(
                        severity: .info,
                        category: "Session",
                        message: "Video stream started (waited \(String(format: "%.1f", elapsed))s)"
                    ))
                    // Continue the loop to watch for decoder-stuck state even after
                    // the first transport frame arrives.
                }

                let elapsed = Date().timeIntervalSince(startedWaiting)

                // 5-second diagnostic: log exact pipeline state if no first frame yet
                if !diagnosticFiredAt5s && elapsed >= 5 {
                    diagnosticFiredAt5s = true
                    let connState = self.webRTCSessionManager.connectionState
                    let dcState = self.webRTCSessionManager.dataChannelState
                    let framesRecv = diag.framesReceived
                    let videoReceivingState = diag.receivingState
                    let reason: String
                    if connState != .connected {
                        reason = "stream socket not connected (state=\(connState.rawValue))"
                    } else if dcState != .open {
                        reason = "control channel not open (state=\(dcState.rawValue))"
                    } else if framesRecv == 0 {
                        reason = "no video bytes received (socket open, video channel=\(videoReceivingState.rawValue))"
                    } else {
                        reason = "frames arrived but decoder/renderer not delivering (recv=\(framesRecv), keyframes=\(diag.keyframesReceived), videoState=\(videoReceivingState.rawValue))"
                    }
                    self.logger.warning("No first frame after 5s — \(reason)")
                    await self.eventLogStore.append(EventLogItem(
                        severity: .warning,
                        category: "Session",
                        message: "No video frame after 5s: \(reason)"
                    ))
                }

                // Media-arrival watchdog. The negotiation timeout only covers
                // .negotiating/.signalingConnected; once the host answer is applied we sit in
                // .waitingForMedia with no deadline, so a wedged encoder / never-opened video
                // channel / no-display-selected host left a perpetual "connecting…" spinner.
                // Resolve it with actionable guidance instead of hanging forever.
                // An app-streaming-only host has nothing to send until the user
                // picks a window, so "no video yet" is the normal resting state
                // rather than a wedged encoder. Failing it out here stranded every
                // Vamp Sync session on a Screen-Recording error 15s after connecting.
                if diag.firstFrameReceivedAt == nil,
                   !self.appStreamingOnlySession,
                   elapsed >= Self.mediaArrivalTimeoutSeconds,
                   self.phase == .waitingForMedia {
                    self.logger.error("No video after \(String(format: "%.0f", elapsed))s in waitingForMedia — surfacing error")
                    self.phase = .error
                    self.errorMessage = "Connected to the Mac, but no video arrived. On the Mac, make sure a display is selected and that Screen Recording is allowed for the Mac host."
                    await self.eventLogStore.append(EventLogItem(
                        severity: .error,
                        category: "Session",
                        message: "No video within \(Int(Self.mediaArrivalTimeoutSeconds))s of connecting — surfaced to user"
                    ))
                    break
                }

                // Recovery: if bytes are arriving but no keyframe has been received,
                // request a fresh IDR frame from the host.  This is the safety-net for
                // the race where the host's forced keyframe was encoded before the video
                // channel opened and was silently dropped.
                // Conditions: ≥50 transport frames in, still 0 keyframes, cooldown 10s.
                let framesReceived = diag.framesReceived
                let keyframesReceived = diag.keyframesReceived
                if framesReceived >= 50, keyframesReceived == 0 {
                    let shouldSend: Bool
                    if let lastSent = keyframeRequestSentAt {
                        shouldSend = Date().timeIntervalSince(lastSent) >= 10
                    } else {
                        shouldSend = true
                    }
                    if shouldSend, let sid = self.activeSessionID,
                       self.webRTCSessionManager.connectionState == .connected {
                        keyframeRequestSentAt = Date()
                        self.logger.warning("Decoder stuck: \(framesReceived) frames received, 0 keyframes — requesting IDR from host")
                        if let envelope = try? DataChannelEnvelope.requestKeyframe(sessionID: sid) {
                            try? self.webRTCSessionManager.sendDataMessage(envelope)
                        }
                        await self.eventLogStore.append(EventLogItem(
                            severity: .warning,
                            category: "Session",
                            message: "Decoder stuck after \(framesReceived) frames — sent keyframe request to host"
                        ))
                    }
                }

                // Exit once we have confirmed the decoder is healthy (keyframe received).
                if keyframesReceived > 0, diag.firstFrameReceivedAt != nil {
                    break
                }

                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func observeDataChannelMessages(sessionID: UUID) {
        guard dataObserverTask == nil else { return }
        dataObserverTask = Task { [weak self] in
            guard let self else { return }
            for await envelope in webRTCSessionManager.receiveDataMessages() {
                guard !Task.isCancelled else { break }
                guard self.activeSessionID == sessionID else { continue }
                switch envelope.kind {
                case .displayLayout:
                    if let message = try? envelope.decodeDisplayLayout() {
                        self.displayLayoutViewModel.update(layout: message.layout)
                    }
                case .displayConfigurationChanged:
                    if let message = try? envelope.decodeDisplayConfigurationChanged() {
                        if let layout = message.layout {
                            self.displayLayoutViewModel.update(layout: layout)
                        }
                        self.displayLayoutViewModel.updateStreamConfiguration(message.configuration)
                        self.displayLayoutViewModel.markHostSelectedDisplay(id: message.configuration.displayID)
                    }
                case .hostStatus:
                    if let message = try? envelope.decodeHostStatus() {
                        if let layout = message.displayLayout {
                            self.displayLayoutViewModel.update(layout: layout)
                        }
                        self.displayLayoutViewModel.markHostSelectedDisplay(id: message.selectedDisplayID)
                        if let sessionMode = message.sessionMode {
                            self.sessionMode = sessionMode
                        }
                        if let quality = message.quality {
                            self.networkQuality = quality
                        }
                        if let lockState = message.lockState {
                            self.hostLockState = lockState
                        }
                    }
                case .pong:
                    if let message = try? envelope.decodePong() {
                        self.handlePong(message)
                    }
                case .ping:
                    if let message = try? envelope.decodePing() {
                        let pong = PongMessage(id: message.id, sentAt: message.sentAt)
                        if let envelope = try? DataChannelEnvelope.pong(pong) {
                            try? self.webRTCSessionManager.sendDataMessage(envelope)
                        }
                    }
                case .chatMessage:
                    if let message = try? envelope.decodeChatMessage() {
                        self.chatMessages.append(message)
                    }
                case .error:
                    if let message = try? envelope.decodeError(), message.code == "permission_blocked" {
                        self.errorMessage = message.message
                    }
                case .audioFrame:
                    if let message = try? envelope.decodeAudioFrame() {
                        self.onAudioFrame?(message)
                    }
                case .clipboardSync:
                    guard self.acceptAuthenticatedInboundControl(envelope, sessionID: sessionID) else { break }
                    if let message = try? envelope.decodeClipboardSync() {
                        guard envelope.sessionID == message.sessionID,
                              message.sessionID == self.activeSessionID,
                              message.source == "host" else { break }
                        self.onClipboardSync?(message)
                    }
                case .terminalOutput:
                    guard self.acceptAuthenticatedInboundControl(envelope, sessionID: sessionID) else { break }
                    if let message = try? envelope.decodeTerminalOutput() {
                        guard envelope.sessionID == message.sessionID,
                              message.sessionID == self.activeSessionID else { break }
                        self.onTerminalOutput?(message)
                    }
                case .terminalReady:
                    guard self.acceptAuthenticatedInboundControl(envelope, sessionID: sessionID) else { break }
                    if let message = try? envelope.decodeTerminalReady() {
                        guard envelope.sessionID == message.sessionID,
                              message.sessionID == self.activeSessionID else { break }
                        if let activeSessionID = self.activeSessionID {
                            self.terminalSessionLifecycle = .active(activeSessionID)
                            if self.syncRequestedForSessionID != activeSessionID {
                                self.syncRequestedForSessionID = activeSessionID
                                // Resume sync (step E): ask the host for the
                                // snapshot + journaled events we missed.
                                self.requestSessionSync(
                                    sessionID: activeSessionID,
                                    afterSequence: self.lastAppliedJournalSequence
                                )
                            }
                        }
                        self.onTerminalReady?(message)
                    }
                case .terminalClose:
                    guard self.acceptAuthenticatedInboundControl(envelope, sessionID: sessionID) else { break }
                    if let message = try? envelope.decodeTerminalClose() {
                        guard envelope.sessionID == message.sessionID,
                              message.sessionID == self.activeSessionID else { break }
                        self.onTerminalClose?(message)
                    }
                case .workspaceListResponse:
                    guard self.acceptAuthenticatedInboundControl(envelope, sessionID: sessionID) else { break }
                    if let message = try? envelope.decodeWorkspaceListResponse(),
                       envelope.sessionID == message.sessionID,
                       message.sessionID == self.activeSessionID {
                        self.onWorkspaceListResponse?(message)
                    }
                case .workspaceDirectoryResponse:
                    guard self.acceptAuthenticatedInboundControl(envelope, sessionID: sessionID) else { break }
                    if let message = try? envelope.decodeWorkspaceDirectoryResponse(),
                       envelope.sessionID == message.sessionID,
                       message.sessionID == self.activeSessionID {
                        self.onWorkspaceDirectoryResponse?(message)
                    }
                case .workspaceAccessResponse:
                    guard self.acceptAuthenticatedInboundControl(envelope, sessionID: sessionID) else { break }
                    if let message = try? envelope.decodeWorkspaceAccessResponse(),
                       envelope.sessionID == message.sessionID,
                       message.sessionID == self.activeSessionID {
                        self.onWorkspaceAccessResponse?(message)
                    }
                case .taskPlanEvent:
                    guard self.acceptAuthenticatedInboundControl(envelope, sessionID: sessionID) else { break }
                    if let message = try? envelope.decodeTaskPlanEvent(),
                       envelope.sessionID == message.sessionID,
                       message.sessionID == self.activeSessionID {
                        if self.applyJournaledLiveEvent(sequence: message.journalSequence, sessionID: sessionID) {
                            self.onTaskPlanEvent?(message)
                        }
                    }
                case .providerSemanticEvent:
                    guard self.acceptAuthenticatedInboundControl(envelope, sessionID: sessionID) else { break }
                    if let message = try? envelope.decodeProviderSemanticEvent(),
                       envelope.sessionID == message.sessionID,
                       message.sessionID == self.activeSessionID {
                        if self.applyJournaledLiveEvent(sequence: message.journalSequence, sessionID: sessionID) {
                            self.onProviderSemanticEvent?(message)
                        }
                    }
                case .sessionSnapshot:
                    guard self.acceptAuthenticatedInboundControl(envelope, sessionID: sessionID) else { break }
                    if let message = try? envelope.decodeSessionSnapshot(),
                       envelope.sessionID == message.sessionID,
                       message.sessionID == self.activeSessionID {
                        self.onSessionSnapshot?(message)
                    }
                case .sessionSyncEvent:
                    guard self.acceptAuthenticatedInboundControl(envelope, sessionID: sessionID) else { break }
                    if let message = try? envelope.decodeSessionSyncEvent(),
                       envelope.sessionID == message.sessionID,
                       message.sessionID == self.activeSessionID {
                        if message.journalSequence > self.lastAppliedJournalSequence {
                            self.lastAppliedJournalSequence = message.journalSequence
                            self.persistJournalBaseline(message.journalSequence, sessionID: sessionID)
                            self.onSessionSyncEvent?(message)
                        }
                    }
                default:
                    break
                }
            }
        }
    }

    /// Validates the same timestamp, session, HMAC, and monotonic counter
    /// invariants the host applies to client control messages. The counter gap
    /// is intentionally allowed because other authenticated host messages may
    /// arrive between two terminal output chunks.
    private func acceptAuthenticatedInboundControl(_ envelope: DataChannelEnvelope, sessionID: UUID) -> Bool {
        guard envelope.hasAcceptableTimestamp,
              envelope.sessionID == sessionID,
              let expectedToken = expectedSessionTokenHex,
              envelope.hasValidAuthentication(sessionTokenHex: expectedToken),
              let counter = envelope.authCounter,
              counter > lastAcceptedInboundAuthCounter,
              counter - lastAcceptedInboundAuthCounter <= DataChannelEnvelope.maxCounterGap else {
            return false
        }
        lastAcceptedInboundAuthCounter = counter
        return true
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Sends a ping to confirm the connection is still alive.
    /// Used by the lock-state overlay so the user can verify the session
    /// is live while waiting for the Mac to be unlocked locally.
    func sendConnectionProbe() {
        guard webRTCSessionManager.connectionState == .connected else { return }
        let ping = PingMessage()
        pendingPings[ping.id] = ping.sentAt
        sentPingCount += 1
        if let envelope = try? DataChannelEnvelope.ping(ping) {
            try? webRTCSessionManager.sendDataMessage(envelope)
        }
    }

    func sendUnlockPassword(_ password: String) {
        guard webRTCSessionManager.connectionState == .connected,
              let sessionID = activeSessionID,
              !password.isEmpty else { return }
        let message = UnlockPasswordMessage(sessionID: sessionID, password: password)
        guard let envelope = try? DataChannelEnvelope.unlockPassword(message) else { return }
        try? webRTCSessionManager.sendDataMessage(envelope)
    }

    func sendClipboardEnvelope(_ envelope: DataChannelEnvelope) {
        guard webRTCSessionManager.connectionState == .connected else { return }
        try? webRTCSessionManager.sendDataMessage(envelope)
    }

    /// Dedupes a live semantic event against the applied journal baseline.
    /// - sequence 0 (unsequenced host): always deliver.
    /// - at/below baseline: duplicate from replay overlap — drop.
    /// - exactly baseline + 1: deliver and advance.
    /// - above baseline + 1: gap — request a sync replay and DROP this
    ///   occurrence; the replay delivers it (and anything missed) in order.
    private func applyJournaledLiveEvent(sequence: UInt64, sessionID: UUID) -> Bool {
        guard sequence > 0 else { return true }
        if sequence <= lastAppliedJournalSequence { return false }
        if sequence > lastAppliedJournalSequence + 1 {
            requestSessionSync(sessionID: sessionID, afterSequence: lastAppliedJournalSequence)
            return false
        }
        lastAppliedJournalSequence = sequence
        persistJournalBaseline(sequence, sessionID: sessionID)
        return true
    }

    /// Asks the host for the snapshot plus journaled events after a sequence.
    private func requestSessionSync(sessionID: UUID, afterSequence: UInt64) {
        let request = SessionSyncRequestMessage(sessionID: sessionID, afterSequence: afterSequence)
        if let envelope = try? DataChannelEnvelope.sessionSyncRequest(request) {
            try? webRTCSessionManager.sendDataMessage(envelope)
        }
    }

    /// The journal baseline survives app relaunches so a force-quit + reopen
    /// can still resume the same session without replaying (or missing) any
    /// semantic event. Host snapshot state wins on reconnect — this only
    /// seeds the local replay cursor.
    func checkpointForBackground() {
        guard let sessionID = activeSessionID ?? resumableSessionID else { return }
        persistJournalBaseline(lastAppliedJournalSequence, sessionID: sessionID)
    }

    private func persistedJournalBaseline(for sessionID: UUID) -> UInt64 {
        (UserDefaults.standard.object(forKey: Self.journalBaselineKeyPrefix + sessionID.uuidString) as? NSNumber)?.uint64Value ?? 0
    }

    private func persistJournalBaseline(_ value: UInt64, sessionID: UUID) {
        UserDefaults.standard.set(NSNumber(value: value), forKey: Self.journalBaselineKeyPrefix + sessionID.uuidString)
    }

    /// Terminal opens are created as soon as the workspace mounts, which can
    /// be a few frames before the ordered control channel reaches `.open`.
    /// Keep this path throwing so the tab manager can retry instead of silently
    /// losing the first open request.
    func sendTerminalEnvelope(_ envelope: DataChannelEnvelope) throws {
        guard activeSessionID != nil,
              webRTCSessionManager.connectionState == .connected,
              webRTCSessionManager.dataChannelState == .open else {
            logger.notice("Terminal envelope deferred: kind=\(envelope.kind.rawValue, privacy: .public), connection=\(self.webRTCSessionManager.connectionState.rawValue, privacy: .public), data=\(self.webRTCSessionManager.dataChannelState.rawValue, privacy: .public)")
            throw WebRTCSessionError.dataChannelUnavailable
        }
        logger.notice("Sending terminal envelope: kind=\(envelope.kind.rawValue, privacy: .public)")
        try webRTCSessionManager.sendDataMessage(envelope)
    }

    func requestWorkspaces(refresh: Bool = false) throws -> UUID {
        guard let sessionID = activeSessionID else { throw WebRTCSessionError.dataChannelUnavailable }
        let message = WorkspaceListRequestMessage(sessionID: sessionID, refresh: refresh)
        let envelope = try DataChannelEnvelope.workspaceListRequest(message)
        try sendTerminalEnvelope(envelope)
        return message.requestID
    }

    func requestWorkspaceDirectory(path: String) throws -> UUID {
        guard let sessionID = activeSessionID else { throw WebRTCSessionError.dataChannelUnavailable }
        let message = WorkspaceDirectoryRequestMessage(sessionID: sessionID, path: path)
        let envelope = try DataChannelEnvelope.workspaceDirectoryRequest(message)
        try sendTerminalEnvelope(envelope)
        return message.requestID
    }

    func requestAdditionalWorkspaceFolder() throws -> UUID {
        guard let sessionID = activeSessionID else { throw WebRTCSessionError.dataChannelUnavailable }
        let message = WorkspaceAccessRequestMessage(sessionID: sessionID)
        let envelope = try DataChannelEnvelope.workspaceAccessRequest(message)
        try sendTerminalEnvelope(envelope)
        return message.requestID
    }

    /// A small feature-specific view of transport readiness for terminal-tab
    /// lifecycle retries. The general session observer remains private to the
    /// coordinator; this stream only exposes the state needed by the workspace.
    func terminalDataChannelStateUpdates() -> AsyncStream<DataChannelState> {
        webRTCSessionManager.dataChannelStateUpdates()
    }

    func requestKeyframeRefresh(reason: String) {
        guard webRTCSessionManager.connectionState == .connected,
              let sessionID = activeSessionID,
              let envelope = try? DataChannelEnvelope.requestKeyframe(sessionID: sessionID) else { return }
        logger.info("Requesting keyframe refresh: \(reason, privacy: .public)")
        try? webRTCSessionManager.sendDataMessage(envelope)
    }

    /// Tell the host which displays to stream simultaneously (multi-monitor). Index 0 is the
    /// primary (wire displayID 0); the rest stream in parallel on wire IDs 1, 2, … in order.
    func setStreamedDisplays(_ displayIDs: [String]) {
        guard webRTCSessionManager.connectionState == .connected, !displayIDs.isEmpty else { return }
        let message = SetActiveDisplaysMessage(sessionID: activeSessionID, displayIDs: displayIDs)
        guard let envelope = try? DataChannelEnvelope.setActiveDisplays(message) else { return }
        logger.info("Requesting \(displayIDs.count) streamed display(s)")
        try? webRTCSessionManager.sendDataMessage(envelope)
    }

    func sendChatMessage(_ text: String) throws {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let limited = String(cleaned.prefix(2_000))
        let message = SessionChatMessage(
            sessionID: activeSessionID,
            senderID: clientIdentity.id,
            senderDisplayName: clientIdentity.displayName,
            senderRole: .client,
            text: limited
        )
        let envelope = try DataChannelEnvelope.chatMessage(message)
        try webRTCSessionManager.sendDataMessage(envelope)
        chatMessages.append(message)
    }

    private func startLatencyProbes() {
        latencyProbeTask?.cancel()
        latencyProbeTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.webRTCSessionManager.connectionState == .connected {
                    let ping = PingMessage(lossPermille: self.webRTCSessionManager.recentVideoLossPermille)
                    self.pendingPings[ping.id] = ping.sentAt
                    self.sentPingCount += 1
                    if let envelope = try? DataChannelEnvelope.ping(ping) {
                        try? self.webRTCSessionManager.sendDataMessage(envelope)
                    }
                    self.pruneExpiredPings(now: Date())
                    self.recomputeQuality()
                    self.checkLiveness(now: Date())
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Half-open-connection watchdog. The transport can sit in `.connected`
    /// forever on a dead TCP path (AP roam, NAT timeout, host sleep) — pongs
    /// are the only end-to-end liveness signal. Enforced only after the first
    /// pong of the session so hosts that never pong are unaffected.
    private func checkLiveness(now: Date) {
        guard receivedPongCount > 0, let lastPong = lastPongReceivedAt else { return }
        guard phase == .receiving || phase == .waitingForMedia else { return }
        // Don't stack a watchdog-driven reconnect on top of one already in flight
        // (resumeTask = reconnectLast; disconnectTask = an in-progress teardown).
        guard resumeTask == nil, disconnectTask == nil else { return }
        let silentFor = now.timeIntervalSince(lastPong)
        guard silentFor > Self.livenessTimeoutSeconds else { return }

        logger.error("Liveness timeout — no pong for \(String(format: "%.0f", silentFor))s; treating connection as lost")
        connectionDebugger.connectionLost(
            reason: "Liveness timeout — no pong for \(String(format: "%.0f", silentFor))s while transport reported connected"
        )
        phase = .error
        errorMessage = lastEndpoint != nil ? "Connection lost — reconnecting…" : "Connection lost"
        networkQuality = .poor
        Task { [weak self] in
            await self?.reconnectLast()
        }
    }

    private static let livenessTimeoutSeconds: TimeInterval = 12
    /// Max time to wait for the first video frame after the host answer is applied before failing
    /// out of `.waitingForMedia` with actionable guidance (see observeVideoFrames).
    private static let mediaArrivalTimeoutSeconds: TimeInterval = 15

    private func handlePong(_ message: PongMessage) {
        guard let sentAt = pendingPings.removeValue(forKey: message.id) else { return }
        receivedPongCount += 1
        lastPongReceivedAt = Date()
        let latency = Date().timeIntervalSince(sentAt) * 1000
        lastRoundTripLatencyMs = latency
        let lost = max(0, Int(sentPingCount) - Int(receivedPongCount) - pendingPings.count)
        packetLossPercent = sentPingCount == 0
            ? nil
            : (Double(lost) / Double(sentPingCount)) * 100
        recomputeQuality()
    }

    private func pruneExpiredPings(now: Date) {
        pendingPings = pendingPings.filter { now.timeIntervalSince($0.value) < 8 }
        let lost = max(0, Int(sentPingCount) - Int(receivedPongCount) - pendingPings.count)
        packetLossPercent = sentPingCount == 0
            ? nil
            : (Double(lost) / Double(sentPingCount)) * 100
    }

    private func recomputeQuality() {
        let diagnostics = webRTCSessionManager.streamDiagnostics
        let snapshot = SessionMetricsSnapshot(
            framesPerSecond: nil,
            bitrateKbps: nil,
            latencyMs: lastRoundTripLatencyMs,
            packetLossPercent: packetLossPercent,
            codecName: nil,
            displayName: connectedHostName,
            connectionState: webRTCSessionManager.connectionState
        )
        let quality = qualityService.classify(
            metrics: snapshot,
            isReconnecting: phase == .connecting || phase == .negotiating || diagnostics.isStalled()
        )
        networkQuality = quality
        connectionDebugger.record("quality", quality.rawValue, metadata: [
            "latencyMs": lastRoundTripLatencyMs.map { String(format: "%.0f", $0) } ?? "-",
            "lossPercent": packetLossPercent.map { String(format: "%.1f", $0) } ?? "-",
            "stalled": diagnostics.isStalled() ? "yes" : "no"
        ])
        if quality == .fair || quality == .poor, quality != lastLoggedQuality {
            lastLoggedQuality = quality
            Task {
                await eventLogStore.append(EventLogItem(
                    severity: quality == .poor ? .warning : .info,
                    category: "Quality",
                    message: "Connection quality changed to \(quality.rawValue)"
                ))
            }
        }

        // Adaptive runtime downgrade: after 3 consecutive poor-quality samples
        // (≈6 s at 2-second probe interval) request a lower preset from the host.
        if quality == .poor {
            consecutivePoorQualitySamples += 1
            consecutiveGoodQualitySamples = 0
        } else if quality == .good {
            consecutiveGoodQualitySamples += 1
            consecutivePoorQualitySamples = 0
            // Allow a future downgrade once quality recovers.
            lastDowngradeRequestPreset = nil
        } else {
            consecutivePoorQualitySamples = 0
            consecutiveGoodQualitySamples = 0
        }

        // Downgrade trigger
        if consecutivePoorQualitySamples >= 3 {
            if let targetPreset = nextDowngradedPreset(from: activeQualityPreset),
               targetPreset != lastDowngradeRequestPreset {
                lastDowngradeRequestPreset = targetPreset
                activeQualityPreset = targetPreset
                consecutivePoorQualitySamples = 0
                sendQualityAdjust(targetPreset, reason: "poor_network", upgrade: false)
            }
            return
        }

        // Upgrade trigger: after 8 consecutive good samples (~16 s) try to
        // restore one preset toward the user's originally-selected target.
        // Caps at lastQualityPreset so we never exceed what the user asked for.
        if consecutiveGoodQualitySamples >= 8 {
            if let targetPreset = nextUpgradedPreset(from: activeQualityPreset, ceiling: lastQualityPreset),
               targetPreset != lastUpgradeRequestPreset {
                lastUpgradeRequestPreset = targetPreset
                activeQualityPreset = targetPreset
                consecutiveGoodQualitySamples = 0
                sendQualityAdjust(targetPreset, reason: "network_recovered", upgrade: true)
            }
        }
    }

    func disconnectForInputFailure(_ reason: String) async {
        await disconnect()
        errorMessage = reason
        phase = .error
    }

    func setPreferredQuality(_ preset: StreamQualityPreset) {
        lastQualityPreset = preset
        activeQualityPreset = preset
        consecutivePoorQualitySamples = 0
        consecutiveGoodQualitySamples = 0
        sendQualityAdjust(preset, reason: "user_preference", upgrade: true)
    }

    private func sendQualityAdjust(_ preset: StreamQualityPreset, reason: String, upgrade: Bool) {
        let msg = QualityAdjustMessage(
            requestedPreset: preset,
            reason: reason
        )
        if let envelope = try? DataChannelEnvelope.qualityAdjust(msg) {
            try? webRTCSessionManager.sendDataMessage(envelope)
        }
        Task {
            await eventLogStore.append(EventLogItem(
                severity: upgrade ? .info : .warning,
                category: "Quality",
                message: upgrade
                    ? "Adaptive upgrade requested: \(preset.rawValue)"
                    : "Adaptive downgrade requested: \(preset.rawValue)"
            ))
        }
    }

    private func nextDowngradedPreset(from current: StreamQualityPreset) -> StreamQualityPreset? {
        // Ranking lowest→highest: performance < balanced < quality < ultra
        let ladder: [StreamQualityPreset] = [.performance, .balanced, .quality, .ultra]
        guard let idx = ladder.firstIndex(of: current), idx > 0 else { return nil }
        return ladder[idx - 1]
    }

    private func nextUpgradedPreset(
        from current: StreamQualityPreset,
        ceiling: StreamQualityPreset
    ) -> StreamQualityPreset? {
        let ladder: [StreamQualityPreset] = [.performance, .balanced, .quality, .ultra]
        guard let currentIdx = ladder.firstIndex(of: current),
              let ceilingIdx = ladder.firstIndex(of: ceiling),
              currentIdx < ceilingIdx else { return nil }
        return ladder[currentIdx + 1]
    }
}
