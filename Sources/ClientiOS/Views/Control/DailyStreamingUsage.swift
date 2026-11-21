import Foundation

/// The free streaming allowance: 15 minutes per local calendar day. Pro removes the cap
/// (see `StreamingUnlockStore`). Usage is kept on this device only.
@MainActor
final class DailyStreamingUsage: ObservableObject {
    static let dailyLimitSeconds: TimeInterval = 15 * 60
    /// Recheck while a session is live so the cap can end it mid-stream.
    private static let tickInterval: TimeInterval = 10

    private static let dayKey = "vamp.usage.day"
    private static let secondsKey = "vamp.usage.seconds"

    /// Seconds used today, including the live session when one is running. Observers end the session at the cap.
    @Published private(set) var secondsUsedToday: TimeInterval = 0

    private let defaults: UserDefaults
    private var storedSeconds: TimeInterval = 0
    private var sessionStart: Date?
    private var timer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rollOverIfNeeded()
        storedSeconds = defaults.double(forKey: Self.secondsKey)
        refresh()
    }

    var hasTimeRemaining: Bool { secondsUsedToday < Self.dailyLimitSeconds }

    func startSession() {
        guard sessionStart == nil else { return }
        rollOverIfNeeded()
        sessionStart = Date()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refresh()
    }

    func stopSession() {
        guard let start = sessionStart else { return }
        storedSeconds += Date().timeIntervalSince(start)
        sessionStart = nil
        timer?.invalidate()
        timer = nil
        persist()
        refresh()
    }

    private func tick() {
        refresh()
    }

    private func refresh() {
        let live = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        secondsUsedToday = storedSeconds + live
    }

    private func persist() {
        defaults.set(storedSeconds, forKey: Self.secondsKey)
        defaults.set(Self.dayStamp(Date()), forKey: Self.dayKey)
    }

    /// The allowance resets at local midnight. A stored total from an earlier day is discarded.
    private func rollOverIfNeeded() {
        let today = Self.dayStamp(Date())
        guard defaults.string(forKey: Self.dayKey) != today else { return }
        storedSeconds = 0
        defaults.set(0, forKey: Self.secondsKey)
        defaults.set(today, forKey: Self.dayKey)
    }

    private static func dayStamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
