import Foundation
import SharedModels

public struct FriendlyPermissionStatus: Identifiable, Hashable, Sendable {
    public var id: PermissionKind { kind }
    public var kind: PermissionKind
    public var title: String
    public var summary: String
    public var helperText: String
    public var authorizationState: PermissionAuthorizationState
    public var isRequired: Bool
    public var settingsButtonTitle: String

    public init(
        kind: PermissionKind,
        title: String,
        summary: String,
        helperText: String,
        authorizationState: PermissionAuthorizationState,
        isRequired: Bool,
        settingsButtonTitle: String
    ) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.helperText = helperText
        self.authorizationState = authorizationState
        self.isRequired = isRequired
        self.settingsButtonTitle = settingsButtonTitle
    }

    public var isGranted: Bool {
        authorizationState == .granted
    }
}

public protocol PermissionServiceProtocol {
    func currentStates() async -> [PermissionState]
    func refreshState(for kind: PermissionKind) async -> PermissionState
    func requestPermission(for kind: PermissionKind) async throws -> PermissionState
    func friendlyStatuses() async -> [FriendlyPermissionStatus]
    func openSettings(for kind: PermissionKind) async throws
}

public extension PermissionServiceProtocol {
    func friendlyStatuses() async -> [FriendlyPermissionStatus] {
        await currentStates().map { state in
            FriendlyPermissionStatus(
                kind: state.kind,
                title: state.kind.defaultTitle,
                summary: state.authorizationState.defaultSummary,
                helperText: state.kind.defaultHelperText,
                authorizationState: state.authorizationState,
                isRequired: true,
                settingsButtonTitle: "Open Settings"
            )
        }
    }

    func openSettings(for kind: PermissionKind) async throws {}
}

public protocol TrustedPeerStoreProtocol {
    func trustedPeers() async throws -> [TrustedPeer]
    func trustPeer(_ peer: TrustedPeer) async throws
    func revokePeer(id: UUID) async throws
}

private extension PermissionKind {
    var defaultTitle: String {
        switch self {
        case .screenRecording:
            return "Screen Recording"
        case .accessibility:
            return "Accessibility"
        case .localNetwork:
            return "Local Network"
        case .microphone:
            return "Microphone"
        }
    }

    var defaultHelperText: String {
        switch self {
        case .screenRecording:
            return "Allows the host to capture the display for streaming."
        case .accessibility:
            return "Allows the host to inject keyboard and pointer input."
        case .localNetwork:
            return "Allows clients to discover this Mac on the LAN."
        case .microphone:
            return "Reserved for future audio features."
        }
    }
}

private extension PermissionAuthorizationState {
    var defaultSummary: String {
        switch self {
        case .unknown:
            return "Needs checking"
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Blocked"
        case .granted:
            return "Ready"
        case .restricted:
            return "Restricted"
        }
    }
}
