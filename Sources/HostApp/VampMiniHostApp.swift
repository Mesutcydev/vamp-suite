#if VAMP_MINI_HOST && os(macOS)
import AppKit
import Combine
import Darwin
import SwiftUI
import SharedModels
import SharedUtilities
import Permissions

/// Storage used by the standalone Vamp Sync product. The legacy directory is
/// intentionally retained so existing trust data remains upgrade-compatible.
///
/// The mini host deliberately does not share the full host's identity or peer
/// list. Installing it should create a separate trust boundary, even though
/// both products use the same signed signaling and authenticated transport.
// Keep the legacy storage path so an app rename preserves existing trusted peers.
private enum VampMiniHostStorage {
    static let identityTag = "com.mesutcy.remotedesktop.minhost.p256"

    static var trustedPeerDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("RemoteDesktopTool", isDirectory: true)
            .appendingPathComponent("Vamp Mini Host", isDirectory: true)
    }
}

@main
struct VampMiniHostApp: App {
    private static let environment = HostAppEnvironment.placeholder(
        mode: .mini,
        identityTag: VampMiniHostStorage.identityTag,
        trustedPeerDirectory: VampMiniHostStorage.trustedPeerDirectory
    )

    @NSApplicationDelegateAdaptor(VampMiniHostAppDelegate.self) private var appDelegate

    init() {
        _ = Self.environment
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class VampMiniHostAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var environment: HostAppEnvironment?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var phaseObserver: AnyCancellable?
    private var trustPromptObserver: AnyCancellable?
    private var permissionObserver: AnyCancellable?
    private weak var statusDotView: VampSyncMenuBarStatusDotView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        startRuntimeWhenReady(attempt: 0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            await HostAppEnvironment.shared?.stopRuntime()
        }
    }

