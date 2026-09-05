import Combine
import CoreGraphics
import SwiftUI
import SharedModels

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
    private enum StreamResolution: String, CaseIterable, Identifiable {
        case p480 = "480p"
        case p720 = "720p"
        case p1080 = "1080p"
        case native

        var id: String { rawValue }
        var title: String { rawValue == "native" ? "Native" : rawValue }
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
    @State private var startedStreamTaskID: String?
    @StateObject private var renderer: BeetCodeVideoRendererViewModel
    @StateObject private var input: BeetCodeRemoteInputController
    @State private var keyboardActive = false
    @State private var keyboardOverlayBottomPad: CGFloat = 0
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
                windowID: windowID)
            startedStreamTaskID = streamTaskID
        }
        .onChangeCompat(of: canInteract) { enabled in input.isEnabled = enabled }
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
                    windowID: windowID)
            } else {
                renderer.stop()
                input.stop()
            }
        }
        .onDisappear {
            renderer.stop()
            input.stop()
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
        "\(session.address)-\(session.status.ready)-\(windowID ?? 0)-\(selectedDisplayID ?? 0)-\(resolution)-\(streamGeometryRevision)"
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
                if onAdaptiveSizing != nil {
                    Text(sizingNotice ?? " ").font(.caption).foregroundStyle(.white)
                        .lineLimit(2).padding(.horizontal, 6).frame(maxWidth: .infinity).frame(height: 36)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    Color.black

                    if renderer.latestPixelBuffer != nil {
                        VideoFrameRendererView(
                            pixelBuffer: renderer.latestPixelBuffer,
                            displayMode: fillScreen ? .fillScreen : .fitDisplay)
                            .scaleEffect(viewportZoom, anchor: .center)
                            .offset(viewportOffset)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        AppStreamGestureView(
                        allowsViewportAdjustment: adjustsViewport,
                            viewportZoom: viewportZoom,
                            viewportOffset: viewportOffset,
                            viewSize: proxy.size,
                            onTap: { input.tap(at: $0) },
                            onDoubleTap: { input.doubleTap(at: $0) },
                            onRightClick: { input.rightClick(at: $0) },
                            onMiddleClick: { input.middleClick(at: $0) },
                            onPointerMove: { input.pointerMoved(at: $0) },
                            onPointerEnded: { input.pointerEnded() },
                            onScroll: { input.scroll(deltaX: $0, deltaY: $1) },
                            onViewportPan: { delta in
                                viewportOffset = clampedViewportOffset(
                                    CGSize(width: viewportOffset.width + delta.width,
                                           height: viewportOffset.height + delta.height),
                                    zoom: viewportZoom,
                                    in: proxy.size
                                )
                            },
                            onPinchChanged: { scale, focalPoint in
                                updateViewportZoom(scale: scale, focalPoint: focalPoint, in: proxy.size)
                            },
                            onPinchEnded: {
                                if viewportZoom < defaultViewportZoom * 1.15 {
                                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                                        resetViewportZoom()
                                    }
                                }
                            },
                            onLongPress: { input.toggleDragLock(at: $0) },
                            onLongPressEnded: { if input.dragLocked { input.toggleDragLockCurrentPointer() } },
                            onHoverDelta: { input.relativePointerMove(deltaX: $0, deltaY: $1) }
                        )
                        .allowsHitTesting(!keyboardActive && !annotationStore.isVisible && canInteract)

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
                                        windowID: windowID)
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
                        AppStreamVideoRecoveryBar {
                            renderer.start(client: session.client, resolution: resolution,
                                displayID: windowID == nil ? selectedDisplayID : nil, windowID: windowID)
                            videoStartedAt = ProcessInfo.processInfo.systemUptime
                        }
                        .padding(12)
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
                        .padding(.bottom, keyboardOverlayBottomPad)
                    }
                }
                .onAppear {
                    configureInput(viewSize: proxy.size)
                    onViewportSize?(proxy.size)
                }
                .onChangeCompat(of: proxy.size) {
                    configureInput(viewSize: $0)
                    viewportOffset = clampedViewportOffset(viewportOffset, zoom: viewportZoom, in: $0)
                    if !keyboardActive { onViewportSize?($0) }
                }
                .onChangeCompat(of: renderer.geometry) { geometry in
                    configureInput(viewSize: proxy.size)
                    if geometry != nil {
                        viewportOffset = clampedViewportOffset(viewportOffset, zoom: viewportZoom, in: proxy.size)
                    }

                }
#if canImport(UIKit) && !os(macOS)
                .background(AppStreamKeyboardInsetReader { inset in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { keyboardOverlayBottomPad = inset }
                })
