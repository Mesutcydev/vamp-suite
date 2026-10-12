import Foundation
import SwiftUI
import Combine
import Diagnostics
import Discovery
import Permissions
import SharedModels
import SharedProtocol
import TransportWebRTC
#if canImport(UIKit)
import UIKit
#endif
#if canImport(VideoToolbox)
import CoreMedia
import VideoToolbox
#endif

@MainActor
final class ClientAppEnvironment: ObservableObject {
    let clientIdentity: ClientIdentity
    let clientProductRole: ClientProductRole
    /// The terminal client may connect to the terminal-only host product. The
    /// remote-control client uses this to explain why that host cannot provide
    /// a screen session instead of showing a blank connection.
    let supportsTerminalOnlyHosts: Bool
    let discoveryService: any DiscoveryServiceProtocol
    let signalingService: any SessionCoordinatorSignaling
    let webRTCSessionManager: any WebRTCSessionManaging
    let eventLogStore: any EventLogStoreProtocol
    let peerConnectionProvider: LANPeerConnectionProvider
    let hostBrowser: any BonjourDiscoveryBrowsing
    let sharedHostsViewModel: HostsListViewModel
    let displayLayoutViewModel: DisplayLayoutViewModel
    let trustedPeerStore: any TrustedPeerStoreProtocol
    let sessionCoordinator: ClientSessionCoordinator
    let settingsSyncService: any ClientSettingsSyncing
    private let performancePolicyService = SessionPerformancePolicyService()
    private var cancellables = Set<AnyCancellable>()

    @Published var showsStatsOverlay: Bool {
        didSet { persistSettings() }
    }
    @Published var lowPowerModeEnabled: Bool {
        didSet { persistSettings() }
    }
    @Published var prefersViewOnly: Bool {
        didSet { persistSettings() }
    }
    @Published var preferredQualityPreset: StreamQualityPreset {
        didSet { persistSettings() }
    }

    init(
        clientIdentity: ClientIdentity,
        supportsTerminalOnlyHosts: Bool = false,
        clientProductRole: ClientProductRole = .remoteControl,
        discoveryService: any DiscoveryServiceProtocol,
        signalingService: any SessionCoordinatorSignaling,
        webRTCSessionManager: any WebRTCSessionManaging,
        eventLogStore: any EventLogStoreProtocol,
        peerConnectionProvider: LANPeerConnectionProvider,
        hostBrowser: any BonjourDiscoveryBrowsing,
        displayLayoutViewModel: DisplayLayoutViewModel,
        trustedPeerStore: any TrustedPeerStoreProtocol,
        sessionCoordinator: ClientSessionCoordinator,
        settingsSyncService: any ClientSettingsSyncing = ClientSettingsSyncService()
    ) {
        CrashSafeStartupDiagnostics.mark("environment.init.begin")
        var settings = settingsSyncService.load()
        if !settingsSyncService.hasPersistedSettings() {
            #if canImport(UIKit)
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone
            #else
            let isPhone = false
            #endif
            settings.preferredQualityPreset = Self.defaultPreferredQualityPreset(
                isPhone: isPhone,
                deviceModelIdentifier: Self.currentDeviceModelIdentifier()
            )
            settingsSyncService.save(settings)
        }
        CrashSafeStartupDiagnostics.mark("environment.settings.loaded")

        self.clientIdentity = clientIdentity
        self.clientProductRole = clientProductRole
        self.supportsTerminalOnlyHosts = supportsTerminalOnlyHosts
        self.discoveryService = discoveryService
        self.signalingService = signalingService
        self.webRTCSessionManager = webRTCSessionManager
        self.eventLogStore = eventLogStore
        self.peerConnectionProvider = peerConnectionProvider
        self.hostBrowser = hostBrowser
        self.sharedHostsViewModel = HostsListViewModel(browser: hostBrowser)
        self.displayLayoutViewModel = displayLayoutViewModel
        self.trustedPeerStore = trustedPeerStore
        self.sessionCoordinator = sessionCoordinator
        self.settingsSyncService = settingsSyncService
        _preferredQualityPreset = Published(initialValue: settings.preferredQualityPreset)
        _showsStatsOverlay = Published(initialValue: settings.showsStatsOverlay)
        _lowPowerModeEnabled = Published(initialValue: settings.lowPowerModeEnabled)
        _prefersViewOnly = Published(initialValue: settings.prefersViewOnly)

        if let bonjourSignaling = self.signalingService as? BonjourSignalingService,
           bonjourSignaling.identityService == nil {
            bonjourSignaling.identityService = CryptoIdentityService(tag: "com.mesutcy.remotedesktop.terminal.p256")
            CrashSafeStartupDiagnostics.mark("environment.identity.injected")
        }

        self.sessionCoordinator.refreshEndpoint = { [weak self] endpoint in
            self?.sharedHostsViewModel.refreshedEndpoint(matching: endpoint)
        }
        self.sessionCoordinator.candidateEndpoints = { [weak self] endpoint in
            self?.sharedHostsViewModel.candidateEndpoints(matching: endpoint) ?? []
        }
        self.sessionCoordinator.onVerifiedHostIdentity = { [weak self] endpoint, hostID, fingerprint in
            self?.sharedHostsViewModel.recordVerifiedHostIdentity(
                endpoint: endpoint,
                hostID: hostID,
                publicKeyFingerprint: fingerprint
            )
        }
        self.sessionCoordinator.trustedFingerprintProvider = { [weak self] endpoint in
            self?.sharedHostsViewModel.trustedFingerprint(matching: endpoint)
        }

        settingsSyncService.observeRemoteChanges { [weak self] settings in
            Task { @MainActor [weak self] in
                self?.applySyncedSettings(settings)
            }
        }
        CrashSafeStartupDiagnostics.mark("environment.init.end")

        #if canImport(UIKit)
        bindIdleTimerToSessionPhase()
        startForegroundReconnectObservation()
        #endif
    }

