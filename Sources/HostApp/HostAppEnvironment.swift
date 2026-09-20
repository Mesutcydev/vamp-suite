import Foundation
import Network
import SwiftUI
import Combine
#if canImport(WidgetKit)
import WidgetKit
#endif
import OSLog
import CaptureEngine
import Diagnostics
import Discovery
import EncodeEngine
import InputControl
import Permissions
import SharedModels
import SharedProtocol
import SharedUtilities
import TransportWebRTC
import HostWidgetShared
#if os(macOS)
import AppKit
import ServiceManagement
import IOKit.pwr_mgt
import ApplicationServices
#endif

/// Journal directory for a product: sibling of the session registry's
/// `sessions/` directory (`<App Support>/<Product>/journal`).
func sessionRegistryRootURL(registryProductName: String) -> URL {
    HostSessionRegistry.standardRootURL(productName: registryProductName)
        .deletingLastPathComponent()
        .appendingPathComponent("journal", isDirectory: true)
}

@MainActor
final class HostAppEnvironment: ObservableObject {
    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "Environment")
    /// Set when the real environment is constructed, so the app delegate can
    /// reach it to start the widget bridge independent of any window/scene.
    static weak var shared: HostAppEnvironment?
    private var widgetBridge: HostWidgetBridge?
    private var widgetSnapshotNamespace: String?

    private enum Keys {
        static let sessionMode = "com.remotedesktop.host.sessionMode"
        static let lowPowerModeEnabled = "com.remotedesktop.host.lowPowerModeEnabled"
        static let terminalModeEnabled = "com.remotedesktop.host.terminalModeEnabled"
        static let keepAwakeEnabled = "com.remotedesktop.host.keepAwakeEnabled"
    }

    struct TrustPrompt: Identifiable, Equatable {
        let id: UUID
        let displayName: String
        let fingerprint: String
    }

    let hostIdentity: HostIdentity
    let productMode: HostProductMode
    let captureEngine: any CaptureEngineProtocol
    let encoderPipeline: any EncoderPipelineProtocol
    let displayLayoutProvider: any DisplayLayoutProviding
    let inputInjectionService: any InputInjectionServiceProtocol
    let permissionService: any PermissionServiceProtocol
    let runtimePolicy: MacHostRuntimePolicy
    let peerTrustGate: PeerTrustGate
    let trustedPeerStore: any TrustedPeerStoreProtocol
    let eventLogStore: any EventLogStoreProtocol
    let signalingService: any SessionCoordinatorSignaling
    let webRTCSessionManager: any WebRTCSessionManaging
    let discoveryAdvertiser: any HostDiscoveryAdvertiserProtocol
    let permissionsViewModel: HostPermissionsViewModel
    let discoveryAdvertiserViewModel: DiscoveryAdvertiserViewModel
    let streamingCoordinator: HostStreamingCoordinator
    let inputCommandRouter: HostInputCommandRouter
    let sessionCoordinator: HostSessionCoordinator
    let recordingService: SessionRecordingService
    let sessionModeController: HostSessionModeController
    #if os(macOS)
    let lockStateMonitor: LockStateMonitor
    #endif
    let thermalMonitor: ThermalMonitorService
    let lowPowerModeService: LowPowerModeService
    let performanceStateController: HostPerformanceStateController
    var fileTransferSettings: HostFileTransferSettingsStore
    var fileTransferStore: HostFileTransferStore
    var fileTransferManager: HostFileTransferManager
    var outgoingFileTransferController: HostOutgoingFileTransferController
    #if os(macOS)
    let audioPipeline: HostAudioCapturePipeline
    let workspaceService: HostWorkspaceService
    let terminalService: HostTerminalService
    let agentSemanticService: HostAgentSemanticService
    let browserControlService: HostBrowserControlService
    let sessionRegistry: HostSessionRegistry
    let sessionJournal: HostSessionJournal
    #endif

    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.remotedesktop.host.pathmonitor")
    /// Both the app delegate and the SwiftUI scene request startup so the host
    /// can run without a visible window. Their tasks can overlap while the
    /// first listener bind is suspended. Serialize that transition; otherwise
    /// a second in-process start races port 9471, publishes a false
    /// address-in-use error, and leaves the browser UI displaying a pairing
    /// code owned by the losing startup attempt.
    private var runtimeStartInProgress = false
    private var runtimeStarted = false

    @Published private(set) var pendingTrustPrompt: TrustPrompt?
    /// Deadline for the currently-pending trust prompt.  The dashboard banner
    /// uses this to render a live countdown so the host operator knows how
    /// long they have to act before the request auto-rejects.
    @Published private(set) var pendingTrustPromptDeadline: Date?
    @Published var startAtLoginEnabled: Bool = false
    @Published var startAtLoginErrorMessage: String?
    @Published var manualLowPowerModeEnabled: Bool
    /// Terminal Mode is opt-in: even an authenticated client can't spawn a
    /// shell unless the user explicitly turns it on in host settings.
    @Published var terminalModeEnabled: Bool
    /// Private browser-control status. Safari access is deliberately separate
    /// from the WebRTC media session and is exposed through Tailscale Serve or
    /// the Mac's direct 100.x tailnet address.
    #if os(macOS)
    @Published private(set) var browserControlStatus = HostBrowserControlStatus(
        running: false,
        port: nil,
        tailscaleHost: nil,
        pairingCode: "",
        pairingCodeExpiresAt: .distantPast,
        lastError: nil
    )
    private var workspaceFolderSelectionFlag = false
    #endif
    /// When on, hold a power assertion so this Mac never idle-sleeps while the host runs — keeping it
    /// reachable for remote connections. This is the practical answer for an Apple-Silicon Mac on
    /// Wi-Fi with no Sleep Proxy, which the OS cannot wake from sleep at all (so we keep it awake
    /// instead of relying on Wake-on-LAN). Opt-in; best on a desktop or a Mac left on power.
    @Published var keepAwakeEnabled: Bool

    private var trustPromptContinuation: CheckedContinuation<Bool, Never>?
    private var cancellables: Set<AnyCancellable> = []
    #if os(macOS)
    private let launchAtLoginManager = HostLaunchAtLoginManager()
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var streamingAssertionID: IOPMAssertionID = 0
    /// Held while `keepAwakeEnabled` is on — independent of the streaming assertion so the two
    /// never clobber each other's ID.
    private var keepAwakeAssertionID: IOPMAssertionID = 0
    private var wasRunningBeforeSleep = false
    /// Held for the host's whole lifetime to keep macOS App Nap from suspending the process
    /// while it sits idle in the background. App Nap is separate from sleep: a napped host
    /// stops servicing its incoming-connection listener, so a client could discover the host
    /// ("online") yet fail to connect until some unrelated activity woke the process — the
    /// "unreachable over Tailscale after a while, fixed by any inbound connection" bug.
    /// `.userInitiatedAllowingIdleSystemSleep` blocks App Nap but still lets the Mac sleep
    /// normally (forcing the Mac awake is the separate Keep-Mac-Awake assertion).
    private var appNapActivity: NSObjectProtocol?
    #endif
    /// Retains the bridge between capture engine and encoder so the weak
    /// reference inside ScreenCaptureEngine doesn't nil out.
    private var encoderCaptureFrameBridge: AnyObject?

    init(
        hostIdentity: HostIdentity,
        captureEngine: any CaptureEngineProtocol,
        encoderPipeline: any EncoderPipelineProtocol,
        displayLayoutProvider: any DisplayLayoutProviding,
        inputInjectionService: any InputInjectionServiceProtocol,
        permissionService: any PermissionServiceProtocol,
        runtimePolicy: MacHostRuntimePolicy,
        peerTrustGate: PeerTrustGate,
        trustedPeerStore: any TrustedPeerStoreProtocol,
        eventLogStore: any EventLogStoreProtocol,
        signalingService: any SessionCoordinatorSignaling,
        webRTCSessionManager: any WebRTCSessionManaging,
        discoveryAdvertiser: any HostDiscoveryAdvertiserProtocol,
        productMode: HostProductMode = .full,
        recordingService: SessionRecordingService = SessionRecordingService(),
        streamWindowGeometry: StreamWindowGeometryStore = StreamWindowGeometryStore()
    ) {
        let preferredMode = UserDefaults.standard.string(forKey: Keys.sessionMode)
            .flatMap(SessionControlMode.init(rawValue:))
            ?? .fullControl
        let storedMode = runtimePolicy.enforcedSessionMode ?? preferredMode
        let storedLowPower = UserDefaults.standard.bool(forKey: Keys.lowPowerModeEnabled)
        // Terminal Mode defaults to OFF — opt-in only.
        let storedTerminalMode = productMode.isTerminalOnly
            ? true
            : UserDefaults.standard.bool(forKey: Keys.terminalModeEnabled)
        // Keep-awake defaults to OFF — opt-in only.
        let storedKeepAwake = UserDefaults.standard.bool(forKey: Keys.keepAwakeEnabled)
        let canonicalHostIdentity: HostIdentity

        if let bonjourSignaling = signalingService as? BonjourSignalingService,
           let signalingFingerprint = bonjourSignaling.identityService?.fingerprint,
           !signalingFingerprint.isEmpty {
            if hostIdentity.publicKeyFingerprint != signalingFingerprint {
                Logger(subsystem: "com.remotedesktop.host", category: "Identity")
                    .error("Host identity fingerprint mismatch detected; canonicalizing advertised fingerprint from signaling identity")
            }

            var updatedHostIdentity = hostIdentity
            updatedHostIdentity.publicKeyFingerprint = signalingFingerprint
            canonicalHostIdentity = updatedHostIdentity
        } else {
            canonicalHostIdentity = hostIdentity
        }

        self.hostIdentity = canonicalHostIdentity
        self.productMode = productMode
        self.captureEngine = captureEngine
        self.encoderPipeline = encoderPipeline
        self.displayLayoutProvider = displayLayoutProvider
        self.inputInjectionService = inputInjectionService
        self.permissionService = permissionService
        self.runtimePolicy = runtimePolicy
        self.peerTrustGate = peerTrustGate
        self.trustedPeerStore = trustedPeerStore
        self.eventLogStore = eventLogStore
        self.signalingService = signalingService
        self.webRTCSessionManager = webRTCSessionManager
        self.discoveryAdvertiser = discoveryAdvertiser
        self.sessionModeController = HostSessionModeController(mode: storedMode)
        #if os(macOS)
        self.lockStateMonitor = LockStateMonitor()
        #endif
        self.thermalMonitor = ThermalMonitorService()
        self.lowPowerModeService = LowPowerModeService()
        self.recordingService = recordingService
        self.performanceStateController = HostPerformanceStateController(
            thermalState: .nominal,
            lowPowerModeEnabled: storedLowPower
        )
        self.fileTransferSettings = HostFileTransferSettingsStore(
            supportsDefaultDownloadsLocation: !runtimePolicy.isSandboxedDistribution
        )
        self.fileTransferStore = HostFileTransferStore()
        self.fileTransferManager = HostFileTransferManager(
            settings: self.fileTransferSettings,
            store: self.fileTransferStore
        )
        self.outgoingFileTransferController = HostOutgoingFileTransferController(
            webRTCSessionManager: webRTCSessionManager,
            hostIdentity: canonicalHostIdentity
        )
        #if os(macOS)
        let pipeline = HostAudioCapturePipeline()
        self.audioPipeline = pipeline
        let workspaceService = HostWorkspaceService(hostID: canonicalHostIdentity.id)
        self.workspaceService = workspaceService
        self.terminalService = HostTerminalService(workspaceService: workspaceService)
        self.agentSemanticService = HostAgentSemanticService(workspaceService: workspaceService)
        self.browserControlService = HostBrowserControlService()
        // Durable session registry (step B): the Mac is authoritative about
        // which sessions and PTYs exist — running, detached, or reaped —
        // even across app restarts.
        let registryProductName: String
        switch productMode {
        case .full:
            registryProductName = "Vamp Host"
        case .terminalOnly:
            registryProductName = "Terminal Host"
        case .mini:
            registryProductName = "Vamp Mini Host"
        }
        let sessionRegistry = HostSessionRegistry(
            rootURL: HostSessionRegistry.standardRootURL(productName: registryProductName)
        )
        sessionRegistry.load()
        self.sessionRegistry = sessionRegistry
        self.terminalService.registry = sessionRegistry
        // Durable semantic journal (step C): bounded, sequence-numbered
        // history of task-plan, agent, and terminal-lifecycle events per
        // session so a reconnecting client can replay exactly the delta it
        // missed. Raw terminal bytes are NOT journaled.
        let sessionJournal = HostSessionJournal(
            rootURL: sessionRegistryRootURL(registryProductName: registryProductName)
        )
        sessionJournal.load()
        self.sessionJournal = sessionJournal
        self.terminalService.journal = sessionJournal
        self.agentSemanticService.journal = sessionJournal
        #endif
        self.manualLowPowerModeEnabled = storedLowPower
        self.terminalModeEnabled = storedTerminalMode
        self.keepAwakeEnabled = storedKeepAwake
        self.permissionsViewModel = HostPermissionsViewModel(
            permissionService: permissionService,
            eventLogStore: eventLogStore
        )
        self.streamingCoordinator = HostStreamingCoordinator(
            encoderPipeline: encoderPipeline,
            webRTCSessionManager: webRTCSessionManager,
            eventLogStore: eventLogStore,
            recordingService: self.recordingService
        )
        self.inputCommandRouter = HostInputCommandRouter(
            inputService: inputInjectionService,
            webRTCSessionManager: webRTCSessionManager,
            eventLogStore: eventLogStore,
            modeProvider: self.sessionModeController
        )
        self.inputCommandRouter.setTerminalModeEnabled(storedTerminalMode)
        self.discoveryAdvertiserViewModel = DiscoveryAdvertiserViewModel(
            hostIdentity: canonicalHostIdentity,
            advertiser: discoveryAdvertiser,
            productMode: productMode,
            secureTLSPortProvider: { [signalingService] in
                (signalingService as? BonjourSignalingService)?.tlsListeningPort
            },
            keyAgreementPublicKeyProvider: { [signalingService] in
                guard let bonjour = signalingService as? BonjourSignalingService,
                      let identity = bonjour.identityService else { return nil }
                return SessionTokenSealing.deriveKeyAgreementKey(from: identity.privateKey)
                    .publicKey.x963Representation
            }
        )
        self.sessionCoordinator = HostSessionCoordinator(
            hostIdentity: canonicalHostIdentity,
            captureEngine: captureEngine,
            encoderPipeline: encoderPipeline,
            displayLayoutProvider: displayLayoutProvider,
            permissionService: permissionService,
            webRTCSessionManager: webRTCSessionManager,
            peerTrustGate: peerTrustGate,
            streamingCoordinator: self.streamingCoordinator,
            inputCommandRouter: self.inputCommandRouter,
            eventLogStore: eventLogStore,
            signalingService: signalingService,
            sessionModeController: self.sessionModeController,
            performanceStateController: self.performanceStateController,
            fileTransferManager: self.fileTransferManager,
            productMode: productMode,
            sessionTokenUnsealer: { [signalingService] sealed in
                guard let bonjour = signalingService as? BonjourSignalingService,
                      let identity = bonjour.identityService else { return nil }
                let key = SessionTokenSealing.deriveKeyAgreementKey(from: identity.privateKey)
                return SessionTokenSealing.open(sealed, with: key)
            },
            streamWindowGeometry: streamWindowGeometry,
            ensureDiscoveryAdvertising: { [weak discoveryAdvertiserViewModel = self.discoveryAdvertiserViewModel] in
                await discoveryAdvertiserViewModel?.ensureAdvertising()
            }
        )

        self.inputCommandRouter.onFileTransferMessage = { [fileTransferManager = self.fileTransferManager, outgoingFileTransferController = self.outgoingFileTransferController, webRTCSessionManager = self.webRTCSessionManager] message in
            await fileTransferManager.handle(message) { envelope in
                try? webRTCSessionManager.sendDataMessage(envelope)
            }
            await outgoingFileTransferController.handleRemoteMessage(message)
        }
        #if os(macOS)
        self.sessionCoordinator.audioPipeline = pipeline
        #endif

        self.inputCommandRouter.onDisplaySwitchRequest = { [sessionCoordinator = self.sessionCoordinator] message in
            await sessionCoordinator.handleDisplaySwitchRequest(message)
        }
        #if os(macOS)
        self.inputCommandRouter.onApplicationListRequest = { [sessionCoordinator = self.sessionCoordinator] message in
            await sessionCoordinator.handleApplicationListRequest(message)
        }
        self.inputCommandRouter.onStreamTargetSwitchRequest = { [sessionCoordinator = self.sessionCoordinator] message in
            await sessionCoordinator.handleStreamTargetSwitchRequest(message)
        }
        self.inputCommandRouter.onApplicationCloseRequest = { [sessionCoordinator = self.sessionCoordinator] message in
            await sessionCoordinator.handleApplicationCloseRequest(message)
        }
        #endif
        // Remote login-screen unlock uses the same Accessibility-backed input path as
        // normal control, so it stays unavailable in sandboxed builds.
        #if os(macOS)
        if runtimePolicy.supportsRemoteUnlock {
            self.inputCommandRouter.remoteUnlockEnabled = {
                UserDefaults.standard.object(forKey: "host.remoteUnlock.enabled") as? Bool ?? false
            }
            let loginWindowInput = LoginWindowInputService()
            self.inputCommandRouter.onUnlockPassword = { [eventLogStore] password in
                do {
                    try await loginWindowInput.submit(password: password)
                    Logger(subsystem: "com.remotedesktop.host", category: "RemoteUnlock")
                        .info("Remote unlock keystrokes posted; waiting for lock-state confirmation")
                } catch {
                    // Don't silently swallow: a failed remote unlock keystroke injection
                    // (event tap blocked, login window not focused, etc.) must be visible
                    // in logs and the event log so the operator can diagnose it.
                    Logger(subsystem: "com.remotedesktop.host", category: "RemoteUnlock")
                        .error("Remote unlock keystroke injection failed: \(error.localizedDescription, privacy: .public)")
                    await eventLogStore.append(EventLogItem(
                        severity: .error,
                        category: "Trust",
                        message: "Remote unlock failed: could not inject login keystrokes (\(error.localizedDescription))"
                    ))
                }
            }
        }
        #endif
        self.inputCommandRouter.onClipboardSync = { text in
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
        }
        self.inputCommandRouter.onClipboardRequest = { [weak self] in
            #if os(macOS)
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let sessionID = self.sessionCoordinator.activeSessionID else { return }
                let message = ClipboardSyncMessage(sessionID: sessionID, text: text, source: "host")
                guard let envelope = try? DataChannelEnvelope.clipboardSync(message) else { return }
                try? self.webRTCSessionManager.sendDataMessage(envelope)
            }
            #endif
        }

        // Terminal Mode spawns an interactive login shell and remains behind the
        // operator-controlled Terminal Mode setting.
        #if os(macOS)
        // Terminal Mode: the service writes output envelopes through the
        // WebRTC data channel; the router routes incoming open/input/resize/
        // close envelopes back into the service.
        self.terminalService.sendEnvelope = { [weak webRTCSessionManager = self.webRTCSessionManager] envelope in
            try? webRTCSessionManager?.sendDataMessage(envelope)
        }
        self.agentSemanticService.sendEnvelope = { [weak webRTCSessionManager = self.webRTCSessionManager] envelope in
            try? webRTCSessionManager?.sendDataMessage(envelope)
        }
        self.inputCommandRouter.onTerminalOpen = { [terminalService = self.terminalService] message in
            // The router has already authenticated, routed, and feature-gated
            // this packet. HostTerminalService is queue-isolated, so invoke it
            // directly instead of bouncing through the main actor. A main-actor
            // hop here could strand the client in "Opening shell…" while the
            // retry loop kept sending duplicate terminalOpen packets.
            terminalService.handleOpen(message)
        }
        self.inputCommandRouter.onTerminalInput = { [weak terminalService = self.terminalService] message in
            terminalService?.handleInput(message)
        }
        self.inputCommandRouter.onTerminalResize = { [weak terminalService = self.terminalService] message in
            terminalService?.handleResize(message)
        }
        self.inputCommandRouter.onTerminalClose = { [weak terminalService = self.terminalService] message in
            terminalService?.handleClose(message)
        }
        self.inputCommandRouter.onAgentPrompt = { [weak agentSemanticService = self.agentSemanticService] message in
            agentSemanticService?.handlePrompt(message)
        }
        // Resumable-session sync (step D): answer a reconnecting client with
        // the authoritative snapshot plus a bounded replay of the journaled
        // semantic events it missed while away.
        self.inputCommandRouter.onSessionSyncRequest = { [weak self, webRTCSessionManager = self.webRTCSessionManager] message in
            guard let self else { return }
            let record = self.sessionRegistry.sessionRecord(message.sessionID)
            let terminals = (record?.terminals ?? []).map { terminal in
                SessionSnapshotMessage.TerminalSnapshot(
                    terminalID: terminal.terminalID,
                    workspaceID: terminal.workspaceID,
                    workspacePath: terminal.workspacePath,
                    cols: terminal.cols,
                    rows: terminal.rows,
                    state: terminal.state.rawValue,
                    lastSequence: terminal.lastSequence
                )
            }
            let snapshot = SessionSnapshotMessage(
                sessionID: message.sessionID,
                sessionState: record?.state.rawValue ?? "reaped",
                lastJournalSequence: self.sessionJournal.lastSequence(sessionID: message.sessionID),
                terminals: terminals
            )
            if let envelope = try? DataChannelEnvelope.sessionSnapshot(snapshot) {
                try? webRTCSessionManager.sendDataMessage(envelope)
            }
            let events = self.sessionJournal.events(sessionID: message.sessionID, after: message.afterSequence)
            for event in events {
                let syncEvent = SessionSyncEventMessage(
                    sessionID: message.sessionID,
                    journalSequence: event.sequence,
                    kind: event.type.rawValue,
                    payload: event.payload
                )
                if let envelope = try? DataChannelEnvelope.sessionSyncEvent(syncEvent) {
                    try? webRTCSessionManager.sendDataMessage(envelope)
                }
            }
        }
        self.inputCommandRouter.onWorkspaceListRequest = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self,
                      self.sessionCoordinator.activeSessionID == message.sessionID else { return }
                let workspaceService = self.workspaceService
                // Browsing roots are cheap and must be usable immediately.
                // Project discovery can traverse several developer folders,
                // so never make the launch sheet wait on that scan.
                let initialResponse = WorkspaceListResponseMessage(
                    sessionID: message.sessionID,
                    requestID: message.requestID,
                    hostID: workspaceService.hostID,
                    workspaces: [],
                    roots: workspaceService.availableBrowseRoots()
                )
                if let envelope = try? DataChannelEnvelope.workspaceListResponse(initialResponse) {
                    try? self.webRTCSessionManager.sendDataMessage(envelope)
                }
                workspaceService.listWorkspaces(refresh: message.refresh) { [weak self] workspaces, roots, errorMessage in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.sessionCoordinator.activeSessionID == message.sessionID else { return }
                        let response = WorkspaceListResponseMessage(
                            sessionID: message.sessionID,
                            requestID: message.requestID,
                            hostID: workspaceService.hostID,
                            workspaces: workspaces,
                            roots: roots,
                            errorMessage: errorMessage
                        )
                        guard let envelope = try? DataChannelEnvelope.workspaceListResponse(response) else { return }
                        try? self.webRTCSessionManager.sendDataMessage(envelope)
                    }
                }
            }
        }
        self.inputCommandRouter.onWorkspaceDirectoryRequest = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self,
                      self.sessionCoordinator.activeSessionID == message.sessionID else { return }
                self.logger.notice("Listing requested workspace directory")
                let workspaceService = self.workspaceService
                workspaceService.listDirectory(path: message.path) { [weak self] canonicalPath, entries, errorMessage in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.sessionCoordinator.activeSessionID == message.sessionID else { return }
                        let response = WorkspaceDirectoryResponseMessage(
                            sessionID: message.sessionID,
                            requestID: message.requestID,
                            path: canonicalPath,
                            entries: entries,
                            errorMessage: errorMessage
                        )
                        guard let envelope = try? DataChannelEnvelope.workspaceDirectoryResponse(response) else { return }
                        do {
                            try self.webRTCSessionManager.sendDataMessage(envelope)
                            self.logger.notice("Sent workspace directory response")
                        } catch {
                            self.logger.error("Workspace directory response failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
        }
        self.inputCommandRouter.onWorkspaceAccessRequest = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self,
                      self.sessionCoordinator.activeSessionID == message.sessionID else { return }
                self.chooseAdditionalWorkspaceFolder { [weak self] approved in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.sessionCoordinator.activeSessionID == message.sessionID else { return }
                        let response = WorkspaceAccessResponseMessage(
                            sessionID: message.sessionID,
                            requestID: message.requestID,
                            approved: approved,
                            errorMessage: approved ? nil : "Folder selection was cancelled on the Mac."
                        )
                        guard let envelope = try? DataChannelEnvelope.workspaceAccessResponse(response) else { return }
                        try? self.webRTCSessionManager.sendDataMessage(envelope)
                    }
                }
            }
        }
        self.inputCommandRouter.onSessionStarted = { [weak terminalService = self.terminalService] sessionID in
            terminalService?.transportAttached(sessionID: sessionID)
        }
        // Transport loss must NEVER tear remote shells down: mark the session
        // detached so its PTYs keep running and a reconnect can reattach.
        // Explicit ends (per-tab close, Terminal Mode off, host quit) reach
        // the service through sessionDidEnd/handleClose instead.
        self.inputCommandRouter.onSessionTransportEnded = { [weak terminalService = self.terminalService] sessionID in
            terminalService?.transportDetached(sessionID: sessionID)
        }

        #if os(macOS)
        self.browserControlService.terminalModeProvider = { [weak self] in
            self?.terminalModeEnabled ?? false
        }
        self.browserControlService.workspaceService = self.workspaceService
        self.browserControlService.requestWorkspaceAccess = { [weak self] completion in
            Task { @MainActor [weak self] in
                guard let self else { completion(false); return }
                self.chooseAdditionalWorkspaceFolder(completion: completion)
            }
        }
        self.browserControlService.readClipboard = {
            NSPasteboard.general.string(forType: .string)
        }
        self.browserControlService.writeClipboard = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        self.browserControlService.onStatusChange = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.browserControlStatus = status
            }
        }
        self.browserControlStatus = self.browserControlService.currentStatus()
        #endif
        #endif

        if let bonjourSignaling = self.signalingService as? BonjourSignalingService,
           bonjourSignaling.identityService == nil {
            bonjourSignaling.identityService = CryptoIdentityService(tag: "com.remotedesktop.host.p256")
        }

        fileTransferSettings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        installTrustApprovalHandler()
        bindPerformanceMonitoring()
        refreshStartAtLoginState()
        #if os(macOS)
        sessionCoordinator.lockStateProvider = { [weak lockStateMonitor = self.lockStateMonitor] in
            lockStateMonitor?.currentLockState ?? .unlockedActiveSession
        }
        sessionCoordinator.lockStatePublisher = lockStateMonitor.$lockState.eraseToAnyPublisher()
        startSleepWakeObservation()
        bindStreamingAssertions()
        // Restore the keep-awake assertion on launch if the user left it enabled, so a Mac that
        // can't be woken remotely (Apple Silicon on Wi-Fi, no Sleep Proxy) stays reachable.
        if keepAwakeEnabled { acquireKeepAwakeAssertion() }
        lockStateMonitor.startMonitoring()
        preventAppNap()
        #endif
        startNetworkMonitoring()
    }

    #if os(macOS)
    /// Keep macOS App Nap from suspending the host while it idles in the background, so its
    /// incoming-connection listener keeps responding (the "reachable then unreachable over
    /// Tailscale until something pokes the Mac" bug). Held for the process lifetime.
    private func preventAppNap() {
        guard appNapActivity == nil else { return }
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "Vamp Host stays reachable for incoming remote connections"
        )
    }
    #endif

    var displayLayoutChanges: AsyncStream<DisplayLayout>? {
        (displayLayoutProvider as? any DisplayLayoutObserving)?.layoutChanges()
    }

    static func placeholder(
        mode: HostProductMode = .full,
        identityTag: String = "com.remotedesktop.host.p256",
        trustedPeerDirectory: URL? = nil
    ) -> HostAppEnvironment {
        let cryptoIdentity = CryptoIdentityService(tag: identityTag)
        let fingerprint = cryptoIdentity.fingerprint
        let host = HostIdentity(
            id: HostIdentity.stableID(publicKeyFingerprint: fingerprint) ?? UUID(),
            displayName: currentHostDisplayName(),
            modelName: "Mac",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: "0.1",
            publicKeyFingerprint: fingerprint
        )
        let services = PlaceholderHostServices()
        let eventLogStore = InMemoryEventLogStore()
        let recordingService = SessionRecordingService()
        let runtimePolicy = currentRuntimePolicy(for: mode)
        #if os(macOS)
        let permissionService: any PermissionServiceProtocol = MacHostPermissionService(policy: runtimePolicy)
        let displayLayoutProvider: any DisplayLayoutProviding = CoreGraphicsDisplayLayoutProvider()
        let captureEngine: any CaptureEngineProtocol
        let encoderPipeline: any EncoderPipelineProtocol
        let encoderBridge: EncoderCaptureFrameBridge?
        if mode.isTerminalOnly {
            // Keep the light product free of ScreenCaptureKit and VideoToolbox
            // initialization. The coordinator never starts these services in
            // terminal-only mode, but using placeholders here also keeps launch
            // and permission checks terminal-only.
            captureEngine = services
            encoderPipeline = services
            encoderBridge = nil
        } else {
            let screenCaptureEngine = ScreenCaptureEngine()
            let encoder = VideoToolboxEncoder()
            let bridge = EncoderCaptureFrameBridge(encoder: encoder)
            bridge.sampleBufferMirroringHandler = { sampleBuffer, _ in
                recordingService.append(sampleBuffer: sampleBuffer)
            }
            screenCaptureEngine.setFrameReceiver(bridge)
            captureEngine = screenCaptureEngine
            encoderPipeline = encoder
            encoderBridge = bridge
        }
        #else
        let permissionService: any PermissionServiceProtocol = services
        let displayLayoutProvider: any DisplayLayoutProviding = services
        let captureEngine: any CaptureEngineProtocol = services
        let encoderPipeline: any EncoderPipelineProtocol = services
        #endif
        // Shared between the input layout provider and the session coordinator: when a window is
        // the stream target this holds the window's synthetic layout so input maps into the window.
        let streamWindowGeometry = StreamWindowGeometryStore()
        #if os(macOS)
        let inputService: any InputInjectionServiceProtocol
        if !mode.isTerminalOnly && runtimePolicy.supportsRemoteInput {
            let inputBridge = CGEventInputBridge()
            let dlp = displayLayoutProvider
            inputService = HostInputInjectionService(
                bridge: inputBridge,
                accessibilityChecker: { AXIsProcessTrusted() },
                layoutProvider: { [streamWindowGeometry] in
                    // Window target present ⇒ translate input against the window's origin/size;
                    // otherwise the real display layout, unchanged.
                    if let windowLayout = streamWindowGeometry.windowLayout { return windowLayout }
                    return try await dlp.currentDisplayLayout()
                }
            )
        } else {
            inputService = DisabledInputInjectionService()
        }
        #else
        let inputService: any InputInjectionServiceProtocol = services
        #endif
        let signalingService = BonjourSignalingService()
        signalingService.identityService = cryptoIdentity
        let peerConnectionProvider = LANPeerConnectionProvider()
        peerConnectionProvider.useFixedDataPort = true
        let webRTCSessionManager = WebRTCSessionManager(peerConnectionProvider: peerConnectionProvider)
        let trustedPeerStore = PersistentTrustedPeerStore(directory: trustedPeerDirectory)
        let peerTrustGate = PeerTrustGate(store: trustedPeerStore)
        let environment = HostAppEnvironment(
            hostIdentity: host,
            captureEngine: captureEngine,
            encoderPipeline: encoderPipeline,
            displayLayoutProvider: displayLayoutProvider,
            inputInjectionService: inputService,
            permissionService: permissionService,
            runtimePolicy: runtimePolicy,
            peerTrustGate: peerTrustGate,
            trustedPeerStore: trustedPeerStore,
            eventLogStore: eventLogStore,
            signalingService: signalingService,
            webRTCSessionManager: webRTCSessionManager,
            discoveryAdvertiser: BonjourHostDiscoveryAdvertiser(),
            productMode: mode,
            recordingService: recordingService,
            streamWindowGeometry: streamWindowGeometry
        )
        #if os(macOS)
        environment.encoderCaptureFrameBridge = encoderBridge
        #endif
        HostAppEnvironment.shared = environment
        return environment
    }

    private static func currentRuntimePolicy(for mode: HostProductMode) -> MacHostRuntimePolicy {
        mode.isTerminalOnly ? .terminalOnly : .current
    }

    private static func currentHostDisplayName() -> String {
        #if os(macOS)
        if let localizedName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localizedName.isEmpty {
            return localizedName
        }
        #endif

        let hostName = ProcessInfo.processInfo.hostName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".local", with: "")
        if !hostName.isEmpty {
            return hostName
        }

        return "Mac Host"
    }

    #if os(macOS)
    /// Start the desktop-widget bridge (status publishing + action handling).
    /// Called from the app delegate so it runs regardless of window/scene state.
    func activateWidgetBridge(hostName: String? = nil, snapshotNamespace: String? = nil) {
        guard widgetBridge == nil else { return }
        widgetSnapshotNamespace = snapshotNamespace
        let bridge = HostWidgetBridge(
            environment: self,
            hostName: hostName,
            snapshotNamespace: snapshotNamespace
        )
        widgetBridge = bridge
        bridge.start()
        refreshWidgetInstallSuppression()
    }

    /// Re-query whether the desktop widget is installed and hide the dashboard
    /// when it is. Safe to call repeatedly (app launch, become-active, poll).
    func refreshWidgetInstallSuppression() {
        widgetBridge?.checkWidgetInstalled { installed in
            if installed {
                HostWindowCloseBehaviorController.shared.suppressWindowForWidget()
            }
        }
    }

    /// Apply a widget control action against the live runtime. Called directly from
    /// the URL handler when the app is already running, so a button press doesn't have
    /// to round-trip through the shared file + 1 s poll (which depends on the bridge
    /// having started and the app-group container resolving). Falls back to staging the
    /// action on disk when the bridge isn't up yet, so a cold launch still applies it.
    func applyWidgetAction(_ action: HostWidgetAction) {
        if let widgetBridge {
            widgetBridge.handle(action: action)
        } else {
            HostWidgetStore.setPendingAction(action)
        }
    }

    /// Approve a pending pairing only when `vamp` wrote a fingerprint-bound
    /// trust file after an independent check. URL query fingerprints are ignored.
    func consumeCLITrustApproval() -> Bool {
        guard let fingerprint = HostWidgetStore.consumePendingTrustApproval(namespace: widgetSnapshotNamespace)
        else { return false }
        return resolveTrustPrompt(approved: true, matchingFingerprint: fingerprint)
    }

    /// Write an "offline" snapshot so the widget reflects that the host app is no
    /// longer running (instead of showing a stale "ready").
    func publishWidgetOffline(snapshotNamespace: String? = nil) {
        let snapshot = HostWidgetSnapshot(
            phase: .idle,
            statusTitle: "host app closed",
            hostName: hostIdentity.displayName,
            primaryAddress: nil,
            addressLabel: nil,
            connectedClient: nil,
            updatedAt: Date()
        )
        HostWidgetStore.save(snapshot, namespace: snapshotNamespace)
        WidgetCenter.shared.reloadTimelines(ofKind: HostWidgetConstants.widgetKind)
    }
    #endif

    func startRuntimeIfNeeded() async {
        guard !runtimeStartInProgress, !runtimeStarted else { return }
        runtimeStartInProgress = true
        runtimeStarted = true
        defer { runtimeStartInProgress = false }

        await permissionsViewModel.refresh()
        // Bind the signaling sockets before publishing Bonjour metadata. In particular,
        // never advertise `stlsp=9473` merely because the identity exists: clients must
        // only choose TLS after the actual listener has reached .ready.
        await sessionCoordinator.startSession()
        // Do not publish a discoverable or browser endpoint when the signaling listener
        // failed to bind (most commonly because the other Vamp host product owns 9471).
        // A stale advertisement makes clients attempt a secure connection to a host that
        // cannot complete the session and hides the actionable port-conflict message.
        guard sessionCoordinator.phase != .error else {
            runtimeStarted = false
            return
        }
        await discoveryAdvertiserViewModel.startIfNeeded()
        #if os(macOS)
        // Keep the loopback path for Tailscale Serve and, when available,
        // allow the browser service to accept the Mac's 100.x Tailscale
        // address. The service performs the binding and path restriction.
        let tailscaleInfo = await Task.detached(priority: .utility) {
            getTailscaleConnectionInfo()
        }.value
        browserControlService.start(tailscaleHost: tailscaleInfo?.ipAddress)
        #endif
    }

    func stopRuntime() async {
        runtimeStarted = false
        #if os(macOS)
        browserControlService.stop()
        #endif
        await sessionCoordinator.stopSession()
        await discoveryAdvertiserViewModel.stop()
    }

    #if os(macOS)
    func rotateBrowserPairingCode() {
        // The host service serializes the rotation with listener/client state.
        // Reflect the returned snapshot immediately so the QR card and the
        // manually displayed code cannot briefly disagree after a tap.
        browserControlStatus = browserControlService.rotatePairingCode()
    }

    func retryBrowserControl() {
        let tailscaleHost = getTailscaleConnectionInfo()?.ipAddress
        browserControlService.start(tailscaleHost: tailscaleHost)
    }

    /// Adds one operator-approved directory to the workspace roots. The host
    /// persists a security-scoped bookmark, so iOS and Safari can reuse it
    /// without prompting for the same folder on every request.
    private var workspaceFolderSelectionInProgress: Bool {
        get { workspaceFolderSelectionFlag }
        set { workspaceFolderSelectionFlag = newValue }
    }

    func chooseAdditionalWorkspaceFolder(completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        guard !workspaceFolderSelectionInProgress else {
            completion(false)
            return
        }
        workspaceFolderSelectionInProgress = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a project folder to make available to Vamp Terminal."
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { completion(false); return }
                self.workspaceFolderSelectionInProgress = false
                guard response == .OK, let url = panel.url else {
                    completion(false)
                    return
                }
                completion(self.workspaceService.addApprovedRoot(url))
            }
        }
    }
    #endif

    func resolveTrustPrompt(approved: Bool) {
        trustPromptContinuation?.resume(returning: approved)
        trustPromptContinuation = nil
        pendingTrustPrompt = nil
        pendingTrustPromptDeadline = nil
    }

    /// Resolve a trust prompt only when the caller proves it observed the
    /// currently displayed peer fingerprint. This is used by the local `vamp`
    /// CLI; ordinary widget/deep links remain unable to approve a device.
    func resolveTrustPrompt(approved: Bool, matchingFingerprint fingerprint: String) -> Bool {
        guard let pendingTrustPrompt,
              pendingTrustPrompt.fingerprint.caseInsensitiveCompare(fingerprint) == .orderedSame
        else { return false }
        resolveTrustPrompt(approved: approved)
        return true
    }

    func resolveFileTransferPrompt(approved: Bool) {
        fileTransferStore.resolvePrompt(approved: approved)
    }

    func sendFileToConnectedClient() async {
        guard let sessionID = sessionCoordinator.activeSessionID,
              sessionCoordinator.phase == .streaming else {
            outgoingFileTransferController.dismissTransfer()
            return
        }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Send"
        panel.message = "Choose a file to send to the connected client Mac. The client Mac user must approve and choose where to save it."
        if panel.runModal() == .OK, let url = panel.url {
            outgoingFileTransferController.sendFile(url: url, sessionID: sessionID)
        }
        #endif
    }

    func refreshStartAtLoginState() {
        #if os(macOS)
        startAtLoginEnabled = launchAtLoginManager.isEnabled
        if launchAtLoginManager.requiresApproval {
            startAtLoginErrorMessage = "Start at Login needs approval in System Settings > General > Login Items."
        } else {
            startAtLoginErrorMessage = nil
        }
        #endif
    }

    func setStartAtLogin(_ enabled: Bool) {
        #if os(macOS)
        if enabled == startAtLoginEnabled {
            return
        }
        do {
            try launchAtLoginManager.setEnabled(enabled)
            startAtLoginEnabled = launchAtLoginManager.isEnabled
            if enabled && launchAtLoginManager.requiresApproval {
                startAtLoginErrorMessage = "Start at Login is pending approval in System Settings > General > Login Items."
            } else {
                startAtLoginErrorMessage = nil
            }
        } catch {
            startAtLoginEnabled = launchAtLoginManager.isEnabled
            startAtLoginErrorMessage = "Failed to update Start at Login: \(error.localizedDescription)"
        }
        #endif
    }

    /// Opens the macOS Login Items pane when ServiceManagement needs the user
    /// to approve a launch-at-login request.
    func openStartAtLoginSettings() {
        #if os(macOS)
        let settingsURLs = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.LoginItems-Settings"
        ]
        for rawValue in settingsURLs {
            guard let url = URL(string: rawValue) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
        #endif
    }

    func setSessionMode(_ mode: SessionControlMode) {
        let resolvedMode = runtimePolicy.enforcedSessionMode ?? mode
        sessionModeController.setMode(resolvedMode)
        UserDefaults.standard.set(resolvedMode.rawValue, forKey: Keys.sessionMode)
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "SessionMode",
                message: "Host session mode changed to \(resolvedMode.rawValue)"
            ))
            await sessionCoordinator.publishHostStatusUpdate()
        }
    }

    func setKeepAwakeEnabled(_ isEnabled: Bool) {
        keepAwakeEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Keys.keepAwakeEnabled)
        #if os(macOS)
        if isEnabled { acquireKeepAwakeAssertion() } else { releaseKeepAwakeAssertion() }
        #endif
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Power",
                message: "Keep Mac awake & reachable \(isEnabled ? "enabled" : "disabled")"
            ))
        }
    }

    func setManualLowPowerModeEnabled(_ isEnabled: Bool) {
        manualLowPowerModeEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Keys.lowPowerModeEnabled)
        performanceStateController.setLowPowerModeEnabled(isEnabled || lowPowerModeService.systemLowPowerModeEnabled)
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Power",
                message: "Host low-power mode \(isEnabled ? "enabled" : "disabled")"
            ))
            await sessionCoordinator.applyPerformanceProfileIfNeeded()
        }
    }

    func setTerminalModeEnabled(_ isEnabled: Bool) {
        if productMode.isTerminalOnly {
            terminalModeEnabled = true
            return
        }
        terminalModeEnabled = isEnabled
        inputCommandRouter.setTerminalModeEnabled(isEnabled)
        UserDefaults.standard.set(isEnabled, forKey: Keys.terminalModeEnabled)
        #if os(macOS)
        // Turning the feature off mid-session must kill any live shell.
        if !isEnabled {
            terminalService.sessionDidEnd(notifyClient: true, reason: "terminal-disabled")
            agentSemanticService.sessionDidEnd()
        }
        #endif
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Terminal",
                message: "Terminal Mode \(isEnabled ? "enabled" : "disabled")"
            ))
        }
    }

    private func installTrustApprovalHandler() {
        Task { [weak self] in
            guard let self else { return }
            await peerTrustGate.setApprovalHandler { [weak self] peerID, displayName, fingerprint in
                guard let self else { return false }
                return await self.presentTrustPrompt(
                    peerID: peerID,
                    displayName: displayName,
                    fingerprint: fingerprint
                )
            }
        }
    }

    private func presentTrustPrompt(peerID: UUID, displayName: String, fingerprint: String) async -> Bool {
        guard trustPromptContinuation == nil else { return false }
        pendingTrustPrompt = TrustPrompt(id: peerID, displayName: displayName, fingerprint: fingerprint)
        pendingTrustPromptDeadline = Date().addingTimeInterval(RemoteDesktopConstants.trustPromptTimeout)
#if os(macOS)
        // Pairing is deliberately host-approved, but a hidden/menu-bar-only
        // dashboard must not make the client look like it failed silently.
        // `bringExistingWindowFront` orders the window but does not activate
        // the application when it returns true, which can leave the sheet
        // behind the active simulator, Safari, or another Mac app.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            _ = HostWindowCloseBehaviorController.shared.bringExistingWindowFront()
            if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
#endif
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                trustPromptContinuation = continuation
            }
        } onCancel: {
            // When the trust timeout fires, dismiss the prompt and unblock the continuation
            Task { @MainActor [weak self] in
                self?.resolveTrustPrompt(approved: false)
            }
        }
    }

    private func bindPerformanceMonitoring() {
        thermalMonitor.$thermalState
            .sink { [weak self] thermalState in
                guard let self else { return }
                self.performanceStateController.setThermalState(thermalState)
                Task {
                    await self.eventLogStore.append(EventLogItem(
                        severity: thermalState == .serious || thermalState == .critical ? .warning : .info,
                        category: "Thermal",
                        message: "Thermal state changed to \(thermalState.rawValue)"
                    ))
                    await self.sessionCoordinator.applyPerformanceProfileIfNeeded()
                    await self.sessionCoordinator.publishHostStatusUpdate()
                }
            }
            .store(in: &cancellables)

        lowPowerModeService.$systemLowPowerModeEnabled
            .sink { [weak self] isSystemEnabled in
                guard let self else { return }
                self.performanceStateController.setLowPowerModeEnabled(self.manualLowPowerModeEnabled || isSystemEnabled)
                Task {
                    await self.eventLogStore.append(EventLogItem(
                        severity: .info,
                        category: "Power",
                        message: "System low-power mode \(isSystemEnabled ? "enabled" : "disabled")"
                    ))
                    await self.sessionCoordinator.applyPerformanceProfileIfNeeded()
                    await self.sessionCoordinator.publishHostStatusUpdate()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Sleep / Wake

    #if os(macOS)
    private func startSleepWakeObservation() {
        let nc = NSWorkspace.shared.notificationCenter

        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.wasRunningBeforeSleep = (self.sessionCoordinator.phase != .idle)
                if self.wasRunningBeforeSleep {
                    await self.stopRuntime()
                }
                self.releaseStreamingAssertion()
            }
        }

        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.wasRunningBeforeSleep else { return }
                self.wasRunningBeforeSleep = false
                // Brief delay so networking stack is fully up after wake
                try? await Task.sleep(for: .seconds(1.5))
                await self.startRuntimeIfNeeded()
            }
        }
    }

    private func bindStreamingAssertions() {
        sessionCoordinator.$phase
            .sink { [weak self] phase in
                guard let self else { return }
                if phase == .streaming {
                    self.acquireStreamingAssertion()
                } else {
                    self.releaseStreamingAssertion()
                }
            }
            .store(in: &cancellables)
    }

    private func acquireStreamingAssertion() {
        guard streamingAssertionID == 0 else { return }
        // Prevent *display* idle sleep while streaming (this also keeps the system awake). A sleeping
        // display stops producing capture frames, freezing the remote view — so the display must stay
        // on for the duration of the stream, not just the system.
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Vamp Host is actively streaming to a remote client" as CFString,
            &streamingAssertionID
        )
    }

    private func releaseStreamingAssertion() {
        guard streamingAssertionID != 0 else { return }
        IOPMAssertionRelease(streamingAssertionID)
        streamingAssertionID = 0
    }

    private func acquireKeepAwakeAssertion() {
        guard keepAwakeAssertionID == 0 else { return }
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Vamp Host is keeping this Mac awake so it stays reachable for remote connections" as CFString,
            &keepAwakeAssertionID
        )
    }

    private func releaseKeepAwakeAssertion() {
        guard keepAwakeAssertionID != 0 else { return }
        IOPMAssertionRelease(keepAwakeAssertionID)
        keepAwakeAssertionID = 0
    }
    #endif

    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // Wi-Fi-only (no wired Ethernet) means an Apple-Silicon Mac can't be magic-packet woken —
            // feed this to the advertiser so the client can warn instead of offering a doomed wake.
            let isWiFiOnly = path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                await self.discoveryAdvertiserViewModel.updateActiveInterface(isWiFiOnly: isWiFiOnly)
                let info = await Task.detached(priority: .utility) {
                    getTailscaleConnectionInfo()
                }.value
                await self.discoveryAdvertiserViewModel.updateTailscaleIdentity(hostname: info?.dnsName, ip: info?.ipAddress)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    deinit {
        pathMonitor.cancel()
        // Always release power assertions on teardown — otherwise a streaming session or the
        // keep-awake toggle that was active at quit can hold the Mac awake indefinitely after exit.
        if streamingAssertionID != 0 {
            IOPMAssertionRelease(streamingAssertionID)
        }
        if keepAwakeAssertionID != 0 {
            IOPMAssertionRelease(keepAwakeAssertionID)
        }
    }
}

