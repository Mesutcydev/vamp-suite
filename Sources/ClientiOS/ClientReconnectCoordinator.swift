import Discovery
import Foundation
import SharedModels
import SharedProtocol
import SharedUtilities
import TransportWebRTC
import os

/// Client-side reconnect coordinator. Monitors connection state changes,
/// triggers reconnect via `ReconnectManager`, and restores session state
/// (selected display, interaction mode) on success.
@MainActor
final class ClientReconnectCoordinator: ObservableObject {

    @Published var reconnectStatus: ReconnectStatus
    @Published var isReconnecting: Bool = false
    @Published var blockedPermissions: [PermissionState]?

    /// Callback invoked when signaling is about to be rebuilt during reconnect.
    var onRebuildSignaling: ((UUID, StreamQualityPreset) -> Void)?
    var onPerformReconnect: (() async throws -> Void)?

    let reconnectManager: ReconnectManager
    let clientProductRole: ClientProductRole
    /// Must match the value `ClientSessionCoordinator` sends on the initial
    /// offer. A reconnect that drops it renegotiates the same Mac as a non-Mac
    /// client and silently loses the Mac-client capability for the rest of the
    /// session.
    let isMacClient: Bool

    private let _webRTCSessionManager: any WebRTCSessionManaging
    private let _signalingService: any SessionCoordinatorSignaling
    private let displayLayoutViewModel: DisplayLayoutViewModel
    fileprivate let logger = Logger(subsystem: "com.mesutcy.remotedesktop.terminal", category: "Reconnect")
    private var connectionObserverTask: Task<Void, Never>?
    private var dataChannelObserverTask: Task<Void, Never>?
    private var hasSeenConnectedState = false

    /// Internal accessors for the delegate to use.
    var sessionManager: any WebRTCSessionManaging { _webRTCSessionManager }
    var signalingService: any SessionCoordinatorSignaling { _signalingService }

    /// Preserved session state for recovery.
    private(set) var lastSessionID: UUID?
    private(set) var lastSelectedDisplayID: String?
    private(set) var lastHostName: String?
    private(set) var lastHostAddress: String?
    private(set) var lastSignalingPort: UInt16?
    private(set) var lastHostFingerprint: String?
    private(set) var lastQualityPreset: StreamQualityPreset = .balanced
    private(set) var lastSessionTokenHex: String?

    init(
        webRTCSessionManager: any WebRTCSessionManaging,
        signalingService: any SessionCoordinatorSignaling,
        displayLayoutViewModel: DisplayLayoutViewModel,
        clientProductRole: ClientProductRole = .remoteControl,
        isMacClient: Bool = false,
        backoffConfiguration: ReconnectBackoff.Configuration = ReconnectBackoff.Configuration()
    ) {
        self._webRTCSessionManager = webRTCSessionManager
        self._signalingService = signalingService
        self.displayLayoutViewModel = displayLayoutViewModel
        self.clientProductRole = clientProductRole
        self.isMacClient = isMacClient
        self.reconnectManager = ReconnectManager(configuration: backoffConfiguration)
        self.reconnectStatus = ReconnectStatus(maxAttempts: backoffConfiguration.maxAttempts)

        reconnectManager.setDelegate(ClientReconnectDelegate(coordinator: self))
    }

    // MARK: - Session State Preservation

    func recordSessionState(sessionID: UUID, displayID: String?, hostName: String?, qualityPreset: StreamQualityPreset, sessionTokenHex: String?) {
        lastSessionID = sessionID
        lastSelectedDisplayID = displayID
        lastHostName = hostName
        lastQualityPreset = qualityPreset
        lastSessionTokenHex = sessionTokenHex
    }

    func recordConnectionEndpoint(hostAddress: String?, signalingPort: UInt16?, hostFingerprint: String?) {
        lastHostAddress = hostAddress
        lastSignalingPort = signalingPort
        lastHostFingerprint = hostFingerprint
    }

    // MARK: - Observation

