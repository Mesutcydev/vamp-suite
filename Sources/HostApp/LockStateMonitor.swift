#if os(macOS)
import Combine
import CoreGraphics
import Foundation
import SharedModels
import os

/// Monitors the macOS screen-lock state and publishes changes as `HostLockState`.
///
/// Detection strategy (no security bypass, read-only queries only):
/// 1. `DistributedNotificationCenter` — system posts `com.apple.screenIsLocked` /
///    `com.apple.screenIsUnlocked` whenever the lock screen appears or disappears.
///    These notifications are available to sandboxed builds.
/// 2. `CGSessionCopyCurrentDictionary()` — used for the initial snapshot and as a
///    ground-truth confirmation after each notification.  The `CGSSessionScreenIsLocked`
///    key is set by WindowServer and is readable without special entitlements.
///
/// The monitor does NOT:
/// - Attempt to unlock or bypass the lock screen
/// - Inject any credentials or keystrokes into password fields
/// - Log typed text or any sensitive session content
@MainActor
final class LockStateMonitor: ObservableObject {

    @Published private(set) var lockState: HostLockState = .unlockedActiveSession

    /// Thread-safe accessor for non-MainActor callers (e.g. the input router task).
    nonisolated var currentLockState: HostLockState {
        _stateLock.lock()
        defer { _stateLock.unlock() }
        return _cachedState
    }

    private nonisolated(unsafe) var _cachedState: HostLockState = .unlockedActiveSession
    private let _stateLock = NSLock()
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "LockStateMonitor")

    // MARK: - Lifecycle

    func startMonitoring() {
        // Snapshot current state before registering notifications so we handle
        // the case where the host was already locked when the app launched.
        refresh()

        let dnc = DistributedNotificationCenter.default()

        lockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenLocked()
            }
        }

        unlockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenUnlocked()
            }
        }

        logger.info("LockStateMonitor started — initial state: \(self.lockState.statusLabel, privacy: .public)")
    }

    func stopMonitoring() {
        let dnc = DistributedNotificationCenter.default()
        if let obs = lockObserver   { dnc.removeObserver(obs) }
        if let obs = unlockObserver { dnc.removeObserver(obs) }
        lockObserver   = nil
        unlockObserver = nil
        logger.info("LockStateMonitor stopped")
    }

    // MARK: - Event Handlers

    private func handleScreenLocked() {
        // Always confirm with CGSession to avoid false positives from third-party
        // apps that happen to post similarly-named notifications.
        let confirmed = cgSessionIsLocked()
        let newState: HostLockState = confirmed ? .lockedOrLoginWindow : .unlockedActiveSession
        apply(newState)
        logger.info("Screen locked notification — CGSession confirmed=\(confirmed, privacy: .public)")
    }

    private func handleScreenUnlocked() {
        apply(.unlockedActiveSession)
        logger.info("Screen unlocked notification")
    }

    // MARK: - Helpers

    /// Reads `CGSSessionScreenIsLocked` from the current CGSession dictionary.
    /// Returns false if the session dict is unavailable (treated as unlocked).
    private func cgSessionIsLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return dict["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Re-reads the CGSession state and applies it without waiting for a notification.
    /// Called at startup and can be called externally to force a refresh.
    func refresh() {
        let newState: HostLockState = cgSessionIsLocked() ? .lockedOrLoginWindow : .unlockedActiveSession
        apply(newState)
    }

    private func apply(_ newState: HostLockState) {
        _stateLock.lock()
        _cachedState = newState
        _stateLock.unlock()
        if lockState != newState {
            lockState = newState
        }
    }
}
#endif