    private func startRuntimeWhenReady(attempt: Int) {
        if let environment = HostAppEnvironment.shared {
            installStatusItemIfNeeded(environment: environment)
            Task { @MainActor in
                await environment.startRuntimeIfNeeded()
            }
            return
        }

        guard attempt < 50 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.startRuntimeWhenReady(attempt: attempt + 1)
        }
    }

    private func installStatusItemIfNeeded(environment: HostAppEnvironment) {
        guard statusItem == nil else { return }
        self.environment = environment

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = statusImage(for: environment.sessionCoordinator.phase)
            button.image?.isTemplate = true
            button.toolTip = "Vamp Sync"
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            let dotView = VampSyncMenuBarStatusDotView()
            dotView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(dotView)
            NSLayoutConstraint.activate([
                dotView.widthAnchor.constraint(equalToConstant: 9),
                dotView.heightAnchor.constraint(equalToConstant: 9),
                dotView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
                dotView.topAnchor.constraint(equalTo: button.topAnchor, constant: 2)
            ])
            statusDotView = dotView
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: VampSyncCompanionDesign.width, height: VampSyncCompanionDesign.height)
        let controller = NSHostingController(
            rootView: VampSyncCompanionPopover(
                environment: environment,
                onClose: { [weak self] in self?.closePopover() }
            )
        )
        // Let the popover follow the SwiftUI content's own height instead of
        // staying at the fixed size above.
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        self.popover = popover

        phaseObserver = environment.sessionCoordinator.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }

        // Mini Host is menu-bar-only, so it has no dashboard window for the
        // shared trust gate to bring forward. Present the popover as soon as
        // a new client reaches the approval gate; otherwise pairing silently
        // expires while the approval card is hidden.
        trustPromptObserver = environment.$pendingTrustPrompt
            .receive(on: RunLoop.main)
            .sink { [weak self] prompt in
                self?.updateStatusItem()
                guard prompt != nil else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.showTrustPromptPopover()
                }
            }

        permissionObserver = environment.permissionsViewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.updateStatusItem()
            }
        updateStatusItem()
    }

    private func statusImage(for phase: HostSessionCoordinator.SessionPhase) -> NSImage? {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.black.setFill()
            let path = VampSyncMark().path(in: rect.insetBy(dx: 1.4, dy: 1.2))
            context.addPath(path.cgPath)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.accessibilityDescription = phase == .error ? "Vamp Sync needs attention" : "Vamp Sync"
        image.isTemplate = true
        return image
    }

    private func updateStatusItem() {
        guard let environment else { return }
        statusItem?.button?.image = statusImage(for: environment.sessionCoordinator.phase)
        statusItem?.button?.image?.isTemplate = true

        let dotState: VampSyncMenuBarStatusDotView.State
        if environment.sessionCoordinator.phase == .error {
            dotState = .problem
        } else if environment.pendingTrustPrompt != nil {
            dotState = .approval
        } else if environment.sessionCoordinator.phase == .streaming {
            dotState = .streaming
        } else {
            dotState = .none
        }
        statusDotView?.state = dotState
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        // Accessibility activation can send the action without a mouse event.
        // Only a real secondary click opens the context menu; every other
        // activation opens the same popover as a primary click.
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: sender)
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            makePopoverWindowTransparent()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Liquid Glass needs real desktop pixels behind the SwiftUI hierarchy.
    /// NSPopover otherwise supplies an opaque system background that turns every
    /// material surface into a flat gray card.
    private func makePopoverWindowTransparent() {
        guard let view = popover?.contentViewController?.view else { return }
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        guard let window = view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        // NSPopover owns one or more bezel/container views outside the hosting
        // view. Clear their layer fills too; otherwise that system gray remains
        // visible behind every SwiftUI glass surface.
        clearOpaqueLayerBackgrounds(in: window.contentView)
        DispatchQueue.main.async { [weak self] in
            self?.clearOpaqueLayerBackgrounds(in: window.contentView)
        }
    }

    private func clearOpaqueLayerBackgrounds(in view: NSView?) {
        guard let view else { return }
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.subviews.forEach { clearOpaqueLayerBackgrounds(in: $0) }
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Vamp Sync")
        addMenuItem("Open Vamp Sync", action: #selector(openPopover), to: menu)

        let status = NSMenuItem(title: "Status: \(statusMenuTitle)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        addMenuItem(isRuntimeActive ? "Stop Host" : "Start Host", action: #selector(toggleRuntime), to: menu)
        addMenuItem("Restart Host", action: #selector(restartRuntime), to: menu)
        menu.addItem(.separator())

        addMenuItem("Copy Pairing Address", action: #selector(copyPairingAddress), to: menu)
        addMenuItem("Copy Host Fingerprint", action: #selector(copyHostFingerprint), to: menu)
        menu.addItem(.separator())

        addMenuItem("Screen Recording Settings…", action: #selector(openScreenRecordingSettings), to: menu)
        addMenuItem("Accessibility Settings…", action: #selector(openAccessibilitySettings), to: menu)
        menu.addItem(.separator())

        addMenuItem("Quit Vamp Sync", action: #selector(quitApp), keyEquivalent: "q", to: menu)
        return menu
    }

    private func addMenuItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
    }

    private var isRuntimeActive: Bool {
        guard let phase = environment?.sessionCoordinator.phase else { return false }
        return phase != .idle && phase != .error
    }

    private var statusMenuTitle: String {
        guard let environment else { return "Starting" }
        if environment.pendingTrustPrompt != nil { return "Pairing approval required" }
        switch environment.sessionCoordinator.phase {
        case .streaming: return "Connected"
        case .advertising, .awaitingClient: return "Ready"
        case .error: return "Needs attention"
        case .idle: return "Stopped"
        default: return "Starting"
        }
    }

    @objc private func openPopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown != true { togglePopover(relativeTo: button) }
    }

    private func showTrustPromptPopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown != true {
            togglePopover(relativeTo: button)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleRuntime() {
        guard let environment else { return }
        Task {
            if isRuntimeActive {
                await environment.stopRuntime()
            } else {
                await environment.startRuntimeIfNeeded()
            }
        }
    }

    @objc private func restartRuntime() {
        guard let environment else { return }
        Task {
            await environment.stopRuntime()
            await environment.startRuntimeIfNeeded()
        }
    }

    @objc private func copyPairingAddress() {
        guard let address = localIPv4AddressForPairing() else { return }
        copyToPasteboard("\(address):\(RemoteDesktopConstants.defaultSignalingPort)")
    }

    @objc private func copyHostFingerprint() {
        guard let fingerprint = environment?.hostIdentity.publicKeyFingerprint else { return }
        copyToPasteboard(fingerprint)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func openScreenRecordingSettings() {
        guard let environment else { return }
        Task { await environment.permissionsViewModel.openSettings(for: .screenRecording) }
    }

    @objc private func openAccessibilitySettings() {
        guard let environment else { return }
        Task { await environment.permissionsViewModel.openSettings(for: .accessibility) }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func closePopover() {
        popover?.performClose(nil)
    }
}

private enum VampSyncAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Window with two fang notches. The same silhouette is the menu-bar template
/// and the panel mark — never the full-color landscape app icon.
private struct VampSyncMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let frame = rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.06)
        let fangHeight = rect.height * 0.16
        let window = CGRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: max(frame.height - fangHeight * 0.72, frame.height * 0.72)
        )
        let radius = min(window.width, window.height) * 0.16
        let line = max(1.55, min(window.width, window.height) * 0.11)

        path.addRoundedRect(in: window, cornerSize: CGSize(width: radius, height: radius))

        let hole = window.insetBy(dx: line, dy: line)
        let holeRadius = max(1, radius - line * 0.55)
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: holeRadius, height: holeRadius))

        let barHeight = max(1.3, line * 0.68)
        path.addRect(CGRect(x: hole.minX, y: hole.minY, width: hole.width, height: barHeight))

        let fangWidth = window.width * 0.16
        let baseY = window.maxY - line * 0.10
        for centerX in [window.midX - fangWidth * 0.72, window.midX + fangWidth * 0.72] {
            path.move(to: CGPoint(x: centerX - fangWidth * 0.5, y: baseY))
            path.addLine(to: CGPoint(x: centerX, y: baseY + fangHeight))
            path.addLine(to: CGPoint(x: centerX + fangWidth * 0.5, y: baseY))
            path.closeSubpath()
        }
        return path
    }
}

private struct VampMiniHostMark: View {
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(palette.accent.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(palette.accent.opacity(0.22), lineWidth: 0.5)
                }
            VampSyncMark()
                .fill(palette.accent, style: FillStyle(eoFill: true))
                .padding(size * 0.12)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Vamp Sync")
    }

    private var palette: VampSyncCompanionPalette { .init(colorScheme: colorScheme) }
}

private final class VampSyncMenuBarStatusDotView: NSView {
    enum State: Equatable {
        case none
        case streaming
        case approval
        case problem
    }

    var state: State = .none {
        didSet {
            isHidden = state == .none
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard state != .none, let context = NSGraphicsContext.current?.cgContext else { return }
        let dotColor: NSColor
        switch state {
        case .none: return
        case .streaming: dotColor = NSColor(calibratedRed: 0.298, green: 0.851, blue: 0.392, alpha: 1)
        case .approval: dotColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.0, alpha: 1)
        case .problem: dotColor = NSColor(calibratedRed: 1.0, green: 0.271, blue: 0.227, alpha: 1)
        }

        let ringRect = bounds.insetBy(dx: 0.4, dy: 0.4)
        NSColor.controlBackgroundColor.withAlphaComponent(0.95).setFill()
        context.fillEllipse(in: ringRect)
        dotColor.setFill()
        context.fillEllipse(in: bounds.insetBy(dx: 2.0, dy: 2.0))
    }
}

// MARK: - Assistant-style Vamp Sync surface

/// One calm host surface, matching Vamp Assistant's Remote Sessions model:
/// listener state, pairing, permissions, and trusted devices live in a single
/// scroll instead of competing status/device/access dashboards.
private enum VampSyncCompanionDesign {
    static let width: CGFloat = 420
    /// Starting size only. The popover then tracks its content — see
    /// `scrollHeight`. It used to be a hard 680pt whatever was on screen, which
    /// left a third of the panel empty whenever the host was idle.
    static let height: CGFloat = 480
    /// Below this the panel looks broken rather than compact.
    static let minScrollHeight: CGFloat = 150
    /// Above this the scroller takes over, so the popover never outgrows a
    /// laptop screen when a long device list is showing.
    static let maxScrollHeight: CGFloat = 560
    static let inset: CGFloat = 20
    static let radius: CGFloat = 18
}

/// Height of the popover's scrolling content, so the panel can size to it.
private struct VampSyncCompanionContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct VampSyncCompanionPalette {
    let colorScheme: ColorScheme

    private var dark: Bool { colorScheme == .dark }
    var background: Color { dark ? Color(red: 0.075, green: 0.075, blue: 0.085) : Color(red: 0.96, green: 0.955, blue: 0.97) }
    var surface: Color { dark ? Color.white.opacity(0.035) : Color.white.opacity(0.72) }
    var raised: Color { dark ? Color.white.opacity(0.06) : Color.white.opacity(0.92) }
    var border: Color { dark ? Color.white.opacity(0.09) : Color.black.opacity(0.075) }
    var primary: Color { dark ? Color.white.opacity(0.96) : Color.black.opacity(0.88) }
    var secondary: Color { dark ? Color.white.opacity(0.65) : Color.black.opacity(0.60) }
    var accent: Color { dark ? Color(red: 0.74, green: 0.67, blue: 1) : Color(red: 0.43, green: 0.30, blue: 0.76) }
}

private enum VampSyncCompanionState: Equatable {
    case stopped
    case starting
    case ready
    case connected(client: String)
    case streaming(application: String, client: String)
    case permissionMissing(String)
    case error(String)
}

private struct VampSyncCompanionPopover: View {
    @ObservedObject var environment: HostAppEnvironment
    @ObservedObject private var permissionsViewModel: HostPermissionsViewModel
    @ObservedObject private var sessionCoordinator: HostSessionCoordinator
    let onClose: () -> Void

    @State private var trustedPeers: [TrustedPeer] = []
    @State private var revokedPeers: [TrustedPeer] = []
    @State private var isRefreshing = false
    @State private var tailscaleInfo: TailscaleConnectionInfo?
    @State private var copiedValue: String?
    @State private var deviceManagementError: String?
    @State private var framesPerSecond: Int?
    @State private var lastFrameSampleCount: UInt64?
    @State private var lastFrameSampleAt: Date?
    @State private var contentHeight: CGFloat = 0
    @AppStorage("vampSyncAppearance") private var appearance = VampSyncAppearance.system
    @AppStorage("host.remoteUnlock.enabled") private var remoteUnlockEnabled = false

    /// The panel is as tall as what it is showing, between two bounds.
    private var scrollHeight: CGFloat {
        min(
            max(contentHeight, VampSyncCompanionDesign.minScrollHeight),
            VampSyncCompanionDesign.maxScrollHeight
        )
    }

    init(environment: HostAppEnvironment, onClose: @escaping () -> Void) {
        self.environment = environment
        self.onClose = onClose
        _permissionsViewModel = ObservedObject(wrappedValue: environment.permissionsViewModel)
        _sessionCoordinator = ObservedObject(wrappedValue: environment.sessionCoordinator)
    }

    var body: some View {
        VStack(spacing: 0) {
            VampSyncCompanionHeader(
                state: state,
                onClose: onClose
            )

            ScrollView {
                // Not lazy: there are at most five cards, and a LazyVStack only
                // reports the height of what it has already realised — which is
                // exactly the measurement this panel sizes itself from.
                VStack(alignment: .leading, spacing: 14) {
                    if let prompt = environment.pendingTrustPrompt {
                        VampSyncCompanionApprovalCard(
                            prompt: prompt,
                            onReject: { environment.resolveTrustPrompt(approved: false) },
                            onApprove: { environment.resolveTrustPrompt(approved: true) }
                        )
                    }

                    // Ready is already stated in the header. Reserve a separate
                    // card for an active stream, a transition, or needed action.
                    if state != .ready {
                        VampSyncCompanionStatusCard(
                            state: state,
                            framesPerSecond: activeFrameRate,
                            linkName: tailscaleInfo == nil ? "Private LAN" : "Tailscale",
                            onStart: start,
                            onStop: stop,
                            onRetry: restart
                        )
                    }

                    if isRuntimeActive {
                        VampSyncCompanionPairingCard(
                            pairingLink: pairingLink,
                            pairingAddress: pairingAddress,
                            fingerprint: environment.hostIdentity.publicKeyFingerprint,
                            copiedValue: copiedValue,
                            onCopy: copy
                        )
                    }

                    VampSyncCompanionAccessCard(
                        statuses: permissionsViewModel.statuses,
                        remoteUnlockEnabled: $remoteUnlockEnabled,
                        isRefreshing: permissionsViewModel.isRefreshing,
                        onRefresh: { Task { await refresh() } },
                        onOpenSettings: { kind in
                            Task { await permissionsViewModel.openSettings(for: kind) }
                        }
                    )

                    VampSyncCompanionDevicesCard(
                        trustedPeers: trustedPeers,
                        revokedPeers: revokedPeers,
                        isRefreshing: isRefreshing,
                        onRevoke: revoke,
                        onPairAgain: pairAgain
                    )
                }
                .padding(.horizontal, VampSyncCompanionDesign.inset)
                .padding(.bottom, 18)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: VampSyncCompanionContentHeight.self,
                            value: proxy.size.height
                        )
                    }
                }
            }
            .frame(height: scrollHeight)
            .onPreferenceChange(VampSyncCompanionContentHeight.self) { height in
                contentHeight = height
            }

            VampSyncCompanionFooter(
                trustedCount: trustedPeers.count,
                isRuntimeActive: isRuntimeActive,
                appearance: $appearance,
                onRefresh: { Task { await refresh() } },
                onRestart: restart,
                onToggleRuntime: isRuntimeActive ? stop : start,
                onQuit: { NSApp.terminate(nil) }
            )
        }
        .frame(width: VampSyncCompanionDesign.width)
        .background(VampSyncCompanionBackground())
        .preferredColorScheme(appearance.colorScheme)
        .task { await refresh() }
        .task { await sampleStreamingRate() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissionsViewModel.refresh(requestOSPromptIfNeeded: false) }
        }
        .onChange(of: environment.pendingTrustPrompt?.id) { _ in
            Task { await refreshPeers() }
        }
        .alert("Device update failed", isPresented: Binding(
            get: { deviceManagementError != nil },
            set: { if !$0 { deviceManagementError = nil } }
        )) {
            Button("OK", role: .cancel) { deviceManagementError = nil }
        } message: {
            Text(deviceManagementError ?? "Please try again.")
        }
    }

    private var state: VampSyncCompanionState {
        if sessionCoordinator.phase == .error {
            return .error(sessionCoordinator.errorMessage ?? "Vamp Sync could not start.")
        }
        if let application = sessionCoordinator.activeApplicationName {
            return .streaming(
                application: application,
                client: sessionCoordinator.connectedClientName ?? "Vamp Stream"
            )
        }
        if sessionCoordinator.phase == .streaming {
            return .connected(client: sessionCoordinator.connectedClientName ?? "Vamp Stream")
        }
        if let blocker = permissionsViewModel.blockers.first {
            return .permissionMissing(blocker.title)
        }
        switch sessionCoordinator.phase {
        case .idle: return .stopped
        case .advertising, .awaitingClient: return .ready
        default: return .starting
        }
    }

    private var isRuntimeActive: Bool {
        sessionCoordinator.phase != .idle && sessionCoordinator.phase != .error
    }

    private var pairingAddress: String? {
        guard isRuntimeActive else { return nil }
        if let local = localIPv4AddressForPairing() {
            return "\(local):\(RemoteDesktopConstants.defaultSignalingPort)"
        }
        return tailscaleInfo?.connectAddress
    }

    private var pairingLink: String? {
        guard let pairingAddress else { return nil }
        return VampHostPairingLink.make(
            address: pairingAddress,
            displayName: environment.hostIdentity.displayName
        )
    }

    private var activeFrameRate: Int? {
        guard sessionCoordinator.activeApplicationName != nil else { return nil }
        return framesPerSecond
    }

    private func start() {
        Task { await environment.startRuntimeIfNeeded() }
    }

    private func stop() {
        Task { await environment.stopRuntime() }
    }

    private func restart() {
        Task {
            await environment.stopRuntime()
            await environment.startRuntimeIfNeeded()
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedValue = value
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedValue == value { copiedValue = nil }
        }
    }

    private func refresh() async {
        await permissionsViewModel.refresh(requestOSPromptIfNeeded: false)
        await refreshPeers()
        let snapshot = await Task.detached(priority: .utility) {
            getTailscaleDetectionSnapshot()
        }.value
        guard !Task.isCancelled else { return }
        tailscaleInfo = snapshot.info
        await environment.discoveryAdvertiserViewModel.updateTailscaleIdentity(
            hostname: snapshot.info?.dnsName,
            ip: snapshot.info?.ipAddress
        )
    }

    private func refreshPeers() async {
        isRefreshing = true
        defer { isRefreshing = false }
        if let store = environment.trustedPeerStore as? PersistentTrustedPeerStore,
           let peers = try? await store.allPeers() {
            trustedPeers = peers.filter { !$0.isRevoked }
            revokedPeers = peers.filter(\.isRevoked)
        } else {
            trustedPeers = (try? await environment.trustedPeerStore.trustedPeers()) ?? []
            revokedPeers = []
        }
    }

    private func revoke(_ peer: TrustedPeer) {
        Task {
            do {
                try await sessionCoordinator.revokePeer(peer, store: environment.trustedPeerStore)
                await refreshPeers()
            } catch {
                deviceManagementError = "Could not revoke this device: \(error.localizedDescription)"
            }
        }
    }

    private func pairAgain(_ peer: TrustedPeer) {
        Task {
            guard let store = environment.trustedPeerStore as? PersistentTrustedPeerStore else { return }
            do {
                try await store.removePeer(id: peer.id)
                await refreshPeers()
            } catch {
                deviceManagementError = "Could not reset this device for pairing: \(error.localizedDescription)"
            }
        }
    }

    private func sampleStreamingRate() async {
        while !Task.isCancelled {
            let count = environment.streamingCoordinator.streamDiagnostics.framesSent
            let now = Date()
            if let previousCount = lastFrameSampleCount, let previousDate = lastFrameSampleAt {
                let elapsed = max(now.timeIntervalSince(previousDate), 0.1)
                let delta = count >= previousCount ? count - previousCount : 0
                framesPerSecond = max(0, Int((Double(delta) / elapsed).rounded()))
            }
            lastFrameSampleCount = count
            lastFrameSampleAt = now
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

private struct VampSyncCompanionBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { proxy in
            Image("SyncBackdrop")
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay {
                    if reduceTransparency {
                        Color(nsColor: .windowBackgroundColor)
                    } else {
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [.black.opacity(contrast == .increased ? 0.78 : 0.52),
                                   .black.opacity(contrast == .increased ? 0.88 : 0.68)]
                                : [.white.opacity(contrast == .increased ? 0.96 : 0.88),
                                   .white.opacity(contrast == .increased ? 0.98 : 0.94)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct VampSyncCompanionHeader: View {
    let state: VampSyncCompanionState
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            VampMiniHostMark(size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Vamp Sync")
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.5)
                Text("For Control and Stream")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close Vamp Sync")
        }
        .padding(.horizontal, VampSyncCompanionDesign.inset)
        .padding(.top, 22)
        .padding(.bottom, 20)
    }

    private var palette: VampSyncCompanionPalette { .init(colorScheme: colorScheme) }

    private var statusLabel: String {
        switch state {
        case .stopped: "Offline"
        case .starting: "Starting"
        case .ready: "Ready"
        case .connected: "Connected"
        case .streaming: "Live"
        case .permissionMissing, .error: "Setup needed"
        }
    }

    private var statusColor: Color {
        switch state {
        case .ready, .connected, .streaming: .green
        case .permissionMissing, .error: .orange
        case .stopped, .starting: .secondary
        }
    }
}

private struct VampSyncCompanionStatusCard: View {
    let state: VampSyncCompanionState
    let framesPerSecond: Int?
    let linkName: String
    let onStart: () -> Void
    let onStop: () -> Void
    let onRetry: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VampSyncCompanionSurface(raised: true) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 42, height: 42)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    action
                }

                if case .streaming = state {
                    Divider().overlay(palette.border)
                    HStack {
                        VampSyncCompanionMetric(label: "FRAME", value: framesPerSecond.map { "\($0) fps" } ?? "—")
                        VampSyncCompanionMetric(label: "STREAM", value: "App window")
                        VampSyncCompanionMetric(label: "LINK", value: linkName)
                    }
                }
            }
        }
    }

    private var palette: VampSyncCompanionPalette { .init(colorScheme: colorScheme) }

    private var title: String {
        switch state {
        case .stopped: "App Stream host is off"
        case .starting: "Starting secure host…"
        case .ready: "Ready to connect"
        case .connected(let client): "\(client) is connected"
        case .streaming(let application, _): "Streaming \(application)"
        case .permissionMissing(let permission): "\(permission) is required"
        case .error: "Vamp Sync needs attention"
        }
    }

    private var detail: String {
        switch state {
        case .stopped: "Pairing and private transport are offline."
        case .starting: "Preparing signed discovery and authenticated transport."
        case .ready: "Pair Control or Stream, then choose a Mac app."
        case .connected: "Choose a Mac app in Control or Stream to begin."
        case .streaming(_, let client): "Only the selected app window is visible to \(client)."
        case .permissionMissing: "Grant access in System Settings, then re-check."
        case .error(let message): message
        }
    }

    private var icon: String {
        switch state {
        case .stopped: "power"
        case .starting: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.seal.fill"
        case .connected: "iphone.and.arrow.forward"
        case .streaming: "macwindow.on.rectangle"
        case .permissionMissing: "lock.trianglebadge.exclamationmark"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .ready, .connected, .streaming: .green
        case .permissionMissing, .error: .orange
        case .stopped, .starting: palette.secondary
        }
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .stopped:
            Button("Start", action: onStart).buttonStyle(.borderedProminent)
        case .error:
            Button("Retry", action: onRetry).buttonStyle(.borderedProminent)
        case .starting:
            ProgressView().controlSize(.small)
        default:
            Button("Stop", action: onStop).buttonStyle(.bordered)
        }
    }
}

