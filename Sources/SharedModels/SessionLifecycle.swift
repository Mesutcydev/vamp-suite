import Foundation

public enum RemoteDesktopRole: String, Codable, Hashable, Sendable {
    case host
    case client
}

public enum SessionLifecycleState: String, CaseIterable, Codable, Hashable, Sendable {
    case idle
    case discovering
    case connecting
    case signaling
    case awaitingPermissions
    case readyForMedia
    case streaming
    case controlling
    case reconnecting
    case disconnected
    case failed
}

public enum SessionLifecycleEvent: String, Codable, Hashable, Sendable {
    case discoveryStarted
    case hostSelected
    case signalingStarted
    case permissionsRequired
    case permissionsSatisfied
    case sessionReady
    case mediaStarted
    case controlStarted
    case controlEnded
    case reconnectRequested
    case reconnectSucceeded
    case disconnected
    case failed
    case reset
}

public struct InvalidSessionTransition: Error, Equatable, Sendable {
    public var from: SessionLifecycleState
    public var event: SessionLifecycleEvent

    public init(from: SessionLifecycleState, event: SessionLifecycleEvent) {
        self.from = from
        self.event = event
    }
}

public struct SessionStateMachine: Hashable, Sendable {
    public private(set) var state: SessionLifecycleState

    public init(initialState: SessionLifecycleState = .idle) {
        self.state = initialState
    }

    public mutating func apply(_ event: SessionLifecycleEvent) throws {
        state = try Self.nextState(from: state, event: event)
    }

    public static func nextState(
        from state: SessionLifecycleState,
        event: SessionLifecycleEvent
    ) throws -> SessionLifecycleState {
        if event == .failed {
            return .failed
        }

        if event == .reset {
            return .idle
        }

        if event == .disconnected {
            return .disconnected
        }

        switch (state, event) {
        case (.idle, .discoveryStarted):
            return .discovering
        case (.idle, .hostSelected):
            return .connecting
        case (.discovering, .hostSelected):
            return .connecting
        case (.connecting, .signalingStarted):
            return .signaling
        case (.signaling, .permissionsRequired):
            return .awaitingPermissions
        case (.signaling, .sessionReady):
            return .readyForMedia
        case (.awaitingPermissions, .permissionsSatisfied):
            return .readyForMedia
        case (.readyForMedia, .mediaStarted):
            return .streaming
        case (.streaming, .controlStarted):
            return .controlling
        case (.controlling, .controlEnded):
            return .streaming
        case (.readyForMedia, .reconnectRequested),
             (.streaming, .reconnectRequested),
             (.controlling, .reconnectRequested):
            return .reconnecting
        case (.reconnecting, .signalingStarted):
            return .signaling
        case (.reconnecting, .reconnectSucceeded):
            return .readyForMedia
        case (.disconnected, .discoveryStarted):
            return .discovering
        default:
            throw InvalidSessionTransition(from: state, event: event)
        }
    }
}