final class PlaceholderHostServices:
    CaptureEngineProtocol,
    EncoderPipelineProtocol,
    DisplayLayoutProviding,
    InputInjectionServiceProtocol,
    PermissionServiceProtocol,
    TrustedPeerStoreProtocol,
    EventLogStoreProtocol,
    SignalingServiceProtocol,
    WebRTCSessionManaging
{
    var isCapturing: Bool { false }
    var captureState: CaptureState { .stopped }
    var diagnostics: CaptureDiagnostics { CaptureDiagnostics() }
    var isEncoding: Bool { false }
    var encoderState: EncoderState { .idle }
    var encoderDiagnostics: EncoderDiagnostics { EncoderDiagnostics() }
    var connectionState: ConnectionState { .idle }
    var peerConnectionState: PeerConnectionState { .closed }
    var dataChannelState: DataChannelState { .closed }
    var mediaChannelReadiness: MediaChannelReadiness { MediaChannelReadiness() }

    func startCapture(displayID: String, qualityPreset: StreamQualityPreset, allowsHighResolution: Bool) async throws {}
    func stopCapture() async {}
    func setFrameReceiver(_ receiver: (any CaptureFrameReceiver)?) {}
    func setAudioReceiver(_ receiver: (any CaptureAudioReceiver)?) {}
    func stateChanges() -> AsyncStream<CaptureState> {
        AsyncStream { $0.yield(.stopped); $0.finish() }
    }
    func configure(for display: DisplayDescriptor, qualityPreset: StreamQualityPreset, codec: EncodedFrameCodec) async throws {}
    func reconfigure(for display: DisplayDescriptor, qualityPreset: StreamQualityPreset, codec: EncodedFrameCodec) async throws {}
    func configure(
        for display: DisplayDescriptor,
        qualityPreset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        dynamicRange: StreamDynamicRange,
        minLongEdge: Int
    ) async throws {}
    func reconfigure(
        for display: DisplayDescriptor,
        qualityPreset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        dynamicRange: StreamDynamicRange,
        minLongEdge: Int
    ) async throws {}
    func startEncoding() async throws {}
    func flush() async throws {}
    func stopEncoding() async {}
    func setEncodedFrameReceiver(_ receiver: (any EncodedFrameReceiver)?) {}
    func stateChanges() -> AsyncStream<EncoderState> {
        AsyncStream { $0.yield(.idle); $0.finish() }
    }
    func forceKeyframe() {}
    func currentDisplayLayout() async throws -> DisplayLayout { .placeholder }
    func inject(_ command: InputCommand) async throws {}
    func perform(_ shortcut: ShortcutCommand) async throws {}
    func currentStates() async -> [PermissionState] { PermissionKind.allCases.map { PermissionState(kind: $0, authorizationState: .unknown) } }
    func refreshState(for kind: PermissionKind) async -> PermissionState { PermissionState(kind: kind, authorizationState: .unknown) }
    func requestPermission(for kind: PermissionKind) async throws -> PermissionState { PermissionState(kind: kind, authorizationState: .unknown) }
    func trustedPeers() async throws -> [TrustedPeer] { [] }
    func trustPeer(_ peer: TrustedPeer) async throws {}
    func revokePeer(id: UUID) async throws {}
    func append(_ item: EventLogItem) async {}
    func recentItems(limit: Int) async -> [EventLogItem] { [] }
    func removeAll() async {}
    func startAdvertising(host: HostIdentity) async throws {}
    func stopAdvertising() async {}
    func sendHello(_ message: HelloMessage, to host: HostIdentity) async throws {}
    func sendOffer(_ message: SessionOfferMessage, to host: HostIdentity) async throws {}
    func sendAnswer(_ message: SessionAnswerMessage, to client: ClientIdentity) async throws {}
    func sendCandidate(_ message: ICECandidateMessage) async throws {}
    func prepareSession(id: UUID, role: WebRTCSessionRole) async throws {}
    func createOffer(sessionID: UUID, qualityPreset: StreamQualityPreset, displayID: String?) async throws -> SessionOfferMessage {
        SessionOfferMessage(sessionID: sessionID, sdp: "", qualityPreset: qualityPreset)
    }
    func applyRemoteOffer(_ message: SessionOfferMessage) async throws -> SessionAnswerMessage {
        SessionAnswerMessage(sessionID: message.sessionID, sdp: "")
    }
    func applyRemoteAnswer(_ message: SessionAnswerMessage) async throws {}
    func addRemoteCandidate(_ message: ICECandidateMessage) async throws {}
    func sendInputCommand(_ message: InputCommandMessage) async throws {}
    func sendDataMessage(_ message: DataChannelEnvelope) throws {}
    func configureControlChannelAuth(sessionTokenHex: String?) {}
    func receiveDataMessages() -> AsyncStream<DataChannelEnvelope> {
        AsyncStream { $0.finish() }
    }
    func localICECandidates() -> AsyncStream<ICECandidateMessage> {
        AsyncStream { $0.finish() }
    }
    func attachVideoSource(_ source: (any VideoFrameSource)?) {}
    func sendVideoFrame(_ frame: VideoFrameData) throws {}
    func receivedVideoFrames() -> AsyncStream<VideoFrameData> {
        AsyncStream { $0.finish() }
    }
    var streamDiagnostics: StreamDiagnostics { StreamDiagnostics() }
    var videoFrameSubscriberCount: Int { 0 }
    func connectionStateUpdates() -> AsyncStream<ConnectionState> {
        AsyncStream { $0.yield(.idle); $0.finish() }
    }
    func dataChannelStateUpdates() -> AsyncStream<DataChannelState> {
        AsyncStream { $0.yield(.closed); $0.finish() }
    }
    func videoChannelStateUpdates() -> AsyncStream<DataChannelState> {
        AsyncStream { $0.finish() }
    }
    func closeSession() async {}
}

final class DisabledInputInjectionService: InputInjectionServiceProtocol {
    func inject(_ command: InputCommand) async throws {}
    func perform(_ shortcut: ShortcutCommand) async throws {}
}

private extension DisplayLayout {
    static var placeholder: DisplayLayout {
        let display = DisplayDescriptor(
            id: "main",
            name: "Main Display",
            frame: DesktopRect(origin: DesktopPoint(x: 0, y: 0), size: DesktopSize(width: 1440, height: 900)),
            pixelSize: DesktopSize(width: 2880, height: 1800),
            scaleFactor: 2,
            refreshRate: 60,
            isPrimary: true
        )
        return DisplayLayout(displays: [display], primaryDisplayID: display.id, virtualBounds: display.frame)
    }
}

#if os(macOS)
@MainActor
final class HostLaunchAtLoginManager {
    var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    var requiresApproval: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .requiresApproval
        }
        return false
    }

    func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw LaunchAtLoginError.unsupportedOS
        }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum LaunchAtLoginError: LocalizedError {
    case unsupportedOS

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Start at Login requires macOS 13 or newer."
        }
    }
}
#endif