    func startObserving() {
        stopObserving()
        hasSeenConnectedState = false
        connectionObserverTask = Task { [weak self] in
            guard let self else { return }
            for await state in self._webRTCSessionManager.connectionStateUpdates() {
                self.handleConnectionState(state)
            }
        }

        dataChannelObserverTask = Task { [weak self] in
            guard let self else { return }
            for await envelope in self._webRTCSessionManager.receiveDataMessages() {
                self.handleDataChannelMessage(envelope)
            }
        }
    }

    func stopObserving() {
        connectionObserverTask?.cancel()
        connectionObserverTask = nil
        dataChannelObserverTask?.cancel()
        dataChannelObserverTask = nil
        hasSeenConnectedState = false
        // A reconnect loop must never outlive the session UI that supplied its
        // callbacks. Otherwise it can race a later manual Connect and tear down
        // the new session with stale recovery work.
        reconnectManager.reset()
        isReconnecting = false
        updateStatus()
    }

    // MARK: - State Handling

    private func handleConnectionState(_ state: ConnectionState) {
        switch state {
        case .connected:
            hasSeenConnectedState = true
            reconnectManager.connectionRestored()
            isReconnecting = false
            blockedPermissions = nil
        case .disconnected, .failed:
            if hasSeenConnectedState, reconnectStatus.phase == .connected {
                isReconnecting = true
                reconnectManager.connectionLost(
                    reason: state == .failed ? "Connection failed" : "Disconnected",
                    hostName: lastHostName
                )
            }
        case .reconnecting:
            isReconnecting = true
        default:
            break
        }
        updateStatus()
    }

    private func handleDataChannelMessage(_ envelope: DataChannelEnvelope) {
        switch envelope.kind {
        case .displayLayout:
            if let layoutMsg = try? envelope.decodeDisplayLayout() {
                displayLayoutViewModel.update(layout: layoutMsg.layout)
                // Restore selected display if possible
                if let lastID = lastSelectedDisplayID,
                   layoutMsg.layout.display(withID: lastID) != nil {
                    displayLayoutViewModel.selectDisplay(id: lastID)
                }
            }
        case .hostStatus:
            if let statusMsg = try? envelope.decodeHostStatus() {
                if let layout = statusMsg.displayLayout {
                    displayLayoutViewModel.update(layout: layout)
                }
                displayLayoutViewModel.markHostSelectedDisplay(id: statusMsg.selectedDisplayID)
            }
        case .error:
            if let errorMsg = try? envelope.decodeError() {
                if errorMsg.code == "permission_blocked" {
                    // Parse blocked permissions from context — show blocked state
                    blockedPermissions = [] // Simplified; real parsing would come from a dedicated message
                }
            }
        default:
            break
        }
    }

    // MARK: - User Actions

    /// Called by the view layer when the session should be fully torn down
    /// (e.g. host app quit). Wired up in RemoteDesktopView.
    var onRequestSessionDisconnect: (() -> Void)?

    func retryNow() {
        reconnectManager.reset()
        reconnectManager.connectionLost(reason: "Manual retry", hostName: lastHostName)
    }

    func cancelReconnect() {
        reconnectManager.cancel()
        isReconnecting = false
        updateStatus()
        onRequestSessionDisconnect?()
    }

    private func updateStatus() {
        reconnectStatus = reconnectManager.status
    }
}

// MARK: - Reconnect Delegate

private final class ClientReconnectDelegate: ReconnectDelegate, @unchecked Sendable {
    private weak var coordinator: ClientReconnectCoordinator?

