import Combine
import CoreGraphics
import SwiftUI
import SharedModels
import SharedUtilities

#if canImport(UIKit)
import UIKit

/// Full-screen Vamp Assistant desktop-control surface.
///
/// The default initializer preserves the original whole-display Remote Control experience.
/// The separate Assistant App Stream destination supplies a window ID and an app-picker action;
/// the picker itself is never embedded into the original remote-control screen.
struct BeetCodeRemoteView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Assistant streams are requested by resolution, but the user is choosing an outcome.
    /// The labels say what they get; the resolution stays visible as secondary detail so a
    /// user who does think in pixels is not deprived of it.
    private enum StreamResolution: String, CaseIterable, Identifiable {
        // Listed best-first so the picker reads in the same direction as the Sync path's.
        // Raw values are the stored keys and are deliberately unchanged.
        case native
        case p1080 = "1080p"
        case p720 = "720p"
        case p480 = "480p"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .native: return "Sharper text (Native)"
            case .p1080: return "Balanced (1080p)"
            case .p720: return "Lower bandwidth (720p)"
            case .p480: return "Minimum bandwidth (480p)"
            }
        }
    }

    let session: BeetCodeRemoteSessionViewModel.Session
    let windowID: UInt32?
    let streamTitle: String?
    let isTerminalApplication: Bool
    let streamGeometryRevision: String
    let onClose: () -> Void
    let onRefresh: () async -> String?
    let onChooseApplication: (() -> Void)?
    /// The size of the area the video is actually laid out in. It is larger than the enclosing
    /// safe-area frame (this surface ignores the bottom and horizontal insets), and it is the
    /// geometry the input mapper uses — so it is the only aspect the Mac should be fitted to.
    let onViewportSize: ((CGSize) -> Void)?

    let inputSuspended: Bool
    let sizingNotice: String?
    let onAdaptiveSizing: (() -> Void)?
    let onOriginalSizing: (() -> Void)?
    @State private var videoHealthCheckTime = ProcessInfo.processInfo.systemUptime
    @State private var videoStartedAt = ProcessInfo.processInfo.systemUptime
    @StateObject private var cursorModel = LocalCursorModel()
    @State private var startedStreamTaskID: String?
    @StateObject private var renderer: BeetCodeVideoRendererViewModel
    @StateObject private var input: BeetCodeRemoteInputController
    @State private var keyboardActive = false
    @State private var adjustsViewport = false
    @State private var viewportZoom: CGFloat = 1
    @State private var viewportOffset: CGSize = .zero
    @State private var viewportSize: CGSize = .zero
    @State private var isRefreshing = false
    @State private var refreshError: String?
    @State private var selectedDisplayID: UInt32?
    @State private var showsGestureHelp = false
    @State private var controlsHidden = false
    @StateObject private var annotationStore = AnnotationOverlayStore()
    @AppStorage("vampstream.assistant.resolution") private var resolution = StreamResolution.native.rawValue
    @State private var fillScreen = false
    @StateObject private var bluetoothInput = BluetoothInputController()
    @State private var showsBluetoothStatus = false
    /// Shared with the Sync path on purpose: the gestures are identical, so the one-time
    /// introduction should appear on a user's first stream whichever kind of Mac it came from,
    /// and never twice. Only the Sync path used to show it at all.
    @AppStorage("vampstream.didShowGestureHelp") private var didShowGestureHelp = false

    /// Cursorless capture contract (mirrors MacAssistantRemoteView's `usesLocalCursor`):
    /// only a host that advertises `supportsCursorlessCapture` omits its cursor from the
    /// frames. Requesting `cursor=0` from a host that ignores the parameter leaves the
    /// real pointer in the video while the local overlay would draw a second one, so
    /// both the request and the overlay are gated on this flag.
    private var usesLocalCursor: Bool {
        session.status.supportsCursorlessCapture == true
    }

    init(
        session: BeetCodeRemoteSessionViewModel.Session,
        windowID: UInt32? = nil,
        streamTitle: String? = nil,
        isTerminalApplication: Bool = false,
        streamGeometryRevision: String = "",
        onClose: @escaping () -> Void,
        onRefresh: @escaping () async -> String?,
        onChooseApplication: (() -> Void)? = nil,
        onViewportSize: ((CGSize) -> Void)? = nil,
        inputSuspended: Bool = false,
        sizingNotice: String? = nil,
        onAdaptiveSizing: (() -> Void)? = nil,
        onOriginalSizing: (() -> Void)? = nil
    ) {
        self.session = session
        self.windowID = windowID
        self.streamTitle = streamTitle
        self.isTerminalApplication = isTerminalApplication
        self.streamGeometryRevision = streamGeometryRevision
        self.onClose = onClose
        self.onRefresh = onRefresh
        self.onChooseApplication = onChooseApplication
        self.onViewportSize = onViewportSize
        self.inputSuspended = inputSuspended
        self.sizingNotice = sizingNotice
        self.onAdaptiveSizing = onAdaptiveSizing
        self.onOriginalSizing = onOriginalSizing
        _renderer = StateObject(wrappedValue: BeetCodeVideoRendererViewModel())
        _input = StateObject(wrappedValue: BeetCodeRemoteInputController(client: session.client))
    }

    var body: some View {
        Group {
            if session.status.ready {
                streamSurface
            } else if session.status.shouldOfferRemoteUnlock {
                BeetCodeRemoteUnlockStateView(
                    message: session.status.remoteUnlockMessage,
                    client: session.client,
                    onRefresh: onRefresh,
                    onClose: onClose
                )
            } else {
                permissionState
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: streamTaskID) {
            guard session.status.ready, scenePhase == .active else { return }
            input.isEnabled = false
            input.stop()
            renderer.start(
                client: session.client,
                resolution: resolution,
                displayID: windowID == nil ? selectedDisplayID : nil,
                windowID: windowID,
                showsCursor: !usesLocalCursor)
            startedStreamTaskID = streamTaskID
        }
        .onChangeCompat(of: canInteract) { enabled in input.isEnabled = enabled }
        .task {
            // Same shared GCMouse/GCKeyboard bridge the Sync path uses, so one paired mouse
            // behaves identically on either kind of Mac.
            bluetoothInput.sink = input
            bluetoothInput.startObserving()
        }
        .onChangeCompat(of: canInteract) { enabled in
            guard enabled, windowID != nil, !didShowGestureHelp else { return }
            didShowGestureHelp = true
            showsGestureHelp = true
        }
        .onChangeCompat(of: bluetoothInput.mouseSensitivity) { newValue in
            input.pointerSensitivity = newValue
        }
        .task(id: streamTaskID) {
            videoStartedAt = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                videoHealthCheckTime = ProcessInfo.processInfo.systemUptime
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
        .onChangeCompat(of: scenePhase) { phase in
            if phase == .active, session.status.ready {
                renderer.start(
                    client: session.client,
                    resolution: resolution,
                    displayID: windowID == nil ? selectedDisplayID : nil,
                    windowID: windowID,
                    showsCursor: !usesLocalCursor)
            } else {
                renderer.stop()
                input.stop()
            }
        }
        .onDisappear {
            renderer.stop()
            input.stop()
            // Detach the shared bridge so a paired mouse cannot keep driving a session this
            // view no longer owns, and so re-entering does not double-subscribe.
            bluetoothInput.stopObserving()
        }
        .sheet(isPresented: $showsBluetoothStatus) {
            BluetoothInputStatusView(controller: bluetoothInput) { showsBluetoothStatus = false }
        }
    }

    private var videoStalled: Bool {
        AppStreamVideoHealth.isStalled(lastDecodedAt: renderer.lastDecodedAt, now: videoHealthCheckTime)
    }

    private var canInteract: Bool {
        startedStreamTaskID == streamTaskID
            && !inputSuspended && !videoStalled && scenePhase == .active && session.status.ready
            && renderer.isReceiving && renderer.latestPixelBuffer != nil
    }

    private var streamTaskID: String {
        "\(session.address)-\(session.status.ready)-\(usesLocalCursor)-\(windowID ?? 0)-\(selectedDisplayID ?? 0)-\(resolution)-\(streamGeometryRevision)"
    }

    private var permissionState: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.white.opacity(0.92))
            Text("Mac Control is not ready")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(permissionMessage)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Text("On the Mac, open Vamp Assistant → Settings → Permissions. Vamp Stream cannot grant these permissions remotely.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.56))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            if let refreshError {
                Text(refreshError)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
            }
            Button {
                Task {
                    isRefreshing = true
                    refreshError = await onRefresh()
                    isRefreshing = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isRefreshing { ProgressView().tint(.white) }
                    Text(isRefreshing ? "Checking…" : "Check again")
                }
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(isRefreshing)
            .accessibilityLabel(isRefreshing ? "Checking Vamp Assistant permissions" : "Check Vamp Assistant permissions again")
            Button("Back", action: onClose)
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .padding(.top, 6)
                .accessibilityHint("Return to the host picker")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionMessage: String {
        if !session.status.enabled { return "Mac Control is turned off in Vamp Assistant." }
        if !session.status.screenRecording { return "Screen Recording permission is required to receive the Mac display." }
        if !session.status.accessibility { return "Accessibility permission is required to send pointer and keyboard input." }
        return session.status.message ?? "Vamp Assistant is still preparing Mac Control."
    }

    private var streamSurface: some View {
        VStack(spacing: 0) {
            if onChooseApplication != nil, !controlsHidden {
                // This must occupy layout space. Overlaying it hides the first rows of a
                // tall Mac window and also reports an oversized viewport back to the Mac.
                appStreamTopBar
                    .background(Color.black)
            }

            GeometryReader { proxy in
                // The deck floats over the bottom of the surface, so the picture must stop
                // above it — exactly as Vamp Sync lays out an app window. The Mac is asked
                // for the unobstructed area's shape, never the full screen's, so the app's
                // own bottom toolbar can never end up underneath the deck.
                let videoArea = videoViewport(
                    in: proxy.size, safeAreaBottom: proxy.safeAreaInsets.bottom)
                let placement = picturePlacement(in: videoArea)
                let picture = CGSize(width: placement.size.width, height: placement.size.height)
                ZStack(alignment: .top) {
                    Color.black

                    if renderer.latestPixelBuffer != nil {
                        VideoFrameRendererView(
                            pixelBuffer: renderer.latestPixelBuffer,
                            displayMode: fillScreen ? .fillScreen : .fitDisplay)
                            .scaleEffect(viewportZoom, anchor: .center)
                            .offset(viewportOffset)
                            .frame(width: picture.width, height: picture.height)
                            .frame(width: videoArea.width, height: videoArea.height, alignment: .top)

                        AppStreamGestureView(
                        allowsViewportAdjustment: adjustsViewport,
                            viewportZoom: viewportZoom,
                            viewportOffset: viewportOffset,
                            viewSize: picture,
                            onTap: { cursorModel.place(at: $0); input.tap(at: $0) },
                            onDoubleTap: { cursorModel.place(at: $0); input.doubleTap(at: $0) },
                            onRightClick: { cursorModel.place(at: $0); input.rightClick(at: $0) },
                            onMiddleClick: { cursorModel.place(at: $0); input.middleClick(at: $0) },
                            onPointerMove: { cursorModel.place(at: $0); input.pointerMoved(at: $0) },
                            onPointerEnded: { input.pointerEnded() },
                            onScroll: { input.scroll(deltaX: $0, deltaY: $1) },
                            onViewportPan: { delta in
                                viewportOffset = clampedViewportOffset(
                                    CGSize(width: viewportOffset.width + delta.width,
                                           height: viewportOffset.height + delta.height),
                                    zoom: viewportZoom,
                                    in: picture
                                )
                            },
                            onPinchChanged: { scale, focalPoint in
                                updateViewportZoom(scale: scale, focalPoint: focalPoint, in: picture)
                            },
                            onPinchEnded: {
                                if viewportZoom < defaultViewportZoom * 1.15 {
                                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                                        resetViewportZoom()
                                    }
                                }
                            },
                            onLongPress: { cursorModel.place(at: $0); input.toggleDragLock(at: $0) },
                            onLongPressEnded: { if input.dragLocked { input.toggleDragLockCurrentPointer() } },
                            onHoverDelta: { dx, dy in
                                input.relativePointerMove(deltaX: dx, deltaY: dy)
                                if let scale = input.cursorViewPointsPerDesktopPoint {
                                    cursorModel.moveRelative(dx: dx, dy: dy, viewPointsPerDesktopPoint: scale)
                                }
                            }
                        )
                        .frame(width: picture.width, height: picture.height)
                        .overlay {
                            // Cursorless capture: the host omits the macOS cursor from the
                            // frames (only negotiated hosts — see usesLocalCursor), so the
                            // pointer is drawn here at the touch/mouse positions the input
                            // controller maps — zero-round-trip hover feedback. The overlay
                            // carries the viewport's zoom/pan so it stays glued to the video
                            // under magnify.
                            if usesLocalCursor {
                                LocalCursorOverlay(cursor: cursorModel, contentZoom: viewportZoom)
                                    .scaleEffect(viewportZoom, anchor: .center)
                                    .offset(viewportOffset)
                            }
                        }
                        .allowsHitTesting(!keyboardActive && !annotationStore.isVisible && canInteract)
                        // Placement last: a covered picture is exactly as tall as the
                        // surface, so it cannot creep under the deck that sits at that edge.
                        .frame(width: videoArea.width, height: videoArea.height, alignment: .top)

                        if annotationStore.isVisible {
                            AnnotationCanvasOverlay(store: annotationStore)
                        }
                    } else {
                        VStack(spacing: 12) {
                            if let error = renderer.lastError {
                                Image(systemName: "wifi.exclamationmark")
                                    .font(.system(size: 34, weight: .light))
                                Text("Vamp Assistant stream stopped")
                                    .font(.headline)
                                Text(error)
                                    .font(.footnote)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.white.opacity(0.72))
                                Button("Reconnect") {
                                    renderer.start(
                                        client: session.client,
                                        resolution: resolution,
                                        displayID: windowID == nil ? selectedDisplayID : nil,
                                        windowID: windowID,
                                        showsCursor: !usesLocalCursor)
                                }
                                .buttonStyle(.bordered)
                                .tint(.white)
                            } else {
                                ProgressView().tint(.white)
                                Text("Opening \(session.displayName)…")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.84))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(28)
                    }

                    if let inputError = input.lastError {
                        Text(inputError)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.red.opacity(0.82), in: Capsule())
                            .padding(.horizontal, 18)
                            .padding(.bottom, 86)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .accessibilityLabel("Input error: \(inputError)")
                    }
                }
                .overlay(alignment: .top) {
                    if AppStreamVideoHealth.needsRecovery(lastDecodedAt: renderer.lastDecodedAt,
                        startedAt: videoStartedAt, now: videoHealthCheckTime), renderer.lastError == nil {
                        AppStreamVideoRecoveryBar { restartStream() }
                            .padding(AppSpacing.sm)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let notice = sizingNotice, !notice.isEmpty, !keyboardActive {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, AppSpacing.sm)
                            .padding(.vertical, AppSpacing.xs)
                            .background(
                                .regularMaterial,
                                in: RoundedRectangle(cornerRadius: PR.r8, style: .continuous))
                            .padding(.horizontal, AppSpacing.md)
                            // Derived from the deck so it follows the deck's height.
                            .padding(
                                .bottom,
                                AppStreamChromePill<EmptyView>.reservedBand(safeAreaBottom: 0) + AppSpacing.xs)
                            .allowsHitTesting(false)
                            .accessibilityLabel("Stream notice: \(notice)")
                    }
                }
                .overlay(alignment: .bottom) {
                    classicBottomChrome(bottomInset: proxy.safeAreaInsets.bottom)
                }
                .overlay(alignment: .bottom) {
                    if keyboardActive {
                        AppStreamKeyboardOverlayView(
                            mode: isTerminalApplication ? .terminal : .standard,
                            onText: { input.sendText($0) },
                            onKey: { keyCode, modifiers in
                                input.sendKey(keyName(for: keyCode), modifiers: modifierNames(for: modifiers))
                            },
                            onDismiss: { keyboardActive = false }
                        )
                        .allowsHitTesting(canInteract)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .onAppear {
                    configureInput(viewSize: picture)
                    onViewportSize?(videoArea)
                }
                .onChangeCompat(of: proxy.size) { newSize in
                    let area = videoViewport(
                        in: newSize, safeAreaBottom: proxy.safeAreaInsets.bottom)
                    let fitted = picturePlacement(in: area).size
                    let fittedSize = CGSize(width: fitted.width, height: fitted.height)
                    configureInput(viewSize: fittedSize)
                    viewportOffset = clampedViewportOffset(viewportOffset, zoom: viewportZoom, in: fittedSize)
                    if !keyboardActive { onViewportSize?(area) }
                }
                .onChangeCompat(of: renderer.geometry) { geometry in
                    configureInput(viewSize: picture)
                    if geometry != nil {
                        viewportOffset = clampedViewportOffset(viewportOffset, zoom: viewportZoom, in: picture)
                    }

                }
            }
        }
        .background(Color.black)
        // `.container` only, so the keyboard region is respected: the deck rides above the
        // system keyboard once instead of being shifted a second time by hand.
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
    }

    private var appStreamTopBar: some View {
        HStack(spacing: 10) {
            Button(action: { onChooseApplication?() }) {
                Label("Apps", systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to apps")

            Spacer()

            Text(adjustsViewport ? "Adjust view" : (streamTitle ?? "Mac app"))
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .lineLimit(1)

            Spacer()

            Button {
                if input.dragLocked { input.toggleDragLockCurrentPointer() }
                adjustsViewport.toggle()
            } label: {
                Image(systemName: adjustsViewport ? "checkmark" : "viewfinder")
                    .frame(minWidth: 44, minHeight: 44)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .accessibilityLabel(adjustsViewport ? "Done adjusting" : "Adjust view")
            .accessibilityHint("Switch between controlling the Mac and moving or zooming the picture")
            Menu {
                Section("View on this device") {
                    Button("Fit window", systemImage: "arrow.down.right.and.arrow.up.left") {
                        if input.dragLocked { input.toggleDragLockCurrentPointer() }
                        resetViewportZoom()
                        adjustsViewport = false
                    }
                    Button("Larger text (2×)", systemImage: "plus.magnifyingglass") {
                        if input.dragLocked { input.toggleDragLockCurrentPointer() }
                        viewportZoom = 2
                        viewportOffset = .zero
                        adjustsViewport = true
                    }
                }
                if onAdaptiveSizing != nil {
                    Section("Mac window") {
                        Button("Adaptive resize") { onAdaptiveSizing?() }
                        // Was "Original proportions" here and "Original Size" on the Sync
                        // path — the same action under two names.
                        Button("Original Size") { onOriginalSizing?() }
                    }
                }
                // Named for the outcome, like the Sync path's picker, with the resolution
                // kept as secondary detail so nothing is lost. "Resolution" asked the user
                // to reason about pixels; every other quality control in the app does not.
                Picker("Picture quality", selection: $resolution) {
                    ForEach(StreamResolution.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                Button("Gesture help", systemImage: "hand.draw") { showsGestureHelp = true }
                if bluetoothInput.isMouseConnected || bluetoothInput.isKeyboardConnected {
                    Button("Bluetooth input", systemImage: "mouse") { showsBluetoothStatus = true }
                }
                if input.dragLocked {
                    Button("Release drag lock", systemImage: "lock.open") { input.toggleDragLockCurrentPointer() }
                }
                // The Sync path has always offered a manual restart; here the only way to
                // recover a stuttering stream was to wait for the automatic recovery bar to
                // decide the video had stalled, or to leave and reopen the app.
                Button("Refresh video", systemImage: "arrow.clockwise") { restartStream() }
            } label: {
                Image(systemName: input.dragLocked ? "lock.fill" : "ellipsis.circle")
                    .frame(
                        minWidth: AppHostMetrics.iconControlTarget,
                        minHeight: AppHostMetrics.iconControlTarget)
            }
            .accessibilityLabel(input.dragLocked ? "Stream options, drag lock on" : "Stream options")
            .sheet(isPresented: $showsGestureHelp) { AppStreamGestureHelpView() }
            if viewportZoom > defaultViewportZoom + 0.05 || viewportOffset != .zero {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                        resetViewportZoom()
                    }
                } label: {
                    Text("1×")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset zoom")
                .accessibilityValue("Currently zoomed to \(Int(viewportZoom * 100)) percent")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// The bottom control deck, drawn with the *shared* `AppStreamChromePill` components.
    ///
    /// This used to be a hand-rolled copy of that deck, and the two had already drifted: a
    /// different hide/reveal button, a different reset control, different tap targets. Both
    /// host paths now draw the same deck in the same order, so a Sync stream and an Assistant
    /// stream stop looking like two different apps.
    @ViewBuilder
    private func classicBottomChrome(bottomInset: CGFloat) -> some View {
        if controlsHidden {
            AppStreamChromeRevealButton(bottomInset: bottomInset) {
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
                    controlsHidden = false
                }
            }
        } else {
            classicChromePill
                .padding(.horizontal, AppSpacing.md)
                .padding(.bottom, max(bottomInset, 0) + AppSpacing.sm)
        }
    }

    private var classicChromePill: some View {
        AppStreamChromePill {
            AppStreamChromeButton(systemName: "xmark", isDestructive: true, action: onClose)

            AppStreamChromeButton(
                systemName: annotationStore.isVisible ? "pencil.slash" : "pencil.tip",
                isActive: annotationStore.isVisible
            ) {
                annotationStore.isVisible.toggle()
            }

            AppStreamChromeButton(
                systemName: keyboardActive ? "keyboard.chevron.compact.down" : "keyboard",
                isActive: keyboardActive
            ) {
                if !keyboardActive, isTerminalApplication { input.focusTerminal() }
                keyboardActive.toggle()
            }

            if windowID == nil, let displays = session.status.displays, displays.count > 1 {
                AppStreamChromeMenu(
                    systemName: "display.2",
                    accessibilityLabel: "Switch display"
                ) {
                    ForEach(displays) { display in
                        Button {
                            selectedDisplayID = display.id
                        } label: {
                            if selectedDisplayID == display.id {
                                Label(display.name, systemImage: "checkmark")
                            } else {
                                Text(display.name)
                            }
                        }
                    }
                }
            }

            if windowID != nil {
                // Window streams share the Sync deck's sizing control: the Mac window shape is
                // what this button is about, and "Fit window" now lives only on the 1× chip so
                // the same action is not offered three times over.
                AppStreamChromeMenu(
                    systemName: "aspectratio",
                    isDimmed: onAdaptiveSizing == nil,
                    accessibilityLabel: "Mac window sizing"
                ) {
                    Button("Adaptive resize", systemImage: "rectangle.arrowtriangle.2.inward") {
                        onAdaptiveSizing?()
                    }
                    Button("Original Size", systemImage: "arrow.up.left.and.arrow.down.right") {
                        onOriginalSizing?()
                    }
                }
            } else {
                AppStreamChromeMenu(
                    systemName: fillScreen
                        ? "rectangle.arrowtriangle.2.outward"
                        : "rectangle.arrowtriangle.2.inward",
                    isActive: fillScreen,
                    accessibilityLabel: "Remote display sizing",
                    accessibilityValue: fillScreen ? "Fill Screen" : "Fit Display"
                ) {
                    Button {
                        fillScreen = false
                        input.setFillScreen(false)
                        resetViewportZoom()
                    } label: {
                        Label("Fit Display", systemImage: fillScreen ? "rectangle.arrowtriangle.2.inward" : "checkmark")
                    }
                    Button {
                        fillScreen = true
                        input.setFillScreen(true)
                        resetViewportZoom()
                    } label: {
                        Label("Fill Screen", systemImage: fillScreen ? "checkmark" : "rectangle.arrowtriangle.2.outward")
                    }
                }
            }

            AppStreamChromeButton(systemName: "eye.slash", isDimmed: true) {
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
                    keyboardActive = false
                    annotationStore.isVisible = false
                    controlsHidden = true
                }
            }
        }
    }

    private func configureInput(viewSize: CGSize) {
        viewportSize = viewSize
        input.setGeometry(renderer.geometry)
        input.setViewSize(viewSize)
        input.setFillScreen(fillScreen)
        if let rect = input.cursorContentRect {
            cursorModel.setSurface(size: viewSize, contentRect: rect)
        }
    }

    /// The control deck floats over the bottom of the surface, so the picture must not be laid
    /// out underneath it. Reserving the band keeps the streamed app's own bottom controls (a
    /// toolbar, a send button) clear of the deck, and makes the Mac match the area the picture is
    /// actually drawn in instead of one taller than the phone can show.
    private static func controlDeckBand(safeAreaBottom: CGFloat) -> CGFloat {
        AppStreamChromePill<EmptyView>.reservedBand(safeAreaBottom: safeAreaBottom)
    }

    /// Rebuild the capture stream from the current settings. Shared by the automatic recovery
    /// bar and the manual "Refresh video" action so both do exactly the same thing.
    private func restartStream() {
        renderer.start(
            client: session.client,
            resolution: resolution,
            displayID: windowID == nil ? selectedDisplayID : nil,
            windowID: windowID,
            showsCursor: !usesLocalCursor)
        videoStartedAt = ProcessInfo.processInfo.systemUptime
    }

    /// The unobstructed part of the surface: the area the streamed app window may occupy.
    /// Whole-display control keeps the full surface — Fill Screen has to reach every edge, and
    /// the Mac display is never reshaped to the phone.
    private func videoViewport(in size: CGSize, safeAreaBottom: CGFloat) -> CGSize {
        guard windowID != nil else { return size }
        return CGSize(
            width: max(size.width, 1),
            height: max(size.height - Self.controlDeckBand(safeAreaBottom: safeAreaBottom), 1))
    }

    /// How the streamed picture is sized inside `area`, matching Vamp Sync's placement. A Mac app
    /// can decline the exact shape it was asked for by a few percent; covering absorbs that
    /// shortfall so the app's own bottom controls stay put, clear of the deck. Whole-display
    /// control keeps an honest fit.
    private func picturePlacement(in area: CGSize) -> DisplayMappingEngine.StreamPicturePlacement {
        let fallback = DisplayMappingEngine.StreamPicturePlacement(
            size: DesktopSize(width: max(area.width, 1), height: max(area.height, 1)),
            croppedFraction: 0)
        guard windowID != nil,
              let geometry = renderer.geometry,
              geometry.imageWidth > 0, geometry.imageHeight > 0,
              area.width > 0, area.height > 0 else { return fallback }
        return DisplayMappingEngine.placePicture(
            streamSize: DesktopSize(
                width: Double(geometry.imageWidth), height: Double(geometry.imageHeight)),
            container: DesktopSize(width: area.width, height: area.height))
    }

    private func keyName(for keyCode: UInt16) -> String {
        BeetCodeRemoteInputController.keyName(for: keyCode)
    }

    private func modifierNames(for flags: KeyboardModifierFlags) -> [String] {
        BeetCodeRemoteInputController.modifierNames(for: flags)
    }

    private func updateViewportZoom(scale: CGFloat, focalPoint: CGPoint, in viewSize: CGSize) {
        let oldZoom = viewportZoom
        let newZoom = min(max(viewportZoom * scale, defaultViewportZoom), 5)
        viewportZoom = newZoom
        guard newZoom > 1 else {
            viewportOffset = .zero
            return
        }

        let ratio = newZoom / max(oldZoom, 0.001)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let anchored = CGSize(
            width: viewportOffset.width + (1 - ratio) * (focalPoint.x - center.x - viewportOffset.width),
            height: viewportOffset.height + (1 - ratio) * (focalPoint.y - center.y - viewportOffset.height)
        )
        viewportOffset = clampedViewportOffset(anchored, zoom: newZoom, in: viewSize)
    }

    private func resetViewportZoom() {
        viewportZoom = defaultViewportZoom
        viewportOffset = .zero
    }

    private var defaultViewportZoom: CGFloat {
        // App windows are reshaped on the Mac to an adaptive aspect. Keep presentation at
        // aspect-fit so every control remains visible and pointer mapping stays exact.
        1
    }

    private func clampedViewportOffset(_ proposed: CGSize, zoom: CGFloat, in viewSize: CGSize) -> CGSize {
        guard zoom > 1, let geometry = renderer.geometry,
              geometry.imageWidth > 0, geometry.imageHeight > 0,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }

        let streamAspect = CGFloat(geometry.imageWidth) / CGFloat(geometry.imageHeight)
        let viewAspect = viewSize.width / viewSize.height
        let contentSize: CGSize
        if streamAspect > viewAspect {
            contentSize = CGSize(width: viewSize.width, height: viewSize.width / streamAspect)
        } else {
            contentSize = CGSize(width: viewSize.height * streamAspect, height: viewSize.height)
        }
        let content = CGRect(
            x: (viewSize.width - contentSize.width) / 2,
            y: (viewSize.height - contentSize.height) / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)

        func clamp(_ value: CGFloat, min edgeMin: CGFloat, max edgeMax: CGFloat, viewport: CGFloat, center: CGFloat) -> CGFloat {
            let scaledMin = center + (edgeMin - center) * zoom
            let scaledMax = center + (edgeMax - center) * zoom
            if scaledMax - scaledMin <= viewport {
                return viewport / 2 - (scaledMin + scaledMax) / 2
            }
            return min(max(value, viewport - scaledMax), -scaledMin)
        }

        return CGSize(
            width: clamp(proposed.width, min: content.minX, max: content.maxX, viewport: viewSize.width, center: center.x),
            height: clamp(proposed.height, min: content.minY, max: content.maxY, viewport: viewSize.height, center: center.y)
        )
    }
}

/// Locked-state surface for Vamp Assistant's authenticated HTTP compatibility path.
/// The password is cleared before the request starts and is never retained by the view.
private struct BeetCodeRemoteUnlockStateView: View {
    let message: String?
    let client: BeetCodeRemoteClient
    let onRefresh: () async -> String?
    let onClose: () -> Void

    @State private var password = ""
    @State private var isSubmitting = false
    @State private var unlockError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.white.opacity(0.92))

                Text("Mac is locked")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text(message ?? "Enter the Mac login password to resume Vamp Stream.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                SecureField("Mac login password", text: $password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .privacySensitive()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.24), lineWidth: 1)
                    }
                    .frame(maxWidth: 340)
                    .onSubmit(submitUnlock)

                Button(action: submitUnlock) {
                    HStack(spacing: 8) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(isSubmitting ? "Unlocking…" : "Unlock Mac")
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: 312)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .disabled(password.isEmpty || isSubmitting)

                Text("Available only through the encrypted Tailscale connection. The password is sent once, then cleared from this field.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.56))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                if let unlockError {
                    Text(unlockError)
                        .font(.footnote)
                        .foregroundStyle(.red.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }

                Button("Back", action: onClose)
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollDismissesKeyboard(.interactively)
    }

    private func submitUnlock() {
        guard !password.isEmpty, !isSubmitting else { return }
        let submittedPassword = password
        password = ""
        unlockError = nil
        isSubmitting = true

        Task {
            do {
                _ = try await client.unlockMac(password: submittedPassword)
                try? await Task.sleep(for: .milliseconds(700))
                unlockError = await onRefresh()
            } catch {
                unlockError = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}

/// Vamp Assistant's coordinate contract is global display points, while the iPhone gesture surface is
/// a letterboxed video. This mapper matches the host's aspect-fit policy and ignores letterbox
/// taps for clicks while clamping pointer movement to the nearest display edge.
@MainActor
final class BeetCodeRemoteInputController: ObservableObject {
    var isEnabled = false {
        willSet { if !newValue && isEnabled { if dragLocked { toggleDragLockCurrentPointer() }; flush() } }
    }
    /// Multiplier applied to relative pointer movement, driven by the Bluetooth sensitivity
    /// slider — the same knob the Sync path exposes.
    var pointerSensitivity: Double = 1.0
    private let client: BeetCodeRemoteClient
    private var geometry: BeetCodeDisplayGeometry?
    private var viewSize: CGSize = .zero
    private var fillScreen = false
    private var pendingMove: BeetCodeInputCommand?
    private var pendingScrollDX = 0.0
    private var pendingScrollDY = 0.0
    private var hasPendingScroll = false
    private var sendTail: Task<Void, Never>?
    private var flushLink: CADisplayLink?
    @Published private(set) var lastError: String?
    @Published private(set) var dragLocked = false

    init(client: BeetCodeRemoteClient) {
        self.client = client
    }

    deinit {
        flushLink?.invalidate()
        sendTail?.cancel()
    }

    func setGeometry(_ geometry: BeetCodeDisplayGeometry?) { self.geometry = geometry }
    func setViewSize(_ size: CGSize) { viewSize = size }
    func setFillScreen(_ enabled: Bool) { fillScreen = enabled }

    // MARK: - Local cursor overlay (cursorless capture)

    /// The fitted video content area in view coordinates — the overlay's clamp rect.
    var cursorContentRect: CGRect? {
        guard let geometry else { return nil }
        return contentRect(for: geometry)
    }

    /// View points per desktop point, for converting relative (desktop-space) pointer
    /// deltas into local cursor movement in the overlay's coordinate space.
    var cursorViewPointsPerDesktopPoint: Double? {
        guard let geometry, let rect = contentRect(for: geometry),
              rect.width > 0, geometry.displayWidth > 0 else { return nil }
        return rect.width / geometry.displayWidth
    }

    func clickCurrentPointer() {
        routeClick(x: nil, y: nil, button: "left", count: 1)
    }

    func doubleClickCurrentPointer() {
        routeClick(x: nil, y: nil, button: "left", count: 2)
    }

    func rightClickCurrentPointer() {
        routeClick(x: nil, y: nil, button: "right", count: 1)
    }

    func toggleDragLockCurrentPointer() {
        route(dragLocked ? .up(button: "left") : .down(button: "left"))
        dragLocked.toggle()
    }

    func scrollRelative(deltaX: Double, deltaY: Double) {
        pendingScrollDX += deltaX
        pendingScrollDY += deltaY
        hasPendingScroll = true
        ensureFlushLink()
    }

    func tap(at point: CGPoint) {
        guard let mapped = map(point, clamp: false) else { return }
        routeClick(x: mapped.x, y: mapped.y, button: "left", count: 1)
    }

    func doubleTap(at point: CGPoint) {
        guard let mapped = map(point, clamp: false) else { return }
        routeClick(x: mapped.x, y: mapped.y, button: "left", count: 2)
    }

    func rightClick(at point: CGPoint) {
        guard let mapped = map(point, clamp: false) else { return }
        routeClick(x: mapped.x, y: mapped.y, button: "right", count: 1)
    }

    func middleClick(at point: CGPoint) {
        guard let mapped = map(point, clamp: false) else { return }
        routeClick(x: mapped.x, y: mapped.y, button: "middle", count: 1)
    }

    func pointerMoved(at point: CGPoint) {
        guard let mapped = map(point, clamp: true) else { return }
        route(.move(x: mapped.x, y: mapped.y))
    }

    func pointerEnded() { flush() }

    func toggleDragLock(at point: CGPoint) {
        guard let mapped = map(point, clamp: true) else { return }
        route(.move(x: mapped.x, y: mapped.y))
        route(dragLocked ? .up(button: "left") : .down(button: "left"))
        dragLocked.toggle()
    }

    func scroll(deltaX: Double, deltaY: Double) {
        guard isEnabled else { return }
        guard let geometry, let rect = contentRect(for: geometry) else { return }
        let scaled = (
            dx: deltaX * geometry.displayWidth / max(rect.width, 1),
            dy: deltaY * geometry.displayHeight / max(rect.height, 1))
        pendingScrollDX += scaled.dx
        pendingScrollDY += scaled.dy
        hasPendingScroll = true
        ensureFlushLink()
    }

    func relativePointerMove(deltaX: Double, deltaY: Double) {
        guard let geometry, let rect = contentRect(for: geometry) else { return }
        let scale = max(geometry.displayWidth / max(rect.width, 1), geometry.displayHeight / max(rect.height, 1))
        // Same velocity curve and sensitivity as Vamp Control and the Sync path.
        let moved = PointerDynamics.apply(
            DesktopPoint(x: deltaX * scale, y: deltaY * scale),
            sensitivity: pointerSensitivity,
            accelerationEnabled: true)
        route(.relative(dx: moved.x, dy: moved.y))
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        route(.type(text))
    }

    func sendKey(_ key: String, modifiers: [String] = []) {
        route(.key(key, modifiers: modifiers))
    }

    func focusTerminal() {
        guard let geometry, let rect = contentRect(for: geometry) else { return }
        let point = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.82)
        guard let mapped = map(point, clamp: false) else { return }
        routeClick(x: mapped.x, y: mapped.y, button: "left", count: 1)
    }

    func stop() {
        isEnabled = false
        flushLink?.invalidate()
        flushLink = nil
        if dragLocked {
            enqueue(.up(button: "left"))
            dragLocked = false
        }
        pendingMove = nil
        pendingScrollDX = 0
        pendingScrollDY = 0
        hasPendingScroll = false
        lastError = nil
    }

    private func map(_ point: CGPoint, clamp: Bool) -> CGPoint? {
        guard isEnabled else { return nil }
        guard let geometry, let rect = contentRect(for: geometry), rect.width > 0, rect.height > 0 else { return nil }
        let clamped = CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY))
        guard clamp || rect.contains(point) else { return nil }
        let nx = (clamped.x - rect.minX) / rect.width
        let ny = (clamped.y - rect.minY) / rect.height
        return CGPoint(
            x: geometry.displayX + nx * geometry.displayWidth,
            y: geometry.displayY + ny * geometry.displayHeight)
    }

    private func contentRect(for geometry: BeetCodeDisplayGeometry) -> CGRect? {
        guard geometry.imageWidth > 0, geometry.imageHeight > 0,
              viewSize.width > 0, viewSize.height > 0 else { return nil }
        let imageAspect = CGFloat(geometry.imageWidth) / CGFloat(geometry.imageHeight)
        let viewAspect = viewSize.width / viewSize.height
        let size: CGSize
        if fillScreen {
            if imageAspect > viewAspect {
                size = CGSize(width: viewSize.height * imageAspect, height: viewSize.height)
            } else {
                size = CGSize(width: viewSize.width, height: viewSize.width / imageAspect)
            }
        } else if imageAspect > viewAspect {
            size = CGSize(width: viewSize.width, height: viewSize.width / imageAspect)
        } else {
            size = CGSize(width: viewSize.height * imageAspect, height: viewSize.height)
        }
        return CGRect(
            x: (viewSize.width - size.width) / 2,
            y: (viewSize.height - size.height) / 2,
            width: size.width,
            height: size.height)
    }

    private func route(_ command: BeetCodeInputCommand) {
        guard isEnabled else { return }
        switch command {
        case .move:
            pendingMove = command
            ensureFlushLink()
        case .relative:
            flushMove()
            enqueue(command)
        case .scroll:
            flushMove()
            enqueueScrollIfNeeded()
        default:
            flush()
            enqueue(command)
        }
    }

    private func routeClick(
        x: Double?,
        y: Double?,
        button: String,
        count: Int
    ) {
        flush()
        enqueue(BeetCodeInputCommand.clickSequence(
            x: x,
            y: y,
            button: button,
            count: count
        ))
    }

    private func flush() {
        flushMove()
        enqueueScrollIfNeeded()
        if pendingMove == nil, !hasPendingScroll {
            flushLink?.invalidate()
            flushLink = nil
        }
    }

    private func flushMove() {
        guard let pendingMove else { return }
        enqueue(pendingMove)
        self.pendingMove = nil
    }

    private func enqueueScrollIfNeeded() {
        guard hasPendingScroll else { return }
        enqueue(.scroll(x: nil, y: nil, dx: pendingScrollDX, dy: pendingScrollDY))
        pendingScrollDX = 0
        pendingScrollDY = 0
        hasPendingScroll = false
    }

    private func ensureFlushLink() {
        guard flushLink == nil else { return }
        let link = CADisplayLink(
            target: BeetCodeDisplayLinkProxy { [weak self] in self?.flush() },
            selector: #selector(BeetCodeDisplayLinkProxy.tick)
        )
        link.add(to: .main, forMode: .common)
        flushLink = link
    }

    private func enqueue(_ command: BeetCodeInputCommand) {
        enqueue([command])
    }

    private func enqueue(_ commands: [BeetCodeInputCommand]) {
        guard !commands.isEmpty else { return }
        let previous = sendTail
        sendTail = Task { [client, weak self] in
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            do {
                _ = try await client.sendControlBatch(commands)
                self?.lastError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Key naming

    /// The Assistant control protocol names keys rather than numbering them, so a keycode has
    /// to become a name before it goes on the wire. This lives on the controller — not on the
    /// view — because the keyboard deck and the Bluetooth bridge both need it.
    static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Backspace"
        case 53: return "Escape"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PageUp"
        case 121: return "PageDown"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 49: return "Space"
        default:
            // Every shortcut on the keyboard decks (⌘C, ⌃C, ⌘V, ⌘Z, ⌘⇧3 …) is a letter or digit
            // keycode. Without this they went out as "key8" and the Mac silently ignored them.
            return AppStreamKeyboardOverlayView.character(forKeyCode: keyCode) ?? "key\(keyCode)"
        }
    }

    static func modifierNames(for flags: KeyboardModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.function) { names.append("function") }
        return names
    }
}

/// A paired Bluetooth mouse/keyboard drives the Assistant stream through the same shared
/// bridge as the Sync stream and Vamp Control. Only the Sync path implemented this, so on an
/// Assistant Mac a paired mouse moved the hover cursor but its buttons, its scroll wheel and
/// any physical keyboard went nowhere.
extension BeetCodeRemoteInputController: RemotePointerInputSink {
    func sendPointerButton(_ button: MouseButton, action: ButtonAction) {
        guard isEnabled else { return }
        let name: String
        switch button {
        case .left: name = "left"
        case .right: name = "right"
        case .middle: name = "middle"
        }
        switch action {
        case .down:
            route(.down(button: name))
            if name == "left" { dragLocked = true }
        case .up:
            route(.up(button: name))
            if name == "left" { dragLocked = false }
        case .click:
            routeClick(x: nil, y: nil, button: name, count: 1)
        case .doubleClick:
            routeClick(x: nil, y: nil, button: name, count: 2)
        }
    }

    func sendScrollInput(deltaX: Double, deltaY: Double) {
        guard isEnabled else { return }
        scrollRelative(deltaX: deltaX, deltaY: deltaY)
    }

    func sendKey(keyCode: UInt16, action: KeyAction, modifiers: KeyboardModifierFlags) {
        guard isEnabled else { return }
        // The Assistant protocol takes a whole key press, not separate down/up edges, so the
        // key is sent once — on the down edge — and the up edge is dropped.
        guard action == .down else { return }
        sendKey(Self.keyName(for: keyCode), modifiers: Self.modifierNames(for: modifiers))
    }
}

private final class BeetCodeDisplayLinkProxy {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func tick() {
        handler()
    }
}
#endif
