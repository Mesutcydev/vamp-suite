import Foundation
import SharedModels

public struct DisplayConfigurationChangedMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var configuration: DisplayStreamConfiguration
    public var layout: DisplayLayout?
    public var reason: String?
    public var changedAt: Date

    public init(
        sessionID: UUID,
        configuration: DisplayStreamConfiguration,
        layout: DisplayLayout? = nil,
        reason: String? = nil,
        changedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.configuration = configuration
        self.layout = layout
        self.reason = reason
        self.changedAt = changedAt
    }
}
