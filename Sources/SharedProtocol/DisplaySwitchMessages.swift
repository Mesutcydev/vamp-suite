import Foundation

public enum DisplaySwitchStatus: String, Codable, Hashable, Sendable {
    case accepted
    case completed
    case rejected
    case failed
}

public struct DisplaySwitchRequestMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var targetDisplayID: String
    public var senderDeviceID: UUID
    public var requestedAt: Date

    public init(
        sessionID: UUID,
        targetDisplayID: String,
        senderDeviceID: UUID,
        requestedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.targetDisplayID = targetDisplayID
        self.senderDeviceID = senderDeviceID
        self.requestedAt = requestedAt
    }
}

public struct DisplaySwitchResultMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var selectedDisplayID: String
    public var senderDeviceID: UUID
    public var status: DisplaySwitchStatus
    public var reason: String?
    public var startedAt: Date
    public var completedAt: Date

    public init(
        sessionID: UUID,
        selectedDisplayID: String,
        senderDeviceID: UUID,
        status: DisplaySwitchStatus,
        reason: String? = nil,
        startedAt: Date,
        completedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.selectedDisplayID = selectedDisplayID
        self.senderDeviceID = senderDeviceID
        self.status = status
        self.reason = reason
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}
