import Combine
import Foundation
import os
import SharedModels
import SharedProtocol
import TransportWebRTC

private let appStreamLog = Logger(subsystem: "com.mesutcy.remotedesktop.stream", category: "AppStream")

enum AppStreamApplicationProfile {
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "com.github.wez.wezterm-gui",
        "dev.warp.warp",
        "dev.warp.warp-stable",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
    ]

    static func isTerminal(bundleIdentifier: String?, name: String) -> Bool {
        if let bundleIdentifier,
           terminalBundleIDs.contains(bundleIdentifier.lowercased()) {
            return true
        }
        let normalized = name.lowercased()
        return ["terminal", "iterm", "ghostty", "wezterm", "warp", "alacritty", "kitty", "hyper"]
            .contains { normalized.contains($0) }
    }

}

/// Tracks the latest explicit sizing intent independently of the in-flight transport request.
struct AppStreamSizingIntent {
    private(set) var generation: UUID?
    private(set) var pending = false

    @discardableResult mutating func request() -> UUID {
        let token = UUID()
        generation = token
        pending = true
        return token
    }

    mutating func markSent(_ token: UUID) {
        if accepts(token) { pending = false }
    }

    mutating func cancel() {
        generation = nil
        pending = false
    }

    func accepts(_ token: UUID) -> Bool { generation == token }
}

/// Client-side driver for App Streaming. Self-contained: it consumes the broadcast
/// `receiveDataMessages()` stream directly (like `ClientFileTransferManager`), so it needs no
/// changes to `ClientSessionCoordinator`'s dispatch. It sends `applicationList` /
/// `streamTargetSwitch` requests (auto-authenticated by `sendDataMessage`) and turns the host's
/// results — including the unsolicited target-lost result — into an explicit UI state machine.
@MainActor
final class AppStreamViewModel: ObservableObject {

    /// Explicit session state (no conflicting booleans). `.streaming` means the host confirmed
    /// the target; the view treats it as *interactive* once `sessionCoordinator.phase == .receiving`
    /// (a real first frame), which avoids a "connected but frozen" surface.
    enum Status: Equatable {
        case idle
        case loadingApps
        case browsing
        case launching(name: String)
        case streaming(target: StreamTarget, name: String)
        case failed(reason: String)
        case targetLost(reason: String)
    }

    /// The currently-streamed window's geometry (point size + Retina scale), used to map touch
    /// input into the window. Nil unless a window is streaming.
    struct StreamedWindow: Equatable {
        let windowID: String
        let pointWidth: Double
        let pointHeight: Double
        let scale: Double
    }

    @Published private(set) var applications: [RemoteApplication] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var streamedWindow: StreamedWindow?
    @Published private(set) var streamedApplication: RemoteApplication?

    @Published private(set) var isGeometryChanging = false
    @Published private(set) var isResizing = false
    @Published private(set) var geometryRevision = 0
    @Published private(set) var sizingNotice: String?
    @Published private(set) var supportsAdaptiveSizing = false
    @Published private(set) var sizingMode: AppWindowSizingMode = .original
    private var viewportSize = CGSize.zero
    private var sizingIntent = AppStreamSizingIntent()
    private var resizeTask: Task<Void, Never>?
    private var targetSendTask: Task<Void, Never>?
    private var lastControlRequestAt: TimeInterval?
    private var isSuspended = false
    private var lastRequestedViewport = CGSize.zero
    private var resumeSelection: (RemoteApplication, String, String)?
    private var selectionFingerprint: String?

    private let environment: ClientAppEnvironment
    private var receiveTask: Task<Void, Never>?
    private var listRetryTask: Task<Void, Never>?
    private var launchTimeoutTask: Task<Void, Never>?
    private var pendingTargetName: String?
    private var pendingRequestID: UUID?
    private var pendingCloseRequestID: UUID?
    private var pendingCloseName: String?
    private var closeTimeoutTask: Task<Void, Never>?
    private var clientViewportAspect: Double?
    private var listOffset = 0
    private var loadingApplications: [RemoteApplication] = []

    init(environment: ClientAppEnvironment) {
        self.environment = environment
    }

    /// True when the connected host negotiated App Streaming (macOS 14+ host).
    var isSupported: Bool {
        environment.sessionCoordinator.negotiatedCapabilities?.supportsAppStreaming ?? false
    }