    static func makeDefault(
        clientName: String,
        supportsTerminalOnlyHosts: Bool = false,
        clientProductRole: ClientProductRole = .remoteControl
    ) -> ClientAppEnvironment {
        CrashSafeStartupDiagnostics.mark("environment.default.begin", details: clientName)
        #if canImport(UIKit)
        let currentDeviceModel = currentDeviceModelIdentifier() ?? "Apple Device"
        #else
        let currentDeviceModel = "Apple Device"
        #endif
        let cryptoIdentity = CryptoIdentityService(tag: "com.mesutcy.remotedesktop.terminal.p256")
        let client = ClientIdentity(
            // Derive a STABLE id from the (persistent Keychain) fingerprint instead of a fresh
            // random UUID per launch — otherwise the host's id-keyed trust lookup misses every
            // cold launch and trust survives only on the fingerprint fallback. Mirrors the host.
            id: ClientIdentity.stableID(publicKeyFingerprint: cryptoIdentity.fingerprint) ?? UUID(),
            displayName: clientName,
            deviceModel: currentDeviceModel,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            publicKeyFingerprint: cryptoIdentity.fingerprint
        )
        CrashSafeStartupDiagnostics.mark("environment.default.identity.ready")
        let trustedPeerStore = PersistentTrustedPeerStore()
        let browser = BonjourHostDiscoveryBrowser()
        let signalingService = BonjourSignalingService()
        signalingService.identityService = CryptoIdentityService(tag: "com.mesutcy.remotedesktop.terminal.p256")
        let peerConnectionProvider = LANPeerConnectionProvider()
        let webRTCSessionManager = WebRTCSessionManager(peerConnectionProvider: peerConnectionProvider)
        let displayLayoutViewModel = DisplayLayoutViewModel()
        let eventLogStore = InMemoryEventLogStore()
        let sessionCoordinator = ClientSessionCoordinator(
            clientIdentity: client,
            clientProductRole: clientProductRole,
            webRTCSessionManager: webRTCSessionManager,
            peerConnectionProvider: peerConnectionProvider,
            eventLogStore: eventLogStore,
            signalingService: signalingService,
            displayLayoutViewModel: displayLayoutViewModel
        )
        CrashSafeStartupDiagnostics.mark("environment.default.dependencies.ready")
        return ClientAppEnvironment(
            clientIdentity: client,
            supportsTerminalOnlyHosts: supportsTerminalOnlyHosts,
            clientProductRole: clientProductRole,
            discoveryService: browser,
            signalingService: signalingService,
            webRTCSessionManager: webRTCSessionManager,
            eventLogStore: eventLogStore,
            peerConnectionProvider: peerConnectionProvider,
            hostBrowser: browser,
            displayLayoutViewModel: displayLayoutViewModel,
            trustedPeerStore: trustedPeerStore,
            sessionCoordinator: sessionCoordinator,
            settingsSyncService: ClientSettingsSyncService()
        )
    }

