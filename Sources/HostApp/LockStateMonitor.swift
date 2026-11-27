#if os(macOS)
import Combine
import CoreGraphics
import Foundation
import SharedModels
import os
#if VAMP_APP_STORE
import AppKit
#endif

/// Public session/display signals are availability signals, not proof that a
/// lock screen has authenticated a user. Unknown snapshots remain unavailable.
/// Store input is independently disabled by MacHostRuntimePolicy in every state;
/// ScreenCaptureKit remains responsible for delivering permitted capture frames.
struct StoreHostSessionAvailability {
    enum Event: Sendable {
        case sessionInactive, sessionActive, screensSleep, screensWake, systemSleep, systemWake
    }

    private(set) var sessionSwitchedOut = false
    private(set) var screensAsleep = false
    private(set) var systemAsleep = false

    mutating func handle(_ event: Event) {
        switch event {
        case .sessionInactive: sessionSwitchedOut = true
        case .sessionActive: sessionSwitchedOut = false
        case .screensSleep: screensAsleep = true
        case .screensWake: screensAsleep = false
        case .systemSleep: systemAsleep = true
        case .systemWake: systemAsleep = false
        }
    }

    func state(isOnConsole: Bool?, loginDone: Bool?, displayAwake: Bool) -> HostLockState {
        guard isOnConsole == true, loginDone == true, displayAwake,
              !sessionSwitchedOut, !screensAsleep, !systemAsleep else {
            return .lockedOrLoginWindow
        }
        return .unlockedActiveSession
    }
}

/// Monitors the macOS screen-lock state and publishes changes as `HostLockState`.
///
/// Website detection strategy (excluded from Store compilation):
/// 1. `DistributedNotificationCenter` — system posts `com.apple.screenIsLocked` /
///    `com.apple.screenIsUnlocked` whenever the lock screen appears or disappears.
///    These undocumented notification names are website-only compatibility code.
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

    #if VAMP_APP_STORE
    @Published private(set) var lockState: HostLockState = .lockedOrLoginWindow
    #else
    @Published private(set) var lockState: HostLockState = .unlockedActiveSession
    #endif

    /// Thread-safe accessor for non-MainActor callers (e.g. the input router task).
    nonisolated var currentLockState: HostLockState {
        _stateLock.lock()
        defer { _stateLock.unlock() }
        return _cachedState
    }

    #if VAMP_APP_STORE
    private nonisolated(unsafe) var _cachedState: HostLockState = .lockedOrLoginWindow
    private var availability = StoreHostSessionAvailability()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    #else
    private nonisolated(unsafe) var _cachedState: HostLockState = .unlockedActiveSession
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    #endif
    private let _stateLock = NSLock()
    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "LockStateMonitor")

    // MARK: - Lifecycle

    #if VAMP_APP_STORE
    /// Store builds use documented NSWorkspace notifications and CGSession keys.
    /// These do not claim exact lock/unlock detection or enable remote input.
    func startMonitoring() {
        stopMonitoring()
        availability = StoreHostSessionAvailability()
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, StoreHostSessionAvailability.Event)] = [
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive),
            (NSWorkspace.screensDidSleepNotification, .screensSleep),
            (NSWorkspace.screensDidWakeNotification, .screensWake),
            (NSWorkspace.willSleepNotification, .systemSleep),
            (NSWorkspace.didWakeNotification, .systemWake)
        ]
        for (name, event) in events {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.availability.handle(event)
                    self.refresh()
                }
            })
        }
        refresh()
        // Public session/display snapshots can settle after a wake notification.
        // Retry without treating the wake itself as proof of an available session.
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.refresh()
            }
        }
    }

    func stopMonitoring() {
        refreshTask?.cancel()
        refreshTask = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    func refresh() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let display = CGMainDisplayID()
        apply(availability.state(
            isOnConsole: session?[kCGSessionOnConsoleKey as String] as? Bool,
            loginDone: session?[kCGSessionLoginDoneKey as String] as? Bool,
            displayAwake: display != kCGNullDirectDisplay && CGDisplayIsAsleep(display) == 0
        ))
    }
    #else
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
        // Any process can post this notification name, and trusting it reopens the input gate
        // while the Mac is still locked. Confirm with CGSession like the lock handler does, and
        // retry for a few seconds because WindowServer can lag the notification.
        Task { @MainActor [weak self] in
            for delay in [0.0, 0.5, 1.5, 3.0] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard let self else { return }
                if !self.cgSessionIsLocked() {
                    self.apply(.unlockedActiveSession)
                    self.logger.info("Screen unlocked notification confirmed")
                    return
                }
            }
            self?.logger.warning("Ignored an unlock notification that CGSession did not confirm")
        }
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
    #endif

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
