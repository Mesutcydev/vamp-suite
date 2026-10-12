import Foundation

public enum EventSeverity: String, Codable, Hashable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct EventLogItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var timestamp: Date
    public var severity: EventSeverity
    public var category: String
    public var message: String
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        severity: EventSeverity,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}