    private func persistSettings() {
        let settings = SessionFeatureSettings(
            preferredQualityPreset: preferredQualityPreset,
            showsStatsOverlay: showsStatsOverlay,
            lowPowerModeEnabled: lowPowerModeEnabled,
            prefersViewOnly: prefersViewOnly
        )
        if settingsSyncService.load() != settings {
            settingsSyncService.save(settings)
        }
    }

    private func applySyncedSettings(_ settings: SessionFeatureSettings) {
        if preferredQualityPreset != settings.preferredQualityPreset {
            preferredQualityPreset = settings.preferredQualityPreset
        }
        if showsStatsOverlay != settings.showsStatsOverlay {
            showsStatsOverlay = settings.showsStatsOverlay
        }
        if lowPowerModeEnabled != settings.lowPowerModeEnabled {
            lowPowerModeEnabled = settings.lowPowerModeEnabled
        }
        if prefersViewOnly != settings.prefersViewOnly {
            prefersViewOnly = settings.prefersViewOnly
        }
    }

    var supportsUltraQualityPreset: Bool {
        #if canImport(UIKit)
        Self.supportsUltraQualityPreset(
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            deviceModelIdentifier: Self.currentDeviceModelIdentifier(),
            nativeBounds: UIScreen.main.nativeBounds.size,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
        #else
        true
        #endif
    }

    /// Ultra is available whenever the client hardware supports it.
    var isUltraQualityEntitled: Bool {
        supportsUltraQualityPreset
    }

    var ultraQualityAvailabilityMessage: String? {
        if !supportsUltraQualityPreset {
            #if os(macOS)
            return "Ultra needs a newer Mac with more HEVC decoder headroom."
            #else
            return "Ultra needs a newer high-resolution iPhone with more decoder headroom."
            #endif
        }
        return nil
    }

    var effectivePreferredQualityPreset: StreamQualityPreset {
        // `.nominal` is deliberate, not a stub: this value is the preset the
        // client *requests* at connect time, and the host owns runtime
        // adaptation — it downgrades for its own thermal and power pressure and
        // the congestion controller trims bitrate live. Feeding this device's
        // thermal state in here would cap the request permanently for the whole
        // session on the strength of one instantaneous reading.
        let resolved = performancePolicyService.profile(
            preferredPreset: preferredQualityPreset,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: .nominal
        ).effectivePreset
        if resolved == .ultra && !isUltraQualityEntitled {
            return .quality
        }
        return resolved
    }

    nonisolated static func defaultPreferredQualityPreset(
        isPhone: Bool,
        deviceModelIdentifier: String? = nil
    ) -> StreamQualityPreset {
        guard isPhone else { return .balanced }
        return supportsUltraQualityPreset(
            isPhone: isPhone,
            deviceModelIdentifier: deviceModelIdentifier,
            nativeBounds: .zero,
            physicalMemoryBytes: 0
        // Default to `.quality`, not `.ultra`, to avoid selecting the most
        // bandwidth-intensive preset on a fresh install.
        ) ? StreamQualityPreset.quality : StreamQualityPreset.balanced
    }

    nonisolated static func supportsUltraQualityPreset(
        isPhone: Bool,
        deviceModelIdentifier: String? = nil,
        nativeBounds: CGSize,
        physicalMemoryBytes: UInt64,
        hardwareHEVCDecodeSupported: Bool? = nil
    ) -> Bool {
        guard isPhone else { return true }

        // Fast path: known-capable models always qualify (covers the case where
        // live screen bounds / memory aren't available yet, e.g. default selection).
        if let identifier = normalizedUltraCapableModelIdentifier(deviceModelIdentifier),
           ultraCapablePhoneModelIdentifiers.contains(identifier) {
            return true
        }

        // Capability-based path so any sufficiently capable phone — including models
        // released after this build — qualifies without needing a model-list update.
        // (The previous model-allowlist-only check greyed out Ultra on every device
        // newer than the last one baked into the list.) Ultra streams native-resolution
        // HEVC, so we require hardware HEVC decode plus ample memory and a
        // high-resolution display for decoder/GPU headroom.
        let hasHardwareHEVCDecode: Bool = hardwareHEVCDecodeSupported ?? {
            #if canImport(VideoToolbox)
            return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
            #else
            return false
            #endif
        }()
        let longestNativeEdge = max(nativeBounds.width, nativeBounds.height)
        return hasHardwareHEVCDecode
            && physicalMemoryBytes >= 7_000_000_000   // ~8 GB+ (separates Pro/flagship from 6 GB tier)
            && longestNativeEdge >= 2400               // high-resolution display
    }

    nonisolated static func currentDeviceModelIdentifier() -> String? {
        #if targetEnvironment(simulator)
        if let simulatedIdentifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return normalizedUltraCapableModelIdentifier(simulatedIdentifier)
        }
        #endif

        var systemInfo = utsname()
        uname(&systemInfo)
        var machine = systemInfo.machine
        let machineSize = MemoryLayout.size(ofValue: machine)
        let identifier = withUnsafePointer(to: &machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: machineSize) {
                String(cString: $0)
            }
        }
        return normalizedUltraCapableModelIdentifier(identifier)
    }

    nonisolated static func normalizedUltraCapableModelIdentifier(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    // Fast-path allowlist of known ultra-capable phones. Devices newer than these
    // are handled by the capability-based path in `supportsUltraQualityPreset`, so
    // this list never needs to be exhaustive — it just optimizes default selection.
    private nonisolated static let ultraCapablePhoneModelIdentifiers: Set<String> = [
        "iphone16,1", // iPhone 15 Pro
        "iphone16,2", // iPhone 15 Pro Max
        "iphone17,1", // iPhone 16 Pro
        "iphone17,2", // iPhone 16 Pro Max
        "iphone18,1", // iPhone 17 family (A19, 8 GB+)
        "iphone18,2",
        "iphone18,3",
        "iphone18,4"
    ]

    // MARK: - Idle Timer / Screen Sleep

    #if canImport(UIKit)
    private func bindIdleTimerToSessionPhase() {
        sessionCoordinator.$phase
            .receive(on: DispatchQueue.main)
            .sink { phase in
                UIApplication.shared.isIdleTimerDisabled = (phase == .receiving)
            }
            .store(in: &cancellables)
    }

    private func startForegroundReconnectObservation() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Any in-flight session must be torn down cleanly: iOS kills the
                // sockets seconds after backgrounding, and a session left in a
                // mid-handshake phase (.connecting/.negotiating/.waitingForMedia)
                // comes back to the foreground stuck — connect() refuses to run
                // unless phase is .idle or .error.
                switch self.sessionCoordinator.phase {
                case .idle, .error:
                    return
                case .connecting, .signalingConnected, .negotiating, .waitingForMedia, .receiving:
                    Task { await self.sessionCoordinator.disconnect() }
                }
            }
            .store(in: &cancellables)
    }
    #endif

}

