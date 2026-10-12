#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation

@available(iOS 16.1, *)
public struct RemoteSessionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var hostDisplayName: String
        public var qualitySummary: String
        public var startedAt: Date
        public var isReconnecting: Bool

        public init(
            hostDisplayName: String,
            qualitySummary: String,
            startedAt: Date,
            isReconnecting: Bool
        ) {
            self.hostDisplayName = hostDisplayName
            self.qualitySummary = qualitySummary
            self.startedAt = startedAt
            self.isReconnecting = isReconnecting
        }
    }

    public var sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}
#endif
