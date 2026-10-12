import Foundation
import Combine
import SwiftUI
import SharedUtilities
import HostWidgetShared
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Bridges the running host app and its desktop widget extension:
///
/// 1. Observes session/discovery/permission state and publishes a
///    `HostWidgetSnapshot` into the shared App Group, then reloads the widget.
/// 2. Listens for the Darwin notification posted by the widget's buttons and
///    applies the requested start/stop/restart on the live environment.
/// 3. Detects whether the widget is installed so the app can stay in the menu
///    bar instead of also showing the floating window (no duplication).
@MainActor
final class HostWidgetBridge {
    private weak var environment: HostAppEnvironment?
    private let hostNameOverride: String?
    private let snapshotNamespace: String?
    private var cancellables = Set<AnyCancellable>()
    private var publishWorkItem: DispatchWorkItem?
    private var darwinRegistered = false
    private var pollTimer: Timer?
    private var pollTick = 0

    init(environment: HostAppEnvironment, hostName: String? = nil, snapshotNamespace: String? = nil) {
        self.environment = environment
        self.hostNameOverride = hostName
        self.snapshotNamespace = snapshotNamespace
    }

    deinit {
        pollTimer?.invalidate()
        if darwinRegistered {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// Begin observing state and listening for widget actions.
    func start() {
        guard let environment else { return }

        // Re-publish whenever any of the relevant view models change. These are
        // @MainActor ObservableObjects, so objectWillChange fires just before the
        // value updates — schedule the read for the next runloop tick.
        for publisher in [
            environment.objectWillChange.eraseToAnyPublisher(),
            environment.sessionCoordinator.objectWillChange.eraseToAnyPublisher(),
            environment.discoveryAdvertiserViewModel.objectWillChange.eraseToAnyPublisher(),
            environment.permissionsViewModel.objectWillChange.eraseToAnyPublisher()
        ] {
            publisher
                .sink { [weak self] _ in self?.schedulePublish() }
                .store(in: &cancellables)
        }

        registerDarwinObserver()
        startPolling()
        publishSnapshot()
        // Apply anything the widget requested while the app was launching.
        applyPendingAction()
    }

    /// The Darwin notification from the (sandboxed) widget can be unreliable
    /// across the sandbox boundary, so we also poll the shared action file on a
    /// short interval. This is what actually guarantees the widget buttons work.
    /// Every ~5s we also re-check widget install so adding the widget mid-session
    /// still collapses the dashboard into the menu bar.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTick = 0
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applyPendingAction()
                self.pollTick += 1
                if self.pollTick % 5 == 0 {
                    self.environment?.refreshWidgetInstallSuppression()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Publishing

    private func schedulePublish() {
        publishWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.publishSnapshot() }
        publishWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func publishSnapshot() {
        guard let environment else { return }
        let phase = environment.sessionCoordinator.phase
        let hasBlockers = !environment.permissionsViewModel.blockers.isEmpty

        let widgetPhase: HostWidgetPhase
        let statusTitle: String
        if hasBlockers {
            widgetPhase = .setup
            statusTitle = "setup required"
        } else {
            switch phase {
            case .idle:
                widgetPhase = .idle
                statusTitle = "stopped"
            case .advertising, .awaitingClient:
                widgetPhase = .ready
                statusTitle = "ready"
            case .signalingConnected, .trustPending, .negotiating, .pipelineStarting:
                widgetPhase = .connecting
                statusTitle = "connecting"
            case .streaming:
                widgetPhase = .live
                statusTitle = environment.sessionCoordinator.connectedClientName
                    .map { "connected to \($0)" } ?? "streaming"
            case .error:
                widgetPhase = .error
                statusTitle = "error"
            }
        }

        var address: String?
        if phase != .idle, let ip = localIPv4Address() {
            address = "\(ip):\(RemoteDesktopConstants.defaultSignalingPort)"
        }

        let pendingPairingRequest: HostWidgetPendingPairingRequest?
        if let prompt = environment.pendingTrustPrompt,
           let deadline = environment.pendingTrustPromptDeadline {
            pendingPairingRequest = HostWidgetPendingPairingRequest(
                displayName: prompt.displayName,
                fingerprint: prompt.fingerprint,
                deadline: deadline
            )
        } else {
            pendingPairingRequest = nil
        }

        let snapshot = HostWidgetSnapshot(
            phase: widgetPhase,
            statusTitle: statusTitle,
            hostName: hostNameOverride ?? environment.hostIdentity.displayName,
            primaryAddress: address,
            addressLabel: address == nil ? nil : "lan",
            connectedClient: environment.sessionCoordinator.connectedClientName,
            pendingPairingRequest: pendingPairingRequest,
            updatedAt: Date()
        )
        HostWidgetStore.save(snapshot, namespace: snapshotNamespace)
        reloadWidget()
    }

    private func reloadWidget() {
        #if canImport(WidgetKit)
        // Target this widget explicitly. On macOS, reloadAllTimelines() can be
        // coalesced with unrelated widget work and leave the final offline entry
        // visible after Vamp Host has already relaunched.
        WidgetCenter.shared.reloadTimelines(ofKind: HostWidgetConstants.widgetKind)
        #endif
    }

    // MARK: - Widget actions (widget -> app)

    private func registerDarwinObserver() {
        guard !darwinRegistered else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let bridge = Unmanaged<HostWidgetBridge>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in bridge.applyPendingAction() }
            },
            HostWidgetConstants.actionDarwinName as CFString,
            nil,
            .deliverImmediately
        )
        darwinRegistered = true
    }

