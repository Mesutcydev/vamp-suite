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
    private(set) var lastSelectedDisplayID: String?
    private(set) var lastHostName: String?

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

    func recordSessionState(displayID: String?, hostName: String?) {
        lastSelectedDisplayID = displayID
        lastHostName = hostName
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

    func performReconnect(attempt: Int) async throws {
        guard let coord = await MainActor.run(body: { coordinator }) else {
            throw ReconnectError.coordinatorDeallocated
        }
        if let performReconnect = await MainActor.run(body: { coord.onPerformReconnect }) {
            try await performReconnect()
            return
        }

        // Reconnect goes only through the session coordinator's connect flow, which
        // authenticates the host and seals a fresh token. Without one attached there is
        // nothing safe to recover with: an offer is never rebuilt here with a kept token.
        throw ReconnectError.noSessionToRecover
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