    init(coordinator: ClientReconnectCoordinator) {
        self.coordinator = coordinator
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

    func performReconnect(attempt: Int) async throws {
        guard let coord = await MainActor.run(body: { coordinator }) else {
            throw ReconnectError.coordinatorDeallocated
        }
        if let performReconnect = await MainActor.run(body: { coord.onPerformReconnect }) {
            try await performReconnect()
            return
        }

        let preservedSessionID = await MainActor.run { coord.lastSessionID }
        let sessionID = preservedSessionID ?? UUID()

        let manager = await MainActor.run { coord.sessionManager }
        let sigService = await MainActor.run { coord.signalingService }
        let qualityPreset = await MainActor.run { coord.lastQualityPreset }
        let sessionTokenHex = await MainActor.run { coord.lastSessionTokenHex }
        let displayID = await MainActor.run { coord.lastSelectedDisplayID }
        let hostName = await MainActor.run { coord.lastHostName }
        let hostAddress = await MainActor.run { coord.lastHostAddress }
        let signalingPort = await MainActor.run { coord.lastSignalingPort }
        let hostFingerprint = await MainActor.run { coord.lastHostFingerprint }
        let clientProductRole = await MainActor.run { coord.clientProductRole }
        let isMacClient = await MainActor.run { coord.isMacClient }

        // Rebuild signaling first so reconnect does not depend on a stale TCP socket.
        guard let hostAddress, !hostAddress.isEmpty, let signalingPort, signalingPort > 0 else {
            throw ReconnectError.noSessionToRecover
        }
        let target = normalizedHostAndPort(host: hostAddress, fallbackPort: signalingPort)
        sigService.disconnect()
        try await withTimeout(seconds: RemoteDesktopConstants.signalingConnectTimeout) {
            try await sigService.connect(host: target.host, port: target.port)
        }

        await MainActor.run {
            coord.onRebuildSignaling?(sessionID, qualityPreset)
        }

        // Close existing session and prepare a fresh one.
        await manager.closeSession()
        try await manager.prepareSession(id: sessionID, role: .client)

        var offer = try await manager.createOffer(
            sessionID: sessionID,
            qualityPreset: qualityPreset,
            displayID: displayID
        )
        let effectiveToken = sessionTokenHex ?? ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        offer.sessionToken = effectiveToken
        offer.clientCapabilities = .currentClient(isMacClient: isMacClient)
        offer.clientProductRole = clientProductRole
        // Reconnect must preserve the normal SDR default. HDR is an explicit
        // session choice, not an implicit side effect of the Ultra preset.
        offer.preferredDynamicRange = ClientVideoDynamicRangePolicy.preferredDynamicRange(
            qualityPreset: qualityPreset,
            clientCapabilities: offer.clientCapabilities,
            hdrExplicitlyEnabled: false
        )
        manager.configureControlChannelAuth(sessionTokenHex: effectiveToken)

        // Send the offer to the host via signaling.
        try await sigService.sendOffer(offer, to: HostIdentity(
            displayName: hostName ?? "Host",
            modelName: "Mac",
            osVersion: "",
            appVersion: "",
            publicKeyFingerprint: hostFingerprint ?? ""
        ))

        await MainActor.run {
            coord.logger.info("Stream request sent during reconnect")
        }

        // Only mark reconnect as successful once transport is truly connected.
        try await withTimeout(seconds: RemoteDesktopConstants.negotiationTimeout) {
            for await state in manager.connectionStateUpdates() {
                if state == .connected {
                    await MainActor.run {
                        coord.logger.info("Stream socket connected after reconnect")
                    }
                    return
                }
                if state == .failed {
                    throw ReconnectError.connectionFailed
                }
            }
            throw ReconnectError.connectionDidNotRecover
        }
    }

    func reconnectDidSucceed() async {
        await MainActor.run {
            coordinator?.isReconnecting = false
            coordinator?.blockedPermissions = nil
        }
    }

    func reconnectDidGiveUp(after attempts: Int) async {
        await MainActor.run {
            coordinator?.isReconnecting = false
            coordinator?.onRequestSessionDisconnect?()
        }
    }

    func reconnectPhaseDidChange(_ phase: ReconnectPhase, attempt: Int) async {
        await MainActor.run {
            coordinator?.reconnectStatus = coordinator?.reconnectManager.status ?? ReconnectStatus()
        }
    }
}

enum ReconnectError: Error, LocalizedError {
    case coordinatorDeallocated
    case noSessionToRecover
    case connectionFailed
    case connectionDidNotRecover

    var errorDescription: String? {
        switch self {
        case .coordinatorDeallocated: return "Reconnect coordinator was deallocated"
        case .noSessionToRecover: return "No previous session to recover"
        case .connectionFailed: return "Reconnect failed while establishing peer connection"
        case .connectionDidNotRecover: return "Reconnect timed out before transport became connected"
        }
    }
}