    /// Apply an action delivered directly via the app's URL handler
    /// (vamphost://action/<x>). This is the primary path now that the widget
    /// uses Links instead of in-extension AppIntents.
    func handle(action: HostWidgetAction) {
        guard let environment else { return }
        Task { @MainActor in
            switch action {
            case .start:
                await environment.startRuntimeIfNeeded()
            case .stop:
                await environment.stopRuntime()
            case .restart:
                await environment.stopRuntime()
                await environment.startRuntimeIfNeeded()
            case .approvePairing, .approveConnection:
                _ = environment.consumeCLITrustApproval()
            case .rejectPairing, .rejectConnection:
                environment.resolveTrustPrompt(approved: false)
            }
            publishSnapshot()
        }
    }

    private func applyPendingAction() {
        guard let environment, let action = HostWidgetStore.consumePendingAction(namespace: snapshotNamespace) else { return }
        Task { @MainActor in
            switch action {
            case .start:
                await environment.startRuntimeIfNeeded()
            case .stop:
                await environment.stopRuntime()
            case .restart:
                await environment.stopRuntime()
                await environment.startRuntimeIfNeeded()
            case .approvePairing, .approveConnection:
                _ = environment.consumeCLITrustApproval()
            case .rejectPairing, .rejectConnection:
                environment.resolveTrustPrompt(approved: false)
            }
            publishSnapshot()
        }
    }

    // MARK: - Install detection

    /// Calls back with whether at least one of our widgets is currently installed.
    ///
    /// WidgetKit's `getCurrentConfigurations` is flaky on macOS (empty lists and
    /// transient failures are common). Never clear the launch-time tray-hide cache
    /// on failure — only update it from a successful query — so a bad read can't
    /// make the next launch pop the dashboard again while the widget is still up.
    func checkWidgetInstalled(_ completion: @escaping (Bool) -> Void) {
        #if canImport(WidgetKit)
        WidgetCenter.shared.getCurrentConfigurations { result in
            switch result {
            case .success(let configs):
                let installed = configs.contains { $0.kind == HostWidgetConstants.widgetKind }
                UserDefaults.standard.set(installed, forKey: HostWidgetConstants.installedCacheKey)
                DispatchQueue.main.async { completion(installed) }
            case .failure:
                // Keep the previous cache; fall back to it for this session.
                let cached = UserDefaults.standard.bool(forKey: HostWidgetConstants.installedCacheKey)
                DispatchQueue.main.async { completion(cached) }
            }
        }
        #else
        completion(UserDefaults.standard.bool(forKey: HostWidgetConstants.installedCacheKey))
        #endif
    }
}

/// First non-loopback IPv4 address, preferring en* interfaces. Mirrors the
/// helper used by the dashboard so the widget shows the same address.
private func localIPv4Address() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let sa = ptr.pointee.ifa_addr.pointee
        guard sa.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: ptr.pointee.ifa_name)
        guard name != "lo0" else { continue }
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(ptr.pointee.ifa_addr, socklen_t(sa.sa_len),
                       &hostname, socklen_t(hostname.count),
                       nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: hostname)
            if name.hasPrefix("en") { return ip }
            if address == nil { address = ip }
        }
    }
    return address
}