private struct VampSyncCompanionMetric: View {
    let label: String
    let value: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9, weight: .medium)).tracking(1.2)
                .foregroundStyle(palette.secondary)
            Text(value).font(.caption.weight(.semibold).monospacedDigit()).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var palette: VampSyncCompanionPalette { .init(colorScheme: colorScheme) }
}

private struct VampSyncCompanionApprovalCard: View {
    let prompt: HostAppEnvironment.TrustPrompt
    let onReject: () -> Void
    let onApprove: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VampSyncCompanionSurface(raised: true, tint: .orange) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Verify \(prompt.displayName)", systemImage: "person.badge.key.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Compare this complete fingerprint with the one shown on the device through a separate trusted channel.")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(vampSyncFormattedFingerprint(prompt.fingerprint))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Device fingerprint")
                    .accessibilityValue(prompt.fingerprint)
                HStack {
                    Button("Reject", role: .destructive, action: onReject).buttonStyle(.bordered)
                    Spacer()
                    Button("Codes match — approve", action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var palette: VampSyncCompanionPalette { .init(colorScheme: colorScheme) }
}

private struct VampSyncCompanionPairingCard: View {
    let pairingLink: String?
    let pairingAddress: String?
    let fingerprint: String
    let copiedValue: String?
    let onCopy: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VampSyncCompanionSurface(raised: true) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 18) {
                    if let pairingLink {
                        HostBrowserPairingQRCode(
                            pairingURL: pairingLink,
                            accessibilityLabel: "QR code for Vamp Stream pairing",
                            size: 116
                        )
                    } else {
                        ProgressView().frame(width: 116, height: 116)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Make the connection")
                            .font(.system(size: 17, weight: .semibold))
                            .tracking(-0.35)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Scan with Stream, or discover this Mac in Control.")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let pairingLink {
                            Button {
                                onCopy(pairingLink)
                            } label: {
                                Label(copiedValue == pairingLink ? "Copied" : "Copy pairing link",
                                      systemImage: copiedValue == pairingLink ? "checkmark" : "link")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let pairingAddress {
                    HStack(spacing: 8) {
                        Image(systemName: "network")
                            .foregroundStyle(palette.secondary)
                        Text(pairingAddress)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Text("Private")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.secondary)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 9))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Host fingerprint")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.secondary)
                        Spacer()
                        Button {
                            onCopy(fingerprint)
                        } label: {
                            Image(systemName: copiedValue == fingerprint ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy host fingerprint")
                    }
                    Text(vampSyncFormattedFingerprint(fingerprint))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineSpacing(4)
                        .foregroundStyle(palette.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Host fingerprint")
                        .accessibilityValue(fingerprint)
                    Text("Every new device needs your approval.")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondary)
                }
            }
        }
    }

    private var palette: VampSyncCompanionPalette { .init(colorScheme: colorScheme) }
}