#endif
            }
        }
        .background(Color.black)
        .ignoresSafeArea(edges: [.horizontal, .bottom])
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
                        Button("Original proportions") { onOriginalSizing?() }
                    }
                }
                Picker("Resolution", selection: $resolution) {
                    ForEach(StreamResolution.allCases) { option in Text(option.title).tag(option.rawValue) }
                }
                Button("Gesture help", systemImage: "hand.draw") { showsGestureHelp = true }
                if input.dragLocked {
                    Button("Release drag lock", systemImage: "lock.open") { input.toggleDragLockCurrentPointer() }
                }
            } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("Stream options")
            .sheet(isPresented: $showsGestureHelp) { AppStreamGestureHelpView() }
            Button {
                if !keyboardActive, isTerminalApplication { input.focusTerminal() }
                keyboardActive.toggle()
            } label: {
                Image(systemName: keyboardActive ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(keyboardActive ? "Hide keyboard" : "Show keyboard")
            .accessibilityHint("Type into the Mac through the on-screen keyboard")

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

    @ViewBuilder
    private func classicBottomChrome(bottomInset: CGFloat) -> some View {
        if controlsHidden {
            HStack {
                Spacer()
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
                        controlsHidden = false
                    }
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.58), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show remote controls")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, max(bottomInset, 0) + 14)
        } else {
            classicChromePill
                .padding(.horizontal, 14)
                .padding(.bottom, max(bottomInset, 0) + 12)
        }
    }

    private var classicChromePill: some View {
        HStack(spacing: 0) {
            classicIconButton(systemName: "xmark", isDestructive: true, action: onClose)

            classicUnavailableButton(
                systemName: "magicmouse",
                label: "Bluetooth input status is available for Vamp Sync sessions")

            classicIconButton(
                systemName: annotationStore.isVisible ? "pencil.slash" : "pencil.tip",
                isActive: annotationStore.isVisible
            ) {
                annotationStore.isVisible.toggle()
            }

            classicIconButton(
                systemName: keyboardActive ? "keyboard.chevron.compact.down" : "keyboard",
                isActive: keyboardActive
            ) {
                keyboardActive.toggle()
            }

            if windowID == nil, let displays = session.status.displays, displays.count > 1 {
                Menu {
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
                } label: {
                    classicIconLabel(systemName: "display.2", isActive: false, isDimmed: false, isDestructive: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Switch display")
            }

            classicUnavailableButton(
                systemName: "terminal.fill",
                label: "Terminal is not available in this Assistant control session")
            classicUnavailableButton(
                systemName: "speaker.slash.fill",
                label: "Remote audio is not available in this Assistant control session")
            classicUnavailableButton(
                systemName: "pip.enter",
                label: "Picture in Picture is not available in this Assistant control session")

            Menu {
                if windowID != nil {
                    Button {
                        fillScreen = false
                        input.setFillScreen(false)
                        resetViewportZoom()
                    } label: {
                        Label("Adaptive Fit", systemImage: "checkmark")
                    }
                } else {
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
            } label: {
                classicIconLabel(
                    systemName: fillScreen ? "rectangle.arrowtriangle.2.outward" : "rectangle.arrowtriangle.2.inward",
                    isActive: fillScreen,
                    isDimmed: false,
                    isDestructive: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remote display sizing")
            .accessibilityValue(windowID != nil ? "Adaptive Fit" : (fillScreen ? "Fill Screen" : "Fit Display"))

            classicUnavailableButton(
                systemName: "chart.bar",
                label: "Connection statistics are unavailable for this Assistant stream")

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 22)
                .padding(.horizontal, 6)

            classicIconButton(systemName: "eye.slash", isDimmed: true) {
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
                    keyboardActive = false
                    controlsHidden = true
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // The remote image can be nearly white or highly detailed. Native
        // clear glass alone inherits too much of that content and makes the
        // classic controls disappear, so retain colorless glass while giving
        // it a neutral legibility backing and a stable edge.
        .background(Color.black.opacity(0.62), in: Capsule(style: .continuous))
        .prGlassSurface(in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func classicUnavailableButton(systemName: String, label: String) -> some View {
        Button(action: {}) {
            classicIconLabel(systemName: systemName, isActive: false, isDimmed: true, isDestructive: false)
        }
        .buttonStyle(.plain)
        .disabled(true)
        .accessibilityLabel(label)
        .accessibilityHint(label)
    }

    private func classicIconButton(
        systemName: String,
        isActive: Bool = false,
        isDimmed: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            classicIconLabel(
                systemName: systemName,
                isActive: isActive,
                isDimmed: isDimmed,
                isDestructive: isDestructive)
        }
        .buttonStyle(.plain)
    }

    private func classicIconLabel(
        systemName: String,
        isActive: Bool,
        isDimmed: Bool,
        isDestructive: Bool
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(
                isDestructive ? Color.red.opacity(0.86)
                    : (isActive ? Color.white : Color.white.opacity(isDimmed ? 0.42 : 0.82)))
            .frame(maxWidth: .infinity, minHeight: 30)
            .contentShape(Rectangle())
    }

    private func configureInput(viewSize: CGSize) {
        viewportSize = viewSize
        input.setGeometry(renderer.geometry)
        input.setViewSize(viewSize)
        input.setFillScreen(fillScreen)
    }

    private func keyName(for keyCode: UInt16) -> String {
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

    private func modifierNames(for flags: KeyboardModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.function) { names.append("function") }
        return names
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
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
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
        let speed = hypot(deltaX * scale, deltaY * scale)
        let acceleration = 1.0 + min(speed / 50.0, 1.5)
        route(.relative(dx: deltaX * scale * acceleration, dy: deltaY * scale * acceleration))
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
