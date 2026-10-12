import SwiftUI
import SharedUtilities
import HostWidgetShared
import SharedUI
#if os(macOS)
import AppKit
#endif

#if !VAMP_TERMINAL_HOST && !VAMP_MINI_HOST
@main
struct HostApp: App {
    /// One process-wide owner prevents duplicate signaling/browser runtimes if
    /// SwiftUI reconstructs the App value while restoring the window scene.
    private static let hostEnvironment = HostAppEnvironment.placeholder()
    @StateObject private var environment = hostEnvironment
    #if os(macOS)
    @StateObject private var closeBehaviorController = HostWindowCloseBehaviorController.shared
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate
    #endif

    private static var versionString: String {
        "Version " + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
    }

    var body: some Scene {
        Window("Vamp Host", id: "main") {
            HostShellView(environment: environment)
            #if os(macOS)
                .background(
                    HostWindowAccessor { window in
                        closeBehaviorController.attach(to: window)
                    }
                )
                // The widget bridge is started by HostAppDelegate so it runs
                // regardless of window/scene state; URL actions
                // (vamphost://action/...) are handled there too.
            #endif
                // Skip the launch splash when the app is coming up headless into the menu bar
                // (desktop widget installed → the window is order-out'd right after it appears,
                // which made the splash flash for a frame and vanish). Same signal the window
                // controller uses to decide whether to hide the window at launch.
                .vampSplashWindow(
                    .host(version: Self.versionString, statusText: "Ready for connections"),
                    enabled: !UserDefaults.standard.bool(forKey: HostWidgetConstants.installedCacheKey)
                )
        }
        // Keep the Host 2.0 dashboard in a predictable desktop-sized range. The
        // dashboard owns a scrollable content region, so extra settings or pairing
        // state cannot push the window beyond a laptop display.
        #if os(macOS)
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 900)
        #endif

        #if os(macOS)
        MenuBarExtra {
            HostMenuBarContent(
                environment: environment,
                closeBehaviorController: closeBehaviorController
            )
        } label: {
            Image(nsImage: makeMenuBarTemplateIcon())
        }
        // Render the designed popover panel (status, address, buttons) rather than a
        // flattened standard menu.
        .menuBarExtraStyle(.window)
        #endif
    }

}
#endif