private struct VampSyncCompanionAccessCard: View {
    let statuses: [FriendlyPermissionStatus]
    @Binding var remoteUnlockEnabled: Bool
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onOpenSettings: (PermissionKind) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VampSyncCompanionSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Mac access").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(action: onRefresh) {
                        Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Refresh permission status")
                }
                ForEach(statuses, id: \.kind) { status in
                    VampSyncCompanionPermissionRow(
                        title: status.title,
                        state: status.authorizationState,
                        onSettings: { onOpenSettings(status.kind) }
                    )
                    .help(status.kind == .screenRecording
                          ? "Shares the selected app window."
                          : "Allows touch and keyboard control from your paired device.")
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Remote Unlock", isOn: $remoteUnlockEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 12, weight: .medium))
                    Text("Let a paired device unlock this Mac with your login password. Passwords are never stored.")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var palette: VampSyncCompanionPalette { .init(colorScheme: colorScheme) }
}

private struct VampSyncCompanionPermissionRow: View {
    let title: String
    let state: PermissionAuthorizationState
    let onSettings: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(state == .granted ? .green : .orange)
            Text(title).font(.system(size: 12))
            Spacer()
            if state == .granted {
                Text("Allowed").font(.system(size: 11)).foregroundStyle(palette.secondary)
            } else {
                Button("Open Settings", action: onSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    private var palette: VampSyncCompanionPalette { .init(colorScheme: colorScheme) }
}

private struct VampSyncCompanionDevicesCard: View {
    let trustedPeers: [TrustedPeer]
    let revokedPeers: [TrustedPeer]
    let isRefreshing: Bool
    let onRevoke: (TrustedPeer) -> Void
    let onPairAgain: (TrustedPeer) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VampSyncCompanionSurface {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("Trusted devices").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if isRefreshing { ProgressView().controlSize(.small) }
                    Text("\(trustedPeers.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(palette.secondary)
                }
                if trustedPeers.isEmpty {
                    Text("Your devices will appear here after pairing.")
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                } else {
                    ForEach(trustedPeers) { peer in
                        VampSyncCompanionDeviceRow(
                            peer: peer,
                            actionTitle: "Revoke",
                            isDestructive: true,
                            action: { onRevoke(peer) }
                        )
                    }
                }
                if !revokedPeers.isEmpty {
                    Divider().overlay(palette.border)
                    Text("REVOKED").font(.caption2.weight(.semibold)).foregroundStyle(palette.secondary)
                    ForEach(revokedPeers) { peer in
                        VampSyncCompanionDeviceRow(
                            peer: peer,
                            actionTitle: "Pair again",
                            isDestructive: false,
                            action: { onPairAgain(peer) }
                        )
                    }
                }
            }
        }
    }