final class PlaceholderClientServices:
    DiscoveryServiceProtocol,
    SignalingServiceProtocol,
    WebRTCSessionManaging,
    EventLogStoreProtocol,
    TrustedPeerStoreProtocol
{
    func dataChannelStateUpdates() -> AsyncStream<TransportWebRTC.DataChannelState> {
        AsyncStream { continuation in
            continuation.yield(.closed)
            continuation.finish()
        }
    }
    func videoChannelStateUpdates() -> AsyncStream<TransportWebRTC.DataChannelState> {
        AsyncStream { $0.finish() }
    }

    var connectionState: ConnectionState { .idle }
    var peerConnectionState: PeerConnectionState { .closed }
    var dataChannelState: DataChannelState { .closed }
    var mediaChannelReadiness: MediaChannelReadiness { MediaChannelReadiness() }

    func startBrowsing() async throws {}
    func stopBrowsing() async {}
    func discoveredHosts() async -> [HostIdentity] { [] }
    func resolvedHostEndpoints() async -> [ResolvedHostEndpoint] { [] }
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
    func closeSession() async {}
    func append(_ item: EventLogItem) async {}
    func recentItems(limit: Int) async -> [EventLogItem] { [] }
    func removeAll() async {}
    func trustedPeers() async throws -> [TrustedPeer] { [] }
    func trustPeer(_ peer: TrustedPeer) async throws {}
    func revokePeer(id: UUID) async throws {}
}
