import Foundation
import SharedModels

#if canImport(AppIntents) && os(iOS)
import AppIntents
#endif

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

@available(iOS 16.1, *)
@MainActor
final class LiveActivityService {
    private var activeSessionID: UUID?
    private var activity: Activity<RemoteSessionActivityAttributes>?

    func start(sessionID: UUID, hostDisplayName: String, quality: NetworkQuality, startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        cleanupStaleActivities(keeping: sessionID)

        if let existing = existingActivity(for: sessionID) {
            activity = existing
            activeSessionID = sessionID
            update(
                hostDisplayName: hostDisplayName,
                quality: quality,
                startedAt: startedAt,
                isReconnecting: false
            )
            return
        }

        let attributes = RemoteSessionActivityAttributes(sessionID: sessionID.uuidString)
        let state = RemoteSessionActivityAttributes.ContentState(
            hostDisplayName: hostDisplayName,
            qualitySummary: quality.summaryText,
            startedAt: startedAt,
            isReconnecting: false
        )
        if #available(iOS 16.2, *) {
            let content = ActivityContent(state: state, staleDate: nil)
            activity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
        } else {
            activity = try? Activity.request(attributes: attributes, contentState: state, pushType: nil)
        }
        activeSessionID = sessionID
    }

    func update(
        hostDisplayName: String,
        quality: NetworkQuality,
        startedAt: Date,
        isReconnecting: Bool
    ) {
        guard let activity else { return }
        let state = RemoteSessionActivityAttributes.ContentState(
            hostDisplayName: hostDisplayName,
            qualitySummary: quality.summaryText,
            startedAt: startedAt,
            isReconnecting: isReconnecting
        )
        Task {
            if #available(iOS 16.2, *) {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            } else {
                await activity.update(using: state)
            }
        }
    }

    func end() {
        let currentSessionID = activeSessionID?.uuidString
        let trackedActivity = activity
        self.activity = nil
        self.activeSessionID = nil

        Task {
            if let trackedActivity {
                await Self.endActivity(trackedActivity)
            }

            guard let currentSessionID else { return }
            for existing in Activity<RemoteSessionActivityAttributes>.activities where existing.attributes.sessionID == currentSessionID {
                await Self.endActivity(existing)
            }
        }
    }

    private func existingActivity(for sessionID: UUID) -> Activity<RemoteSessionActivityAttributes>? {
        return Activity<RemoteSessionActivityAttributes>.activities.first {
            $0.attributes.sessionID == sessionID.uuidString
        }
    }

    private func cleanupStaleActivities(keeping sessionID: UUID) {
        let keepID = sessionID.uuidString
        let activities = Activity<RemoteSessionActivityAttributes>.activities
        let matchingActivities = activities.filter { $0.attributes.sessionID == keepID }

        Task {
            for activity in activities where activity.attributes.sessionID != keepID {
                await Self.endActivity(activity)
            }

            for duplicate in matchingActivities.dropFirst() {
                await Self.endActivity(duplicate)
            }
        }
    }

    /// Centralised availability split so the deprecated `end(dismissalPolicy:)`
    /// is only reached on iOS 16.1, while 16.2+ uses the new
    /// `end(_:dismissalPolicy:)` API.  Keeping both paths in one helper avoids
    /// the repeated `#available` blocks at every callsite.
    private static func endActivity(_ activity: Activity<RemoteSessionActivityAttributes>) async {
        if #available(iOS 16.2, *) {
            await activity.end(nil, dismissalPolicy: .immediate)
        } else {
            await activity.end(dismissalPolicy: .immediate)
        }
    }
}
#else
@MainActor
final class LiveActivityService {
    func start(sessionID: UUID, hostDisplayName: String, quality: NetworkQuality, startedAt: Date) {}
    func update(hostDisplayName: String, quality: NetworkQuality, startedAt: Date, isReconnecting: Bool) {}
    func end() {}
}
#endif