    private var palette: VampSyncCompanionPalette { .init(colorScheme: colorScheme) }
}

private struct VampSyncCompanionDeviceRow: View {
    let peer: TrustedPeer
    let actionTitle: String
    let isDestructive: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isDestructive ? "iphone" : "iphone.slash")
                .frame(width: 28, height: 28)
                .background(palette.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(peer.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                Text(peer.fingerprint)
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(actionTitle, role: isDestructive ? .destructive : nil, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var palette: VampSyncCompanionPalette { .init(colorScheme: colorScheme) }
}

private struct VampSyncCompanionFooter: View {
    let trustedCount: Int
    let isRuntimeActive: Bool
    @Binding var appearance: VampSyncAppearance
    let onRefresh: () -> Void
    let onRestart: () -> Void
    let onToggleRuntime: () -> Void
    let onQuit: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Label("Private connection", systemImage: "lock.shield")
                .font(.system(size: 10))
                .foregroundStyle(palette.secondary)
                .help(buildLabel)
            Spacer()
            Button(isRuntimeActive ? "Stop host" : "Start host", action: onToggleRuntime)
                .font(.system(size: 11))
                .buttonStyle(.borderless)
            Menu {
                Button("Refresh status", action: onRefresh)
                Button("Restart host", action: onRestart)
                Divider()
                ForEach(VampSyncAppearance.allCases) { option in
                    Button { appearance = option } label: {
                        Label(option.title, systemImage: option.systemImage)
                    }
                }
                Divider()
                Button("Quit Vamp Sync", action: onQuit)
            } label: {
                Image(systemName: "gearshape").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Vamp Sync settings")
        }
        .padding(.horizontal, VampSyncCompanionDesign.inset)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 0.5) }
    }

    private var palette: VampSyncCompanionPalette { .init(colorScheme: colorScheme) }

    private var buildLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "v\(version) · build \(build) · \(trustedCount) trusted"
    }
}