    /// Begin consuming host messages. Safe to call repeatedly.
    ///
    /// The stream is created (which registers our broadcast continuation) *synchronously* here,
    /// before `requestApplicationList()` runs — otherwise the request could be sent before the
    /// receive loop is registered and the host's snapshot would be missed (the "stuck on
    /// Loading applications" race).
    func start() {
        isSuspended = false
        guard receiveTask == nil else { return }
        let stream = environment.webRTCSessionManager.receiveDataMessages()
        receiveTask = Task { [weak self] in
            for await envelope in stream {
                if Task.isCancelled { break }
                self?.handle(envelope)
            }
            if let self, !Task.isCancelled {
                self.receiveTask = nil
            }
        }
    }

    func stop() {
        if let app = streamedApplication, let window = streamedWindow, let fingerprint = selectionFingerprint {
            resumeSelection = (app, window.windowID, fingerprint)
        }
        resizeTask?.cancel()
        resizeTask = nil
        targetSendTask?.cancel()
        targetSendTask = nil
        isResizing = false
        isGeometryChanging = false
        receiveTask?.cancel()
        receiveTask = nil
        listRetryTask?.cancel()
        listRetryTask = nil
        launchTimeoutTask?.cancel()
        launchTimeoutTask = nil
        closeTimeoutTask?.cancel()
        closeTimeoutTask = nil
        applications = []
        streamedWindow = nil
        streamedApplication = nil
        pendingTargetName = nil
        pendingRequestID = nil
        pendingCloseRequestID = nil
        pendingCloseName = nil
        supportsAdaptiveSizing = false
        status = .idle
    }

    // MARK: - Intents

    func updateClientViewport(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let aspect = Double(size.width / size.height)
        guard aspect.isFinite, (0.25...4).contains(aspect) else { return }
        guard abs(size.width - viewportSize.width) > 2 || abs(size.height - viewportSize.height) > 2 else { return }
        clientViewportAspect = aspect
        viewportSize = size
        scheduleResize()
    }

    func setSizingMode(_ mode: AppWindowSizingMode) {
        guard supportsAdaptiveSizing else {
            sizingNotice = "Update Vamp Sync to enable adaptive sizing and Original Size."
            return
        }
        sizingMode = mode
        sizingIntent.request()
        lastRequestedViewport = .zero
        scheduleResize(force: true)
    }

