import Foundation
import Observation

/// One process-owned launch gate; every exit converges on `finish()`.
/// Timestamps are monotonic, passed explicitly so the rules can be tested without sleeping.
@MainActor
@Observable
final class VampStreamSplashLifecycle {
    enum Phase: Equatable { case pending, playing, dismissing, finished }

    static let maximumDuration: TimeInterval = 1.35
    static let dismissalDuration: TimeInterval = 0.15

    private(set) var phase: Phase = .pending
    private(set) var owner: UUID?
    private(set) var startedAt: TimeInterval?
    private(set) var dismissalStartedAt: TimeInterval?
    private(set) var deadline: TimeInterval?
    private(set) var rootIsUsable = false
    private let previewsFullSequence: Bool

    init(previewsFullSequence: Bool = false) {
        self.previewsFullSequence = previewsFullSequence
    }

    func prepare(owner: UUID) {
        guard phase == .pending, self.owner == nil else { return }
        self.owner = owner
    }

    @discardableResult
    func begin(owner: UUID, at now: TimeInterval, isActive: Bool, reduceMotion: Bool) -> Bool {
        guard phase == .pending, isActive else { return false }
        guard self.owner == nil || self.owner == owner else { return false }
        guard !rootIsUsable || previewsFullSequence else {
            finish()
            return false
        }
        self.owner = owner
        startedAt = now
        deadline = now + Self.maximumDuration
        phase = .playing
        if reduceMotion { dismiss(at: now) }
        return true
    }

    func rootBecameUsable(at now: TimeInterval) {
        rootIsUsable = true
        guard !previewsFullSequence else { return }
        switch phase {
        case .pending: finish()
        case .playing: dismiss(at: now)
        case .dismissing, .finished: break
        }
    }

    func dismiss(at now: TimeInterval) {
        guard phase == .playing, let deadline else { return }
        guard now < deadline else { finish(); return }
        dismissalStartedAt = now
        self.deadline = min(deadline, now + Self.dismissalDuration)
        phase = .dismissing
    }

    func advance(to now: TimeInterval) {
        if let deadline, now >= deadline { finish() }
    }

    func becameInactive() {
        if owner != nil { finish() }
    }

    func cancel(owner: UUID) {
        if self.owner == owner { finish() }
    }

    func isVisible(for owner: UUID) -> Bool {
        self.owner == owner && (phase == .playing || phase == .dismissing)
    }

    func coversRoot(for owner: UUID) -> Bool {
        // Match the native launch background before scene activation reaches SwiftUI.
        // Local readiness can still finish this pending cover without starting motion.
        if phase == .pending { return self.owner == nil || self.owner == owner }
        return isVisible(for: owner)
    }

    func elapsed(at now: TimeInterval) -> TimeInterval {
        // Readiness cancels the remaining choreography; only opacity changes during dismissal.
        max(0, (dismissalStartedAt ?? now) - (startedAt ?? now))
    }

    func opacity(at now: TimeInterval) -> Double {
        guard phase != .finished else { return 0 }
        guard phase == .dismissing, let dismissalStartedAt, let deadline else { return 1 }
        return min(1, max(0, (deadline - now) / max(0.0001, deadline - dismissalStartedAt)))
    }

    private func finish() {
        phase = .finished
        deadline = nil
    }
}

enum VampStreamSplashPreviewConfiguration {
    static var isEnabled: Bool {
        #if DEBUG && VAMP_STREAM_SPLASH_REFERENCE
        // A dedicated QA build can be launched by device tools without launch arguments.
        true
        #elseif DEBUG
        ProcessInfo.processInfo.arguments.contains("--vamp-stream-splash-reference")
            || Bundle.main.object(forInfoDictionaryKey: "VampStreamSplashReference") as? Bool == true
        #else
        false
        #endif
    }
}