private struct VampSyncCompanionSurface<Content: View>: View {
    let raised: Bool
    let tint: Color?
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        raised: Bool = false,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.raised = raised
        self.tint = tint
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: VampSyncCompanionDesign.radius, style: .continuous)
    }

    var body: some View {
        content
            .padding(18)
            .background {
                GeometryReader { proxy in
                    surface
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                shape.strokeBorder(tint?.opacity(0.32) ?? palette.border, lineWidth: 0.65)
                    .allowsHitTesting(false)
            }
    }

    @ViewBuilder private var surface: some View {
        if reduceTransparency {
            shape.fill(Color(nsColor: raised ? .controlBackgroundColor : .windowBackgroundColor))
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.tint(tint?.opacity(0.08)), in: shape)
            } else {
                shape.fill(.thinMaterial)
            }
            #else
            shape.fill(.thinMaterial)
            #endif
        }
    }

    private var palette: VampSyncCompanionPalette { .init(colorScheme: colorScheme) }
}

/// Visual grouping only: copying and verification retain the complete original.
private func vampSyncFormattedFingerprint(_ fingerprint: String) -> String {
    let characters = Array(fingerprint)
    let groups = stride(from: 0, to: characters.count, by: 8).map { offset in
        String(characters[offset..<min(offset + 8, characters.count)])
    }
    return stride(from: 0, to: groups.count, by: 4).map { offset in
        groups[offset..<min(offset + 4, groups.count)].joined(separator: " ")
    }.joined(separator: "\n")
}

/// First non-loopback IPv4 address, preferring Wi-Fi and Ethernet interfaces.
private func localIPv4AddressForPairing() -> String? {
    var fallback: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        guard let socketAddress = ptr.pointee.ifa_addr else { continue }
        guard socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
        let interfaceName = String(cString: ptr.pointee.ifa_name)
        guard interfaceName != "lo0" else { continue }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(socketAddress.pointee.sa_len)
        guard getnameinfo(socketAddress, length, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 else {
            continue
        }
        let address = String(cString: hostname)
        if interfaceName.hasPrefix("en") { return address }
        if fallback == nil { fallback = address }
    }
    return fallback
}
#endif