    private func scheduleResize(force: Bool = false) {
        guard force || sizingMode == .adaptive || sizingIntent.pending else { return }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, !self.isResizing, !self.isSuspended, self.supportsAdaptiveSizing,
                  case .streaming = self.status, let window = self.streamedWindow,
                  let app = self.streamedApplication,
                  (self.sizingIntent.pending || self.lastRequestedViewport != self.viewportSize),
                  self.environment.sessionCoordinator.hostLockState == .unlockedActiveSession else { return }
            self.isResizing = true
            self.sendTargetRequest(app, windowID: window.windowID)
        }
    }

    func forgetSelection() { resumeSelection = nil; selectionFingerprint = nil }

    func suspendInteraction() {
        pauseForHostLock()
    }


    func requestApplicationList() {
        guard environment.sessionCoordinator.hostLockState == .unlockedActiveSession else {
            listRetryTask?.cancel()
            listRetryTask = nil
            status = .browsing
            return
        }
        guard environment.sessionCoordinator.activeSessionID != nil else {
            status = .failed(reason: "Not connected to a Mac.")
            return
        }
        listOffset = 0
        loadingApplications = []
        status = .loadingApps
        sendListRequest(attempt: 1)
    }

    /// The control-channel auth handshake can lag the session becoming "ready", so the very first
    /// request may be dropped as unauthenticated. Retry a few times until the snapshot arrives.
    private func sendListRequest(attempt: Int) {
        guard let sessionID = environment.sessionCoordinator.activeSessionID else {
            status = .failed(reason: "Not connected to a Mac.")
            return
        }
        let request = ApplicationListRequestMessage(
            sessionID: sessionID,
            senderDeviceID: environment.clientIdentity.id,
            offset: listOffset
        )
        do {
            try environment.webRTCSessionManager.sendDataMessage(
                try DataChannelEnvelope.applicationListRequest(request))
            appStreamLog.info("requestApplicationList sent attempt=\(attempt, privacy: .public) session=\(sessionID.uuidString, privacy: .public)")
        } catch {
            appStreamLog.error("requestApplicationList send failed: \(String(describing: error), privacy: .public)")
        }

        listRetryTask?.cancel()
        listRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            // Still waiting? Retry (up to a bound) or surface a failure.
            // Cached apps remain visible during refresh; only a new snapshot ends the wait.
            guard case .loadingApps = self.status else { return }
            if attempt < 6 {
                self.sendListRequest(attempt: attempt + 1)
            } else {
                self.status = .failed(reason: "The Mac didn't send its apps. Tap Retry.")
            }
        }
    }

    func close(_ application: RemoteApplication) {
        guard ApplicationClosePolicy.canClose(application.bundleIdentifier) else {
            status = .failed(reason: "\(application.name) cannot be closed remotely.")
            return
        }
        guard environment.sessionCoordinator.hostLockState == .unlockedActiveSession else {
            status = .failed(reason: "Unlock the Mac to close applications.")
            return
        }
        guard let sessionID = environment.sessionCoordinator.activeSessionID else {
            status = .failed(reason: "Not connected to a Mac.")
            return
        }
        lastControlRequestAt = ProcessInfo.processInfo.systemUptime
        pendingCloseName = application.name
        pendingCloseRequestID = UUID()
        let request = ApplicationCloseRequestMessage(
            sessionID: sessionID,
            bundleIdentifier: application.bundleIdentifier,
            senderDeviceID: environment.clientIdentity.id,
            requestID: pendingCloseRequestID
        )
        do {
            try environment.webRTCSessionManager.sendDataMessage(
                try DataChannelEnvelope.applicationCloseRequest(request))
        } catch {
            status = .failed(reason: "Could not ask the Mac to close \(application.name).")
            pendingCloseRequestID = nil
            pendingCloseName = nil
            return
        }
        armCloseTimeout(name: application.name)
    }

    func select(_ application: RemoteApplication, windowID: String? = nil) {
        guard environment.sessionCoordinator.hostLockState == .unlockedActiveSession else {
            status = .failed(reason: "Unlock the Mac to open applications.")
            return
        }
        guard environment.sessionCoordinator.activeSessionID != nil else {
            status = .failed(reason: "Not connected to a Mac.")
            return
        }
        resumeSelection = nil
        selectionFingerprint = environment.sessionCoordinator.connectedHostFingerprint
        sizingMode = .original
        sizingIntent.cancel()
        streamedApplication = application
        sendTargetRequest(application, windowID: windowID)
    }

    private func sendTargetRequest(_ application: RemoteApplication, windowID: String?) {
        if !isResizing { status = .launching(name: application.name) }
        targetSendTask?.cancel()
        let sessionID = environment.sessionCoordinator.activeSessionID
        targetSendTask = Task { [weak self] in
            guard let self else { return }
            let delay = Self.controlRequestDelay(last: self.lastControlRequestAt, now: ProcessInfo.processInfo.systemUptime)
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, !self.isSuspended,
                  sessionID == self.environment.sessionCoordinator.activeSessionID else { return }
            self.performTargetRequest(application, windowID: windowID)
        }
    }

    /// The host shares a two-second limiter across close and target-switch commands.
    /// Debounce layout at 300ms, but wait out that limiter instead of losing a request.
    static func controlRequestDelay(last: TimeInterval?, now: TimeInterval) -> TimeInterval {
        guard let last else { return 0 }
        return max(0, 2.1 - (now - last))
    }

    private func performTargetRequest(_ application: RemoteApplication, windowID: String?) {
        guard let sessionID = environment.sessionCoordinator.activeSessionID else {
            status = .failed(reason: "Not connected to a Mac.")
            return
        }
        lastControlRequestAt = ProcessInfo.processInfo.systemUptime
        pendingTargetName = application.name
        pendingRequestID = UUID()
        if !isResizing { status = .launching(name: application.name) }
        lastRequestedViewport = viewportSize
        if let token = sizingIntent.generation { sizingIntent.markSent(token) }
        armLaunchTimeout(name: application.name)
        let request = StreamTargetSwitchRequestMessage(
            sessionID: sessionID,
            target: windowID.map(StreamTarget.window) ?? .application(application.bundleIdentifier),
            senderDeviceID: environment.clientIdentity.id,
            clientViewportAspect: supportsAdaptiveSizing && sizingMode == .adaptive ? clientViewportAspect : nil,
            viewportWidth: viewportSize.width > 0 ? Double(viewportSize.width) : nil,
            viewportHeight: viewportSize.height > 0 ? Double(viewportSize.height) : nil,
            sizingMode: sizingMode,
            requestID: pendingRequestID
        )
        do {
            try environment.webRTCSessionManager.sendDataMessage(
                try DataChannelEnvelope.streamTargetSwitch(request))
        } catch {
            isResizing = false
            pendingRequestID = nil
            launchTimeoutTask?.cancel()
            status = .failed(reason: "Could not start \(application.name).")
        }
    }

    /// Safety net for a host that dies mid-launch. It must outlast the host's own bounded
    /// launch loop (up to ~20s of window polling on a cold start) or a slow app reports a
    /// failure here while the Mac is still opening it.
    private func armLaunchTimeout(name: String) {
        launchTimeoutTask?.cancel()
        launchTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if !self.isResizing { guard case .launching = self.status else { return } }
            self.isResizing = false
            self.pendingRequestID = nil
            self.pendingTargetName = nil
            self.status = .failed(reason: "The Mac did not open \(name) in time. Tap Retry.")
        }
    }

    private func armCloseTimeout(name: String) {
        closeTimeoutTask?.cancel()
        closeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.pendingCloseRequestID != nil else { return }
            self.pendingCloseRequestID = nil
            self.pendingCloseName = nil
            self.status = .failed(reason: "The Mac did not close \(name) in time.")
        }
    }

    func backToApps() {
        sizingIntent.cancel()
        targetSendTask?.cancel()
        forgetSelection()
        resizeTask?.cancel()
        isResizing = false
        launchTimeoutTask?.cancel()
        launchTimeoutTask = nil
        pendingTargetName = nil
        pendingRequestID = nil
        streamedWindow = nil
        streamedApplication = nil
        status = .browsing
        requestApplicationList()
    }

    /// A locked Mac intentionally rejects app inventory and launch commands. Pause bounded
    /// retries while locked, then let the view resume them immediately after the host reports
    /// an unlocked session. An already-running stream keeps its target state for fast recovery.
    func pauseForHostLock() {
        isSuspended = true
        isGeometryChanging = false
        targetSendTask?.cancel()
        resizeTask?.cancel()
        isResizing = false
        pendingRequestID = nil
        listRetryTask?.cancel()
        listRetryTask = nil
        launchTimeoutTask?.cancel()
        launchTimeoutTask = nil
        if case .streaming = status { return }
        pendingTargetName = nil
        pendingRequestID = nil
        status = .browsing
    }

    func resumeAfterHostUnlock() {
        isSuspended = false
        if case .streaming = status {
            lastRequestedViewport = .zero
            scheduleResize()
            return
        }
        requestApplicationList()
    }

    // MARK: - Inbound

    func handle(_ envelope: DataChannelEnvelope) {
        appStreamLog.debug("rx kind=\(envelope.kind.rawValue, privacy: .public) payload=\(envelope.payload.count, privacy: .public)B")
        switch envelope.kind {
        case .applicationList:
            guard let snapshot = try? envelope.decodeApplicationListSnapshot() else {
                appStreamLog.error("applicationList decode FAILED payload=\(envelope.payload.count, privacy: .public)B")
                return
            }
            guard snapshot.sessionID == environment.sessionCoordinator.activeSessionID,
                  snapshot.senderDeviceID == environment.clientIdentity.id else { return }
            appStreamLog.info("applicationList snapshot apps=\(snapshot.applications.count, privacy: .public)")
            if case .loadingApps = status {
                guard (snapshot.offset ?? 0) == listOffset else { return }
                listRetryTask?.cancel()
                loadingApplications.append(contentsOf: snapshot.applications)
                if let next = snapshot.nextOffset {
                    guard next > listOffset, next <= 65_536,
                          loadingApplications.count <= 65_536 else {
                        status = .failed(reason: "The Mac returned an invalid app list page.")
                        return
                    }
                    listOffset = next
                    sendListRequest(attempt: 1)
                    return
                }
                var seen = Set<String>()
                applications = loadingApplications.filter { seen.insert($0.id).inserted }
                loadingApplications = []
                status = .browsing
                if let (app, windowID, fingerprint) = resumeSelection {
                    resumeSelection = nil
                    if Self.canResume(applicationID: app.id, windowID: windowID, expectedFingerprint: fingerprint,
                                      connectedFingerprint: environment.sessionCoordinator.connectedHostFingerprint,
                                      applications: applications) {
                        select(app, windowID: windowID)
                    }
                }
            }
        case .streamTargetSwitch:
            guard let result = try? envelope.decodeStreamTargetSwitchResult() else { return }
            guard result.sessionID == environment.sessionCoordinator.activeSessionID,
                  result.senderDeviceID == environment.clientIdentity.id else { return }
            apply(result)
        case .applicationClose:
            guard let result = try? envelope.decodeApplicationCloseResult() else { return }
            guard result.sessionID == environment.sessionCoordinator.activeSessionID,
                  result.senderDeviceID == environment.clientIdentity.id else { return }
            applyClose(result)
        default:
            break
        }
    }

    func apply(_ result: StreamTargetSwitchResultMessage) {
        // Returning to the browser cancels the local launch intent. A delayed host reply
        // must not navigate back into a stream the user has already left.
        switch status {
        case .launching, .streaming: break
        default: return
        }
        guard Self.accepts(result, status: status, pendingRequestID: pendingRequestID, isResizing: isResizing) else { return }
        if result.requestID == nil, result.status == .accepted {
            isGeometryChanging = true
            return
        }
        if isResizing, result.status == .accepted { return }
        isGeometryChanging = false
        if isResizing, result.status == .failed || result.status == .rejected {
            isResizing = false
            pendingRequestID = nil
            launchTimeoutTask?.cancel()
            // A failed retarget may have stopped capture. Require explicit recovery.
            streamedWindow = nil
            status = .targetLost(reason: result.reason ?? "Window resize failed. Reopen the app.")
            return
        }

        if result.status == .completed {
            guard let width = result.width, let height = result.height, width > 0, height > 0,
                  let scale = result.scaleFactor,
                  scale.isFinite, scale > 0 else {
                streamedWindow = nil
                status = .failed(reason: "The Mac returned an invalid window size.")
                return
            }
            guard result.resolvedTarget.kind == .window else { return }
            isResizing = false
            if result.appliedSizingMode != nil { supportsAdaptiveSizing = true }
            sizingNotice = result.reason
            geometryRevision &+= 1
            streamedWindow = StreamedWindow(
                windowID: result.resolvedTarget.identifier,
                pointWidth: Double(width),
                pointHeight: Double(height),
                scale: scale
            )
        } else if result.status == .failed || result.status == .rejected {
            streamedWindow = nil
        }
        status = Self.reduce(status: status, result: result, pendingName: pendingTargetName ?? "Application")
        if result.status != .accepted { pendingRequestID = nil }
        if result.status == .completed { scheduleResize() }
        // `.accepted` only means the host took the request; it still has to launch the app and
        // resolve a window. Re-arm rather than leaving the browser stuck on "Opening…" forever.
        if case .launching(let name) = status {
            armLaunchTimeout(name: name)
        } else {
            launchTimeoutTask?.cancel()
            launchTimeoutTask = nil
        }
    }

    static func canResume(applicationID: String, windowID: String, expectedFingerprint: String,
                          connectedFingerprint: String?, applications: [RemoteApplication]) -> Bool {
        !expectedFingerprint.isEmpty && expectedFingerprint == connectedFingerprint
            && applications.contains { $0.id == applicationID && $0.windowIDs.contains(windowID) }
    }

    static func accepts(_ result: StreamTargetSwitchResultMessage, status: Status,
                        pendingRequestID: UUID?, isResizing: Bool) -> Bool {
        switch status { case .launching, .streaming: break; default: return false }
        if let requestID = result.requestID { return requestID == pendingRequestID }
        guard !isResizing, case .streaming(let target, _) = status else { return false }
        return result.resolvedTarget == target
    }

    func applyClose(_ result: ApplicationCloseResultMessage) {
        if let requestID = result.requestID {
            guard requestID == pendingCloseRequestID else { return }
        }
        closeTimeoutTask?.cancel()
        closeTimeoutTask = nil
        let name = pendingCloseName ?? result.bundleIdentifier
        pendingCloseRequestID = nil
        pendingCloseName = nil

        switch result.status {
        case .completed, .accepted:
            markClosed(result.bundleIdentifier)
            if streamedApplication?.bundleIdentifier == result.bundleIdentifier {
                backToApps()
            } else if case .streaming = status {
                break
            } else {
                status = .browsing
            }
        case .rejected, .failed:
            status = .failed(reason: result.reason ?? "Could not close \(name).")
        }
    }

    private func markClosed(_ bundleIdentifier: String) {
        applications = applications.map { application in
            guard application.bundleIdentifier == bundleIdentifier else { return application }
            return RemoteApplication(
                bundleIdentifier: application.bundleIdentifier,
                name: application.name,
                isRunning: false,
                isActive: false,
                iconPNGBase64: application.iconPNGBase64,
                windowIDs: [],
                windowTitles: nil
            )
        }
    }

    /// Pure state transition (no environment) — unit-tested.
    static func reduce(status: Status, result: StreamTargetSwitchResultMessage, pendingName: String) -> Status {
        switch result.status {
        case .accepted:
            return .launching(name: pendingName)
        case .completed:
            return .streaming(target: result.resolvedTarget, name: pendingName)
        case .rejected, .failed:
            let reason = result.reason ?? "The application is unavailable."
            // A failure arriving while we are already streaming is the host's unsolicited
            // target-lost signal (window closed / app quit) — distinguish it from a launch failure.
            if case .streaming = status {
                return .targetLost(reason: reason)
            }
            return .failed(reason: reason)
        }
    }
}
