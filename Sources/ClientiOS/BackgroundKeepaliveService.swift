import Foundation
import Network
import os

#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class BackgroundKeepaliveService: ObservableObject {
    enum State: String {
        case inactive
        case active
        case expired
        case unsupported

        var title: String {
            switch self {
            case .inactive: return "Inactive"
            case .active: return "Active"
            case .expired: return "Expired"
            case .unsupported: return "Unsupported"
            }
        }
    }

    @Published private(set) var state: State = .inactive

    /// Fired when a foreground/network/unlock event suggests the app should
    /// try to recover its session (e.g. reconnect). Always called on the main
    /// actor. Coalesced — caller is responsible for deduping rapid retries.
    var onWakeRequested: (() -> Void)?

    private let logger = Logger(subsystem: "com.mesutcy.remotedesktop.ios", category: "Keepalive")

    #if canImport(UIKit)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.mesutcy.remotedesktop.ios.keepalive.path")
    private var pathMonitorStarted = false
    private var lastPathStatus: NWPath.Status = .requiresConnection
    private var notificationObservers: [NSObjectProtocol] = []

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        pathMonitor.cancel()
    }

    // MARK: - Lifecycle

    /// Install lifecycle/network observers. Call once at app launch.
    func installObservers() {
        installNotificationObservers()
        startPathMonitorIfNeeded()
    }

    /// Begin the short system background task used for cleanup/reconnect bookkeeping.
    /// Safe to call repeatedly.
    func begin() {
        #if canImport(UIKit)
        beginBackgroundTaskIfNeeded()
        state = backgroundTaskID == .invalid ? .unsupported : .active
        logger.info("Keepalive begin state=\(self.state.rawValue, privacy: .public)")
        #else
        state = .unsupported
        #endif
    }

    /// End the short system background task.
    func end() {
        endBackgroundTaskIfNeeded()
        if state != .expired { state = .inactive }
        logger.info("Keepalive end state=\(self.state.rawValue, privacy: .public)")
    }

    /// Trigger the wake callback unconditionally — used when we know the app
    /// just came back to the foreground.
    func requestWake(reason: String) {
        logger.info("Wake requested: \(reason, privacy: .public)")
        onWakeRequested?()
    }

    // MARK: - Background task

    #if canImport(UIKit)
    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "RemoteDesktopKeepalive") { [weak self] in
            Task { @MainActor [weak self] in
                self?.state = .expired
                self?.endBackgroundTaskIfNeeded()
            }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    #else
    private func beginBackgroundTaskIfNeeded() {}
    private func endBackgroundTaskIfNeeded() {}
    #endif

    // MARK: - Wake observers

    private func installNotificationObservers() {
        guard notificationObservers.isEmpty else { return }
        let center = NotificationCenter.default

        #if canImport(UIKit)
        notificationObservers.append(
            center.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.requestWake(reason: "protectedDataDidBecomeAvailable")
                }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.requestWake(reason: "didBecomeActive")
                }
            }
        )

        #endif
    }

    private func startPathMonitorIfNeeded() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func handlePathUpdate(_ path: NWPath) {
        let newStatus = path.status
        let recovered = (lastPathStatus != .satisfied) && (newStatus == .satisfied)
        lastPathStatus = newStatus
        if recovered {
            requestWake(reason: "network path satisfied")
        }
    }
}