#if os(macOS)
private struct HostMenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var environment: HostAppEnvironment
    @ObservedObject var closeBehaviorController: HostWindowCloseBehaviorController
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 10) {
                HostAppLogo(size: 26, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Vamp Host")
                        .font(.headline)
                    Text(headerCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            // Status + connect address
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(menuStatusTitle)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(headerStateLabel.capitalized)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.15), in: Capsule())
                }

                if let address = lanAddress {
                    Divider()
                    HStack(spacing: 8) {
                        Text("LAN")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15), in: Capsule())
                        Text(address)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button {
                            copyAddress(address)
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundStyle(copied ? Color.green : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy address")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Divider()

            // Open the full dashboard
            Button {
                closeBehaviorController.showMainWindow(using: openWindow)
            } label: {
                Label("Open Dashboard", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Start / Stop + Restart
            HStack(spacing: 8) {
                if isRunning {
                    Button(role: .destructive) {
                        Task { await environment.stopRuntime() }
                    } label: {
                        Label(
                            environment.sessionCoordinator.connectedClientName != nil ? "Disconnect" : "Stop Host",
                            systemImage: "stop.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await environment.startRuntimeIfNeeded() }
                    } label: {
                        Label("Start Host", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    Task {
                        await environment.stopRuntime()
                        await environment.startRuntimeIfNeeded()
                    }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Divider()

            // Footer
            HStack {
                Button {
                    NSApp.hide(nil)
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
            .font(.callout)
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: State

    private var headerCaption: String {
        if !environment.permissionsViewModel.blockers.isEmpty {
            return "Grant the required host access before secure control can start."
        }
        switch environment.sessionCoordinator.phase {
        case .streaming:
            return "A trusted client is actively connected to this Mac."
        case .advertising, .awaitingClient:
            return "Advertising this Mac and waiting for a trusted device."
        case .signalingConnected, .trustPending, .negotiating, .pipelineStarting:
            return "Secure session handshake is in progress."
        case .error:
            return "The runtime needs attention before another session starts."
        case .idle:
            return "The host runtime is idle and can be restarted from here."
        }
    }

    private var headerStateLabel: String {
        if !environment.permissionsViewModel.blockers.isEmpty { return "SETUP" }
        switch environment.sessionCoordinator.phase {
        case .streaming:                                                              return "LIVE"
        case .advertising, .awaitingClient:                                           return "READY"
        case .signalingConnected, .trustPending, .negotiating, .pipelineStarting:     return "CONNECTING"
        case .error:                                                                  return "ERROR"
        case .idle:                                                                   return "IDLE"
        }
    }

    private var statusColor: Color {
        if !environment.permissionsViewModel.blockers.isEmpty { return AppColor.warning }
        switch environment.sessionCoordinator.phase {
        case .streaming:                    return AppColor.primaryAccent
        case .advertising, .awaitingClient: return AppColor.success
        case .error:                        return AppColor.error
        default:                            return AppColor.disconnected
        }
    }

    private var menuStatusTitle: String {
        if !environment.permissionsViewModel.blockers.isEmpty {
            return "Setup required before streaming"
        }
        switch environment.sessionCoordinator.phase {
        case .streaming:
            return "Connected to \(environment.sessionCoordinator.connectedClientName ?? "client")"
        case .advertising, .awaitingClient:
            return "Ready for trusted devices"
        case .idle:
            return "Runtime stopped"
        case .error:
            return "Host runtime needs attention"
        default:
            return "Preparing secure session"
        }
    }

    private var isRunning: Bool {
        environment.sessionCoordinator.phase != .idle
    }

    /// The host's LAN connect address, shown only while the runtime is up.
    private var lanAddress: String? {
        guard isRunning, let ip = primaryLANAddress() else { return nil }
        return "\(ip):\(RemoteDesktopConstants.defaultSignalingPort)"
    }

    private func copyAddress(_ address: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copied = false }
        }
    }

    /// Primary IPv4 address of an active `en*` interface (built-in `en0` preferred).
    private func primaryLANAddress() -> String? {
        var fallback: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }
}

final class HostWindowCloseBehaviorController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = HostWindowCloseBehaviorController()
    private weak var mainWindow: NSWindow?
    private var pendingCompact: (compact: Bool, size: CGSize)?
    private var savedFullFrame: NSRect?
    /// When the desktop widget is installed we keep the app in the menu bar and
    /// suppress the floating window so there's no duplicate of the same panel.
    private var suppressWindow = false
    private var userRequestedShow = false
    private var visibilityObservers: [NSObjectProtocol] = []
    var userHasRequestedShow: Bool { userRequestedShow }

    func attach(to window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        window.delegate = self
        window.titleVisibility = .hidden
        // Continue the same system-rendered clear surface through the unified
        // title bar instead of inserting a separate dark AppKit material.
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unifiedCompact
        setDarkAppearance(UserDefaults.standard.object(forKey: "host.appearance.dark") as? Bool ?? true)
        // Keep the AppKit window transparent so AppBackground's material can blur
        // the desktop behind the dashboard instead of flattening clear glass onto
        // an opaque gray window color.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.toolbar?.showsBaselineSeparator = false
        // The window may attach after the dashboard requested its mode/size, so
        // apply whatever was last requested now that we hold a real window.
        // Defer to the next runloop tick: applyMode mutates styleMask and the
        // title bar, which must not happen during the current layout pass.
        if let pending = pendingCompact {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.applyMode(pending.compact, size: pending.size, to: window, animate: false)
            }
        }
        observeVisibility(of: window)
        // If the widget was installed as of last launch, stay in the tray unless
        // the user has explicitly asked to open the window this session.
        if shouldSuppressWindow {
            suppressWindow = true
            hideWindowIfSuppressed(window)
        }
    }

    func setDarkAppearance(_ isDark: Bool) {
        mainWindow?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// Hide the window and keep it hidden at launch because the widget is present.
    func suppressWindowForWidget() {
        suppressWindow = true
        hideWindowIfSuppressed(mainWindow)
    }

    private var shouldSuppressWindow: Bool {
        !userRequestedShow
            && (suppressWindow || UserDefaults.standard.bool(forKey: HostWidgetConstants.installedCacheKey))
    }

    /// SwiftUI's WindowGroup often re-orders the window after our first `orderOut`,
    /// so watch for it becoming key/main/visible and hide again while suppressed.
    private func observeVisibility(of window: NSWindow) {
        for observer in visibilityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        visibilityObservers.removeAll()
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeOcclusionStateNotification
        ]
        for name in names {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.hideWindowIfSuppressed(window)
            }
            visibilityObservers.append(observer)
        }
    }

    /// Defer `orderOut` so we never mutate visibility during a SwiftUI/AppKit
    /// layout pass (that path crashed title-bar layout on macOS 26). A second
    /// tick covers WindowGroup re-showing the scene after the first hide.
    private func hideWindowIfSuppressed(_ window: NSWindow?) {
        guard shouldSuppressWindow, let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.shouldSuppressWindow else { return }
            window.orderOut(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak window] in
                guard let self, let window, self.shouldSuppressWindow else { return }
                if window.isVisible { window.orderOut(nil) }
            }
        }
    }

    /// Drives the host window between the full dashboard and the mini widget.
    /// Idempotent — safe to call repeatedly as the dashboard re-measures.
    func setCompact(_ compact: Bool, size: CGSize) {
        pendingCompact = (compact, size)
        guard let window = mainWindow else { return }
        applyMode(compact, size: size, to: window, animate: true)
    }

    private func applyMode(_ compact: Bool, size: CGSize, to window: NSWindow, animate: Bool) {
        if compact {
            if savedFullFrame == nil, !window.styleMask.contains(.fullScreen) {
                savedFullFrame = window.frame
            }
            window.toolbar?.isVisible = false
            // Draw the card under the title bar so there's no empty strip on top,
            // while keeping the traffic-light buttons visible and usable.
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.resizable)
            // The mini widget supplies its own close control in the card header,
            // so hide the native traffic lights for a clean glass panel. The card
            // is draggable via isMovableByWindowBackground.
            setTrafficLights(hidden: true, in: window)
            // Make the window itself transparent so the frosted-glass card blurs
            // the desktop behind it instead of sitting on opaque black.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            let target = NSSize(width: max(size.width, 200), height: max(size.height, 120))
            window.contentMinSize = target
            window.contentMaxSize = target
            // With fullSizeContentView the content view fills the entire window
            // frame, so the frame size IS the content size — adding the title-bar
            // height (as frameRect(forContentRect:) would) leaves an empty strip.
            let current = window.frame
            let frame = NSRect(
                x: current.origin.x,
                y: current.maxY - target.height,
                width: target.width,
                height: target.height
            )
            // Only move the window if it isn't already the right size, so repeated
            // re-measures don't cause jitter.
            if abs(current.width - frame.width) > 0.5 || abs(current.height - frame.height) > 0.5 {
                window.setFrame(frame, display: true, animate: animate)
            }
        } else {
            window.toolbar?.isVisible = true
            // Keep the content view full-size in every mode. Toggling this mask
            // was the source of earlier title-bar instability, and removing it
            // also creates an opaque material strip above the clear dashboard.
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.insert(.resizable)
            setTrafficLights(hidden: false, in: window)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentMinSize = NSSize(width: 500, height: 520)
            window.contentMaxSize = NSSize(width: 760, height: 920)
            if let restore = savedFullFrame {
                window.setFrame(restore, display: true, animate: animate)
                savedFullFrame = nil
            }
        }
    }

    private func setTrafficLights(hidden: Bool, in window: NSWindow) {
        window.standardWindowButton(.closeButton)?.isHidden = hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
        window.standardWindowButton(.zoomButton)?.isHidden = hidden
    }

    /// Frame for a given content size, anchored at the window's current top-left
    /// so the widget grows/shrinks in place.
    private func frame(for window: NSWindow, contentSize: NSSize) -> NSRect {
        let current = window.frame
        var rect = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        rect.origin.x = current.origin.x
        rect.origin.y = current.maxY - rect.height
        return rect
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing while the widget is installed returns to tray-only mode for
        // the rest of the session (until Open Dashboard / Dock reopen).
        if UserDefaults.standard.bool(forKey: HostWidgetConstants.installedCacheKey) {
            userRequestedShow = false
            suppressWindow = true
        }
        sender.orderOut(nil)
        return false
    }

    /// Hides the host window (used by the mini widget's custom close button,
    /// since it suppresses the native traffic lights).
    func hideWindow() {
        if UserDefaults.standard.bool(forKey: HostWidgetConstants.installedCacheKey) {
            userRequestedShow = false
            suppressWindow = true
        }
        mainWindow?.orderOut(nil)
    }

    func showMainWindow(using openWindow: OpenWindowAction) {
        userRequestedShow = true
        if bringExistingWindowFront() { return }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    func bringExistingWindowFront() -> Bool {
        userRequestedShow = true
        let target = mainWindow ?? NSApp.windows.first { window in
            window.contentViewController != nil && window.canBecomeMain
        }
        guard let window = target else { return false }
        if mainWindow == nil { mainWindow = window }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HostProcessHeartbeat.shared.start()
        HostWatchdogInstaller.installAndLoad()
        // Start the widget bridge as soon as the app is up, independent of any
        // window/scene (the window may be suppressed when the widget is present).
        // The environment is created when the SwiftUI scene initializes; retry
        // briefly until it's available.
        startWidgetBridgeWhenReady(attempt: 0)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-assert tray-only mode if the widget is installed. SwiftUI can surface
        // the WindowGroup again on activation (login items, URL opens, focus).
        HostAppEnvironment.shared?.refreshWidgetInstallSuppression()
        if !HostWindowCloseBehaviorController.shared.userHasRequestedShow,
           UserDefaults.standard.bool(forKey: HostWidgetConstants.installedCacheKey) {
            HostWindowCloseBehaviorController.shared.suppressWindowForWidget()
        }

        // TCC commits Screen Recording and Accessibility changes while the user
        // is in System Settings. Re-read after returning to the host instead of
        // leaving the dashboard stuck on the pre-settings state.
        guard let environment = HostAppEnvironment.shared else { return }
        Task { @MainActor in
            // Give tccd a moment to commit the checkbox change before probing it.
            try? await Task.sleep(nanoseconds: 350_000_000)
            await environment.permissionsViewModel.refresh()
        }
    }

    private func startWidgetBridgeWhenReady(attempt: Int) {
        if let env = HostAppEnvironment.shared {
            env.activateWidgetBridge()
            // Start the host runtime (signaling listener + Bonjour advertising) independent
            // of the window/scene. On an SMAppService login launch the app comes up
            // unactivated and the main window is orderOut'd when the desktop widget is
            // installed, so HostShellView's `.task { startRuntimeIfNeeded() }` never runs and
            // the host stays undiscoverable until a manual reopen. startSession()/startIfNeeded()
            // are guarded + idempotent, so this can't double-start with the scene's .task.
            Task { @MainActor in await env.startRuntimeIfNeeded() }
            return
        }
        guard attempt < 50 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.startWidgetBridgeWhenReady(attempt: attempt + 1)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A normal Quit pauses recovery. A watchdog-requested SIGTERM carries a
        // recovery marker, so it must not be mistaken for an intentional Quit.
        HostProcessHeartbeat.shared.stopForTermination()
        // Reflect the closed state in the desktop widget.
        HostAppEnvironment.shared?.publishWidgetOffline()
    }

    /// Handle the widget's control links (vamphost://action/<start|stop|restart|approve-pairing|...>).
    /// With an app delegate present, AppKit routes URL opens here rather than to
    /// SwiftUI's onOpenURL. We hand off via the shared action file + Darwin ping,
    /// which the running app's widget bridge consumes (and also polls), so this
    /// works whether the app was already running or just launched by the link.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let action = HostWidgetAction.from(url: url) else { continue }
            if let environment = HostAppEnvironment.shared {
                if action == .approvePairing || action == .approveConnection {
                    _ = environment.consumeCLITrustApproval()
                    continue
                }
                environment.applyWidgetAction(action)
            } else {
                HostWidgetStore.setPendingAction(action)
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName(HostWidgetConstants.actionDarwinName as CFString),
                    nil, nil, true
                )
            }
        }
        // Keep the app in the menu bar; the link shouldn't surface the window.
        DispatchQueue.main.async {
            if !HostWindowCloseBehaviorController.shared.userHasRequestedShow {
                HostWindowCloseBehaviorController.shared.hideWindow()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reuse the existing host window instead of letting SwiftUI's WindowGroup
        // spawn a new one each time the app is re-activated (Dock click, Spotlight,
        // launchd relaunch after wake, etc.).
        if HostWindowCloseBehaviorController.shared.bringExistingWindowFront() {
            return false
        }
        return true
    }
}

private struct HostWindowAccessor: NSViewRepresentable {
    let onResolveWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolveWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolveWindow(window)
            }
        }
    }
}
#endif
