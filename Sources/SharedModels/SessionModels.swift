import Foundation

public enum StreamQualityPreset: String, CaseIterable, Codable, Hashable, Sendable {
    case performance
    case balanced
    case quality
    case ultra
}

public enum ConnectionState: String, Codable, Hashable, Sendable {
    case idle
    case discovering
    case signaling
    case connecting
    case connected
    case reconnecting
    case disconnected
    case failed
}

public struct SessionState: Codable, Hashable, Sendable {
    public var id: UUID
    public var hostID: UUID
    public var clientID: UUID?
    public var connectionState: ConnectionState
    public var selectedDisplayID: String?
    public var qualityPreset: StreamQualityPreset
    public var startedAt: Date?
    public var endedAt: Date?

    public init(
        id: UUID = UUID(),
        hostID: UUID,
        clientID: UUID? = nil,
        connectionState: ConnectionState = .idle,
        selectedDisplayID: String? = nil,
        qualityPreset: StreamQualityPreset = .balanced,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.clientID = clientID
        self.connectionState = connectionState
        self.selectedDisplayID = selectedDisplayID
        self.qualityPreset = qualityPreset
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public enum PermissionAuthorizationState: String, Codable, Hashable, Sendable {
    case unknown
    case notDetermined
    case denied
    case granted
    case restricted
}

public enum PermissionKind: String, CaseIterable, Codable, Hashable, Sendable {
    case screenRecording
    case accessibility
    case localNetwork
    case microphone
}

public struct PermissionState: Codable, Hashable, Sendable {
    public var kind: PermissionKind
    public var authorizationState: PermissionAuthorizationState
    public var lastCheckedAt: Date?

    public init(
        kind: PermissionKind,
        authorizationState: PermissionAuthorizationState,
        lastCheckedAt: Date? = nil
    ) {
        self.kind = kind
        self.authorizationState = authorizationState
        self.lastCheckedAt = lastCheckedAt
    }
}
