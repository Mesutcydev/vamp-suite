#if canImport(UIKit)
import SwiftUI
import SharedModels
import SharedProtocol
// Named directly by `picturePlacement(in:)`; the inferred `.fitDisplay` members did not.
import SharedUtilities
import UIKit

/// Vamp Stream's core screen: the Mac's applications. Tap one to stream just that app's window
/// (reusing the shared video renderer + input via `MirrorScreen`). All state comes from
/// `AppStreamViewModel` — never a fake "connected" while frozen.
/// Which surface wraps the shared app-streaming engine. Vamp Stream keeps its own library; Vamp
/// Control draws the same list and launch state in its design language. The stream surface, input,
/// and session handling are identical for both.
enum AppStreamChrome {
    case stream
    case control
}

@available(iOS 16.1, *)
struct AppStreamBrowserView: View {
    let environment: ClientAppEnvironment
    @ObservedObject var vm: AppStreamViewModel
    let chrome: AppStreamChrome
    @ObservedObject private var sessionCoordinator: ClientSessionCoordinator
    /// Disconnect / leave this Mac.
    var onClose: () -> Void
    @StateObject private var rendererVM: VideoRendererViewModel
    @StateObject private var input: AppStreamInputController
    @StateObject private var cursorModel = LocalCursorModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("vampstream.favoriteApps") private var favoriteStorage = "[]"
    @AppStorage("vampstream.recentApps") private var recentStorage = "[]"
    @AppStorage("vampstream.qualityMode") private var qualityMode = "quality"
    @AppStorage("vampstream.didShowGestureHelp") private var didShowGestureHelp = false
    @State private var searchText = ""
    @State private var libraryFilter = StreamLibraryFilter.all
    @State private var closeChoice: RemoteApplication?
    @State private var showsHelp = false
    @State private var expiredSizingNotice: String?
    @State private var videoHealthCheckTime = ProcessInfo.processInfo.systemUptime
    @State private var videoStartedAt = ProcessInfo.processInfo.systemUptime
    @State private var keyboardActive = false
    @State private var adjustsViewport = false
    /// One bottom control deck owns close, annotate, keyboard, sizing, fit, and hide — the same
    /// deck the Assistant path draws, so both Sync and Assistant streams look like one app.
    @StateObject private var annotationStore = AnnotationOverlayStore()
    @State private var controlsHidden = false
    @State private var viewportWindowID: String?
    @State private var viewportZoom: CGFloat = 1
    @State private var viewportOffset: CGSize = .zero
    /// A paired Bluetooth mouse/keyboard drives this session, exactly as it does in Vamp
    /// Control. Stream previously ignored mouse buttons, the scroll wheel, and physical
    /// keyboards entirely — only the on-screen hover cursor worked.
    @StateObject private var bluetoothInput = BluetoothInputController()
    @State private var showsBluetoothStatus = false

    init(environment: ClientAppEnvironment, vm: AppStreamViewModel, chrome: AppStreamChrome = .stream,
         onClose: @escaping () -> Void) {
        self.environment = environment
        self.vm = vm
        self.chrome = chrome
        self.onClose = onClose
        self.sessionCoordinator = environment.sessionCoordinator
        _rendererVM = StateObject(
            wrappedValue: VideoRendererViewModel(webRTCSessionManager: environment.webRTCSessionManager)
        )
        _input = StateObject(
            wrappedValue: AppStreamInputController(webRTC: environment.webRTCSessionManager, onFailure: { reason in
                Task { await environment.sessionCoordinator.disconnectForInputFailure(reason) }
            })
        )
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if hostIsLocked {
                    AppStreamLockedStateView(
                        sessionCoordinator: sessionCoordinator,
                        onDisconnect: onClose
                    )
                } else {
                    switch vm.status {
                    case .streaming(_, let name):
                        streamSurface(name: name)
                            .vampStreamVideoSurface()
                    case .launching(let name):
                        launching(name: name)
                    default:
                        browser
                    }
                }
            }
            .onAppear {
                vm.updateClientViewport(size: videoViewport(
                    in: proxy.size, safeAreaBottom: proxy.safeAreaInsets.bottom))
            }
            .onChangeCompat(of: proxy.size) { size in
                if case .streaming = vm.status { return }
                vm.updateClientViewport(size: videoViewport(
                    in: size, safeAreaBottom: proxy.safeAreaInsets.bottom))
            }
        }
        .task {
            rendererVM.onNeedsKeyframe = { [weak sc = environment.sessionCoordinator] in
                sc?.requestKeyframeRefresh(reason: "app stream decode")
            }
            vm.start()
            // Observe a paired Bluetooth mouse/keyboard for the whole session, the same way
            // Vamp Control does. The sink is the stream input controller, so button and scroll
            // events reach the Mac through the existing ordered, authenticated send path.
            bluetoothInput.sink = input
            bluetoothInput.startObserving()
            if hostIsLocked {
                vm.pauseForHostLock()
            } else {
                vm.requestApplicationList()
            }
        }
        .onChangeCompat(of: bluetoothInput.mouseSensitivity) { newValue in
            input.pointerSensitivity = newValue
        }
        .onChangeCompat(of: vm.status) { status in
            guard !hostIsLocked else { return }
            switch status {
            case .streaming:
                if viewportWindowID != vm.streamedWindow?.windowID {
                    resetViewportZoom()
                    viewportWindowID = vm.streamedWindow?.windowID
                }
                if !didShowGestureHelp { showsHelp = true; didShowGestureHelp = true }
            default:
                // Leaving the stream surface must release any drag-lock and stop decoding;
                // the browser can remain mounted while the app target changes.
                input.stop()
                rendererVM.stopReceiving()
            }
        }
        .onChangeCompat(of: vm.geometryRevision) { _ in
            input.isEnabled = false
            if scenePhase == .active, !hostIsLocked {
                rendererVM.startReceiving()
                sessionCoordinator.requestKeyframeRefresh(reason: "App window geometry changed")
            }
        }
        .onChangeCompat(of: canInteract) { enabled in input.isEnabled = enabled }
        .onChangeCompat(of: scenePhase) { phase in
            input.isEnabled = false
            if phase == .active, !hostIsLocked {
                vm.resumeAfterHostUnlock()
                if case .streaming = vm.status { rendererVM.startReceiving() }
            } else {
                vm.suspendInteraction()
                rendererVM.stopReceiving()
            }
        }
        .onChangeCompat(of: sessionCoordinator.hostLockState) { state in
            if state == .lockedOrLoginWindow {
                rendererVM.stopReceiving()
                input.stop()
                vm.pauseForHostLock()
            } else {
                vm.resumeAfterHostUnlock()
                if case .streaming = vm.status { rendererVM.startReceiving() }
            }
        }
        .sheet(isPresented: $showsHelp) { AppStreamGestureHelpView(isViewOnly: isViewOnly) }
        .sheet(isPresented: $showsBluetoothStatus) {
            BluetoothInputStatusView(controller: bluetoothInput) { showsBluetoothStatus = false }
        }
        .confirmationDialog(
            closePromptTitle,
            isPresented: Binding(
                get: { closeChoice != nil },
                set: { if !$0 { closeChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let app = closeChoice {
                Button("Close \(app.name)", role: .destructive) { vm.close(app) }
            }
            Button("Cancel", role: .cancel) { closeChoice = nil }
        } message: {
            Text("Unsaved changes on the Mac may be lost.")
        }
        .onChangeCompat(of: qualityMode) { _ in applyQuality() }
        .onDisappear {
            rendererVM.stopReceiving()
            input.stop()
            vm.stop()
            vm.cancelVideoRecovery()
            // Detach the shared bridge so a paired mouse cannot keep driving a session this
            // view no longer owns, and so re-entering does not double-subscribe.
            bluetoothInput.stopObserving()
        }
    }

    private var videoStalled: Bool {
        AppStreamVideoHealth.isStalled(lastDecodedAt: rendererVM.lastDecodedAt, now: videoHealthCheckTime)
    }

    private var isViewOnly: Bool { sessionCoordinator.sessionMode == .viewOnly }

    private var canInteract: Bool { !isViewOnly && isVideoReady }

    private var isVideoReady: Bool {
        scenePhase == .active && !hostIsLocked && !vm.isResizing && !vm.isGeometryChanging && !videoStalled
            && rendererVM.latestPixelBuffer != nil && rendererVM.isReceiving
    }

    private var closePromptTitle: String {
        if let closeChoice { return "Close \(closeChoice.name)?" }
        return "Close this app?"
    }

    private var macName: String { sessionCoordinator.connectedHostName ?? "My Mac" }
    private var hostIsLocked: Bool {
        sessionCoordinator.hostLockState == .lockedOrLoginWindow
    }
    /// Cursorless-capture contract: only when negotiation agreed that the host omits the
    /// macOS cursor from the frames does this surface draw its own local pointer. An
    /// older host still captures the cursor, and drawing on top of it would double it.
    private var usesLocalCursor: Bool {
        !isViewOnly && sessionCoordinator.negotiatedCapabilities?.supportsCursorlessCapture == true
    }
    private var favoriteIDs: [String] { AppStreamAppShortlists.decode(favoriteStorage) }
    private var matchingApps: [RemoteApplication] {
        vm.applications.filter { searchText.isEmpty || $0.name.localizedStandardContains(searchText) }
    }
    private var favorites: [RemoteApplication] { matchingApps.filter { favoriteIDs.contains($0.id) } }
    private var recent: [RemoteApplication] {
        AppStreamAppShortlists.decode(recentStorage)
            .compactMap { id in matchingApps.first { $0.id == id && !favoriteIDs.contains(id) } }
    }
    private var running: [RemoteApplication] { matchingApps.filter { $0.isRunning } }
    private var installed: [RemoteApplication] { matchingApps.filter { !$0.isRunning } }
    private func open(_ app: RemoteApplication, windowID: String? = nil) {
        recentStorage = AppStreamAppShortlists.promoting(app.id, in: recentStorage)
        vm.select(app, windowID: windowID)
    }
    private func applyQuality() {
        let preset: StreamQualityPreset = qualityMode == "performance" ? .performance
            : qualityMode == "auto" ? .balanced : (environment.isUltraQualityEntitled ? .ultra : .quality)
        environment.preferredQualityPreset = preset
        sessionCoordinator.setPreferredQuality(preset)
    }

    // MARK: - Browser

    private var libraryApps: [RemoteApplication] {
        let apps: [RemoteApplication]
        switch libraryFilter {
        case .all: apps = matchingApps
        case .running: apps = matchingApps.filter(\.isRunning)
        case .favorites: apps = favorites
        }
        return apps.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    @ViewBuilder private var browser: some View {
        #if VAMP_CONTROL_APP
        if chrome == .control {
            controlLibrary
        } else {
            streamLibrary
        }
        #else
        streamLibrary
        #endif
    }

    #if VAMP_CONTROL_APP
    private var controlLibrary: some View {
        ControlAppLibrary(
            macName: macName,
            apps: libraryApps,
            isLoading: vmIsLoading,
            failure: bannerReason,
            isViewOnly: isViewOnly,
            favoriteIDs: favoriteIDs,
            leaveTitle: canReturnToDesktop ? "Desktop" : "Macs",
            leaveSymbol: canReturnToDesktop ? "display" : "chevron.left",
            searchText: $searchText,
            filter: $libraryFilter,
            onOpen: { app, windowID in open(app, windowID: windowID) },
            onToggleFavorite: { app in
                favoriteStorage = AppStreamAppShortlists.toggled(app.id, in: favoriteStorage)
            },
            onRequestClose: { app in closeChoice = app },
            onRefresh: { vm.requestApplicationList() },
            onLeave: onClose
        )
    }

    /// Vamp Sync keeps the desktop available beside app windows; an app-only host has no desktop
    /// to return to, so leaving the apps ends the session there.
    private var canReturnToDesktop: Bool {
        guard let capabilities = sessionCoordinator.negotiatedCapabilities else { return false }
        return capabilities.supportsMultiDisplay && !sessionCoordinator.appStreamingOnlySession
    }
    #endif

    private var streamLibrary: some View {
        let apps = libraryApps
        return VStack(alignment: .leading, spacing: 0) {
            StreamLibraryHeader(macName: macName, onClose: onClose)
            VStack(spacing: 14) {
                VampAppSearchField(text: $searchText)
                StreamLibraryFilters(selection: $libraryFilter)
            }
            .padding(.horizontal, StreamDesign.inset)
            .padding(.bottom, 10)
            if isViewOnly {
                VampStreamViewOnlyNotice()
                    .padding(.horizontal, StreamDesign.inset)
                    .padding(.vertical, 12)
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let reason = bannerReason { banner(reason) }
                    if vm.applications.isEmpty {
                        loadingOrEmpty
                    } else if apps.isEmpty {
                        StreamLibraryEmptyState(filter: libraryFilter, isSearching: !searchText.isEmpty)
                    } else {
                        StreamLibrarySectionHeading(title: libraryFilter == .all ? "On your Mac" : libraryFilter.title,
                                                    count: apps.count)
                        LazyVStack(spacing: 0) {
                            ForEach(apps) { app in
                                appRow(app)
                                if app.id != apps.last?.id {
                                    Rectangle().fill(StreamDesign.line).frame(height: 0.5).padding(.leading, 80)
                                }
                            }
                        }
                        .appQuietSurface(isInteractive: true)
                        Text("Touch and hold an app for windows and favorites.")
                            .font(.caption).foregroundStyle(StreamDesign.secondary)
                            .padding(.top, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, StreamDesign.inset)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { vm.requestApplicationList() }
        }
        .frame(maxWidth: StreamDesign.maxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func appRow(_ app: RemoteApplication) -> some View {
        AppStreamApplicationRow(application: app, isFavorite: favoriteIDs.contains(app.id)) {
            open(app)
        }
        .contextMenu {
            if app.windowIDs.count > 1 {
                Menu("Windows", systemImage: "macwindow.on.rectangle") {
                    ForEach(Array(app.windowIDs.enumerated()), id: \.element) { index, id in
                        Button(app.windowTitles?[id] ?? "Window \(index + 1)") {
                            open(app, windowID: id)
                        }
                    }
                }
            }
            Button(favoriteIDs.contains(app.id) ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: favoriteIDs.contains(app.id) ? "star.slash" : "star") {
                favoriteStorage = AppStreamAppShortlists.toggled(app.id, in: favoriteStorage)
            }
            if !isViewOnly, app.isRunning, ApplicationClosePolicy.canClose(app.bundleIdentifier) {
                Button("Close \(app.name)", systemImage: "xmark.app", role: .destructive) {
                    closeChoice = app
                }
            }
        }
    }

    private var bannerReason: String? {
        switch vm.status {
        case .failed(let reason), .targetLost(let reason): return reason
        default: return nil
        }
    }

    private func banner(_ reason: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PR.warn)
            Text(reason).font(.footnote).foregroundStyle(PR.fg)
            Spacer()
            Button("Retry") { vm.requestApplicationList() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PR.fg)
        }
        .padding(14)
        .streamGlass()
    }

    @ViewBuilder private var loadingOrEmpty: some View {
        VampStreamAppListEmptyHint(
            title: vmIsLoading ? "Loading applications…" : (bannerReason == nil ? "No applications found" : "Couldn’t load applications"),
            isLoading: vmIsLoading,
            actionTitle: vmIsLoading ? nil : (bannerReason == nil ? "Refresh" : "Retry"),
            action: vmIsLoading ? nil : { vm.requestApplicationList() }
        )
    }

    private var vmIsLoading: Bool {
        if case .loadingApps = vm.status { return true }
        return false
    }

    // MARK: - Launching / streaming

    @ViewBuilder private func launching(name: String) -> some View {
        #if VAMP_CONTROL_APP
        if chrome == .control {
            ControlAppLaunching(name: name) { vm.backToApps() }
        } else {
            streamLaunching(name: name)
        }
        #else
        streamLaunching(name: name)
        #endif
    }

    private func streamLaunching(name: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().tint(PR.fg).controlSize(.large)
            Text("Launching \(name)…")
                .font(.headline)
                .foregroundStyle(PR.fg)
            VampGlassActionButton(title: "Cancel", action: { vm.backToApps() })
        }
        .padding(22)
        .streamGlass()
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func streamSurface(name: String) -> some View {
        GeometryReader { proxy in
            let videoArea = videoViewport(
                in: proxy.size, safeAreaBottom: proxy.safeAreaInsets.bottom)
            // The picture is drawn at exactly the size `placePicture` chose, and its height is
            // therefore either the surface's own or short by only a hair. The render layer centers
            // whatever it is given, so the picture's frame — not a full-height layer — decides
            // where the spare points go: nothing is left above it, and the deck owns the band
            // below it.
            let placement = picturePlacement(in: videoArea)
            let picture = CGSize(width: placement.size.width, height: placement.size.height)
            ZStack(alignment: .top) {
                Color.black

                if rendererVM.latestPixelBuffer != nil {
                    // The app window itself. `resizeAspect` preserves the actual window shape;
                    // Preserve that shape inside the portrait viewport; zoom and pan stay local.
                    VideoFrameRendererView(
                        pixelBuffer: rendererVM.latestPixelBuffer,
                        displayMode: .fitDisplay,
                        renderer: rendererVM
                    )
                    .scaleEffect(viewportZoom, anchor: .center)
                    .offset(viewportOffset)
                    .frame(width: picture.width, height: picture.height)
                    .frame(width: videoArea.width, height: videoArea.height, alignment: .top)

                    // Direct-touch control: uses the same gesture semantics and ordered input
                    // pipeline as Vamp Control. Coordinates map through the streamed window's
                    // synthetic display descriptor (see configureInteraction).
                    AppStreamGestureView(
                        allowsViewportAdjustment: adjustsViewport || isViewOnly,
                        viewportZoom: viewportZoom,
                        viewportOffset: viewportOffset,
                        viewSize: picture,
                        onTap: { point in
                            cursorModel.place(at: CGPoint(x: point.x, y: point.y))
                            input.tap(at: DesktopPoint(x: point.x, y: point.y))
                        },
                        onDoubleTap: { point in
                            cursorModel.place(at: CGPoint(x: point.x, y: point.y))
                            input.doubleTap(at: DesktopPoint(x: point.x, y: point.y))
                        },
                        onRightClick: { point in
                            cursorModel.place(at: CGPoint(x: point.x, y: point.y))
                            input.rightClick(at: DesktopPoint(x: point.x, y: point.y))
                        },
                        onMiddleClick: { point in
                            cursorModel.place(at: CGPoint(x: point.x, y: point.y))
                            input.middleClick(at: DesktopPoint(x: point.x, y: point.y))
                        },
                        onPointerMove: { point in
                            cursorModel.place(at: CGPoint(x: point.x, y: point.y))
                            input.pointerMoved(at: DesktopPoint(x: point.x, y: point.y))
                        },
                        onPointerEnded: { input.pointerEnded() },
                        onScroll: { dx, dy in input.scroll(deltaX: dx, deltaY: dy) },
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
                            if viewportZoom < 1.15 {
                                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                                    resetViewportZoom()
                                }
                            }
                        },
                        onLongPress: { point in
                            cursorModel.place(at: CGPoint(x: point.x, y: point.y))
                            input.toggleDragLock(at: DesktopPoint(x: point.x, y: point.y))
                        },
                        onLongPressEnded: { input.releaseDragLock() },
                        onHoverDelta: { dx, dy in
                            input.relativePointerMove(deltaX: dx, deltaY: dy)
                            if let scale = input.cursorViewPointsPerDesktopPoint {
                                cursorModel.moveRelative(
                                    dx: dx, dy: dy, viewPointsPerDesktopPoint: scale)
                            }
                        }
                    )
                    .frame(width: picture.width, height: picture.height)
                    .overlay {
                        // Cursorless capture: the host omits the macOS cursor, so the
                        // pointer is drawn here at the exact points the input pipeline
                        // maps — zero-round-trip hover feedback. The overlay carries the
                        // viewport's zoom/pan so it stays glued to the content when the
                        // picture is magnified. It sits inside the picture's frame, before
                        // the anchoring below, so a cover-crop cannot offset it.
                        if usesLocalCursor {
                            LocalCursorOverlay(cursor: cursorModel, contentZoom: viewportZoom,
                                               pointsPerDesktopPoint: input.cursorViewPointsPerDesktopPoint)
                                .scaleEffect(viewportZoom, anchor: .center)
                                .offset(viewportOffset)
                        }
                    }
                    .allowsHitTesting(!keyboardActive && !annotationStore.isVisible && isVideoReady)
                    // Placement happens last: covering makes the picture's height exactly the
                    // surface's, so it cannot creep under the deck that sits at that edge.
                    .frame(width: videoArea.width, height: videoArea.height, alignment: .top)

                    if annotationStore.isVisible {
                        AnnotationCanvasOverlay(store: annotationStore)
                    }

                } else {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Opening \(name)…")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

            }
            .overlay(alignment: .top) {
                if AppStreamVideoHealth.needsRecovery(lastDecodedAt: rendererVM.lastDecodedAt,
                    startedAt: videoStartedAt, now: videoHealthCheckTime) {
                    AppStreamVideoRecoveryBar {
                        let recoveryStartedAt = ProcessInfo.processInfo.systemUptime
                        vm.recoverVideo { [rendererVM] in
                            guard let last = rendererVM.lastDecodedAt else { return true }
                            return last < recoveryStartedAt
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                }
            }
            .overlay(alignment: .bottom) {
                if let notice = vm.sizingNotice, notice != expiredSizingNotice, !keyboardActive {
                    Text(notice)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(AppSpacing.xs)
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: PR.r8, style: .continuous))
                        .padding(.horizontal, AppSpacing.md)
                        // Clear the control deck so a sizing notice is never hidden behind it.
                        // Derived from the deck, not a copied number, so it follows when the
                        // deck's height changes.
                        .padding(
                            .bottom,
                            AppStreamChromeBar.reservedBand(safeAreaBottom: 0, height: deckHeight) + AppSpacing.xs)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            // The notice is informational and sits over the streamed app, so it fades on its own
            // instead of covering the window's bottom row until the next resize result.
            .task(id: vm.sizingNotice) {
                guard let notice = vm.sizingNotice else { expiredSizingNotice = nil; return }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { expiredSizingNotice = notice }
            }
            .overlay(alignment: .bottom) {
                if controlsHidden {
                    AppStreamChromeRevealButton(
                        bottomInset: max(proxy.safeAreaInsets.bottom, AppStreamChromeBar.bottomFloor)
                    ) {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
                            controlsHidden = false
                        }
                    }
                } else {
                    streamChromePill
                        .padding(.horizontal, AppStreamChromeBar.edgeInset)
                        .padding(
                            .bottom,
                            max(proxy.safeAreaInsets.bottom, AppStreamChromeBar.bottomFloor)
                                + AppStreamChromeBar.bottomMargin)
                }
            }
            .overlay(alignment: .bottom) {
                if keyboardActive {
                    AppStreamKeyboardOverlayView(
                        mode: isStreamingTerminal ? .terminal : .standard,
                        onText: { input.sendText($0) },
                        onKey: { keyCode, modifiers in input.pressKey(keyCode, modifiers: modifiers) },
                        onDismiss: { keyboardActive = false }
                    )
                    .allowsHitTesting(canInteract)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                if viewportZoom > 1.05 || viewportOffset != .zero {
                    zoomResetChip()
                }
            }
            .task(id: vm.streamedWindow?.windowID) {
                videoStartedAt = ProcessInfo.processInfo.systemUptime
                vm.cancelVideoRecovery()
                while !Task.isCancelled {
                    videoHealthCheckTime = ProcessInfo.processInfo.systemUptime
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                }
            }
            .onAppear {
                configureInteraction(viewSize: picture)
                vm.updateClientViewport(size: videoArea)
            }
            .onChangeCompat(of: proxy.size) { newSize in
                let area = videoViewport(in: newSize, safeAreaBottom: proxy.safeAreaInsets.bottom)
                let fitted = picturePlacement(in: area).size
                let fittedSize = CGSize(width: fitted.width, height: fitted.height)
                configureInteraction(viewSize: fittedSize)
                if !keyboardActive { vm.updateClientViewport(size: area) }
                viewportOffset = clampedViewportOffset(viewportOffset, zoom: viewportZoom, in: fittedSize)
            }
            .onChangeCompat(of: vm.streamedWindow) { _ in
                configureInteraction(viewSize: picture)
                viewportOffset = clampedViewportOffset(viewportOffset, zoom: viewportZoom, in: picture)
            }

        }
        // The status-bar band prints black while streaming, not the launcher art, so the
        // picture reads as one surface with the app-window above it.
        .background(Color.black.ignoresSafeArea())
        // Respect the keyboard region (`.container` only): iOS then lays the whole surface out
        // above the system keyboard exactly once, which is what keeps the keyboard deck visible.
        // Ignoring it as well as adding our own inset pad moved the deck twice and pushed it off
        // the top of the screen — the "buttons appear, then vanish" report. The top safe area is
        // respected so the streamed window never runs under the status bar.
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
    }

    /// The stream options, opened from the bar's trailing menu key. Everything the old top
    /// bar's menu offered lives here, in the same place the Assistant control surface keeps
    /// its options.
    @ViewBuilder
    private var streamOptionsMenu: some View {
        Section("View on this device") {
            // "Fit window" was documented in the gesture help but existed only on the
            // Assistant path. Both menus now offer the same two picture actions.
            Button("Fit window", systemImage: "arrow.down.right.and.arrow.up.left") {
                input.releaseDragLock()
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                    resetViewportZoom()
                }
                adjustsViewport = false
            }
            Button("Larger text (2×)", systemImage: "plus.magnifyingglass") {
                input.releaseDragLock()
                viewportZoom = 2
                viewportOffset = .zero
                adjustsViewport = true
            }
        }
        // "Auto" named a mechanism this preset does not have — it maps to the fixed
        // balanced preset, not to adaptation. The three options are named for the
        // outcome the user is choosing, matching the Assistant path's vocabulary.
        Picker("Picture quality", selection: $qualityMode) {
            Text("Sharper text").tag("quality")
            Text("Balanced").tag("auto")
            Text("Lower bandwidth").tag("performance")
        }
        if !isViewOnly, let streamed = vm.streamedApplication,
           ApplicationClosePolicy.canClose(streamed.bundleIdentifier) {
            Button("Close \(streamed.name)", systemImage: "xmark.app", role: .destructive) {
                closeChoice = streamed
            }
        }
        Button("Gesture help", systemImage: "hand.draw") { showsHelp = true }
        if bluetoothInput.isMouseConnected || bluetoothInput.isKeyboardConnected {
            Button("Bluetooth input", systemImage: "mouse") { showsBluetoothStatus = true }
        }
        if input.dragLocked {
            Button("Release drag lock", systemImage: "lock.open") { input.releaseDragLock() }
        }
        Button("Refresh video", systemImage: "arrow.clockwise") {
            sessionCoordinator.requestKeyframeRefresh(reason: "User requested video refresh")
        }
        Button("Reconnect", systemImage: "wifi") { Task { await sessionCoordinator.reconnectLast() } }
        Divider()
        Button("Disconnect from Mac", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: onClose)
    }

    /// Floating reset for the local zoom/pan, drawn like the Assistant surface's floating
    /// pills. The bar owns every primary control; this appears only while the picture is
    /// magnified or panned.
    private func zoomResetChip() -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                resetViewportZoom()
            }
        } label: {
            Text("1×")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.30), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7))
                .frame(minWidth: AppHostMetrics.iconControlTarget, minHeight: AppHostMetrics.iconControlTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .padding(.trailing, 14)
        .accessibilityLabel("Reset zoom")
        .accessibilityValue("Currently zoomed to \(Int(viewportZoom * 100)) percent")
    }

    /// The same floating glass dock as the Assistant path: apps, markup, keyboard, view,
    /// sizing and options. Disconnect lives in the options menu; hide stays pinned.
    ///
    /// The sizing cluster is deliberately *two* choices — Adaptive resize and Original Size.
    /// Local picture modes (fit/fill, zoom presets) were removed: they never fixed a window the
    /// Mac had not reshaped, and four sizing-looking controls in one deck made it unclear which
    /// one actually changed the Mac.
    /// Vamp Control's dock shows a caption under each control; Vamp Stream keeps compact glyphs.
    private var labelsChrome: Bool { chrome == .control }

    private var deckHeight: CGFloat {
        labelsChrome ? AppStreamChromeBar.labelledHeight : AppStreamChromeBar.height
    }

    private var streamChromePill: some View {
        AppStreamChromePill(height: deckHeight) {
            // Vamp Control gets a labelled way back; Vamp Stream keeps its established glyph.
            if chrome == .control {
                AppStreamChromeBackButton(title: "Apps") {
                    vm.backToApps()
                }
            } else {
                AppStreamChromeButton(
                    systemName: "square.grid.2x2",
                    accessibilityLabel: "Apps",
                    accessibilityValue: "Back to the Mac app list"
                ) {
                    vm.backToApps()
                }
            }

            AppStreamChromeButton(
                systemName: annotationStore.isVisible ? "pencil.slash" : "pencil.tip",
                isActive: annotationStore.isVisible,
                accessibilityLabel: "Markup",
                accessibilityValue: annotationStore.isVisible ? "On" : "Off",
                title: labelsChrome ? "Markup" : nil
            ) {
                annotationStore.isVisible.toggle()
            }

            if !isViewOnly {
                AppStreamChromeButton(
                    systemName: keyboardActive ? "keyboard.chevron.compact.down" : "keyboard",
                    isActive: keyboardActive,
                    accessibilityLabel: keyboardActive ? "Hide remote keyboard" : "Show remote keyboard",
                    accessibilityValue: keyboardActive ? "Visible" : "Hidden",
                    title: labelsChrome ? "Keyboard" : nil
                ) {
                    if !keyboardActive, isStreamingTerminal { input.focusTerminal() }
                    keyboardActive.toggle()
                }
            }

            AppStreamChromeButton(
                systemName: adjustsViewport ? "checkmark" : "viewfinder",
                isActive: adjustsViewport,
                accessibilityLabel: adjustsViewport ? "Done adjusting" : "Adjust view",
                accessibilityValue: adjustsViewport ? "Adjusting" : (isViewOnly ? "View Only" : "Controlling"),
                title: labelsChrome ? (adjustsViewport ? "Done" : "Adjust") : nil
            ) {
                if input.dragLocked { input.releaseDragLock() }
                adjustsViewport.toggle()
            }

            if !isViewOnly {
                AppStreamChromeMenu(
                    systemName: "aspectratio",
                    isActive: vm.sizingMode == .original,
                    isDimmed: !vm.supportsAdaptiveSizing,
                    accessibilityLabel: "Mac window sizing",
                    accessibilityValue: vm.sizingMode == .adaptive ? "Adaptive resize" : "Original Size",
                    title: labelsChrome ? "Size" : nil
                ) {
                    Button("Adaptive resize", systemImage: "rectangle.arrowtriangle.2.inward") {
                        vm.setSizingMode(.adaptive)
                    }
                    Button("Original Size", systemImage: "arrow.up.left.and.arrow.down.right") {
                        vm.setSizingMode(.original)
                    }
                }
            }

            AppStreamChromeMenu(
                systemName: input.dragLocked ? "lock.fill" : "ellipsis",
                isActive: input.dragLocked,
                accessibilityLabel: input.dragLocked ? "Stream options, drag lock on" : "Stream options",
                title: labelsChrome ? "More" : nil
            ) {
                streamOptionsMenu
            }

        } trailing: {
            AppStreamChromeDivider()

            AppStreamChromeButton(
                systemName: "eye.slash",
                isDimmed: true,
                accessibilityLabel: "Hide controls",
                title: labelsChrome ? "Hide" : nil
            ) {
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
                    keyboardActive = false
                    annotationStore.isVisible = false
                    controlsHidden = true
                }
            }
        }
    }

    private var isStreamingTerminal: Bool {
        guard let application = vm.streamedApplication else { return false }
        return AppStreamApplicationProfile.isTerminal(
            bundleIdentifier: application.bundleIdentifier,
            name: application.name)
    }

    /// The control deck floats over the bottom of the stream surface, so the picture must not be
    /// laid out underneath it. Reserving the band keeps the streamed app's own bottom controls (a
    /// send button, a toolbar) clear of the deck, and makes the Mac match the area the picture is
    /// actually drawn in instead of one taller than the phone can show.
    private func controlDeckBand(safeAreaBottom: CGFloat) -> CGFloat {
        AppStreamChromeBar.reservedBand(safeAreaBottom: safeAreaBottom, height: deckHeight)
    }

    /// The unobstructed part of the surface: the area the streamed picture may occupy.
    private func videoViewport(in size: CGSize, safeAreaBottom: CGFloat) -> CGSize {
        CGSize(
            width: max(size.width, 1),
            height: max(size.height - controlDeckBand(safeAreaBottom: safeAreaBottom), 1))
    }

    /// How the streamed picture is sized and anchored inside `area`, and therefore the geometry
    /// the input mapper must use so touches land where they are drawn.
    ///
    /// A Mac app can decline the exact shape it was asked for by a few percent, which used to
    /// show up as a black band between the picture and the control deck. `placePicture` absorbs a
    /// shortfall that small by covering the surface: the height becomes exact — so the app's own
    /// bottom controls stay put, clear of the deck — and the left and right edges crop slightly.
    private func picturePlacement(in area: CGSize) -> DisplayMappingEngine.StreamPicturePlacement {
        guard let window = vm.streamedWindow, window.pointWidth > 0, window.pointHeight > 0,
              area.width > 0, area.height > 0 else {
            return DisplayMappingEngine.StreamPicturePlacement(
                size: DesktopSize(width: max(area.width, 1), height: max(area.height, 1)),
                croppedFraction: 0)
        }
        return DisplayMappingEngine.placePicture(
            streamSize: DesktopSize(width: window.pointWidth, height: window.pointHeight),
            container: DesktopSize(width: area.width, height: area.height))
    }

    private func configureInteraction(viewSize: CGSize) {
        input.sessionID = environment.sessionCoordinator.activeSessionID
        input.isEnabled = canInteract
        // Keep the Bluetooth sensitivity the user chose in the status sheet applied across
        // window changes; `setWindow` rebuilds the mapper but must not reset pointer feel.
        input.pointerSensitivity = bluetoothInput.mouseSensitivity
        if let window = vm.streamedWindow {
            input.setWindow(DisplayDescriptor(
                id: window.windowID,
                name: "window",
                frame: DesktopRect(
                    origin: DesktopPoint(x: 0, y: 0),
                    size: DesktopSize(width: window.pointWidth, height: window.pointHeight)
                ),
                pixelSize: DesktopSize(width: window.pointWidth * window.scale, height: window.pointHeight * window.scale),
                scaleFactor: window.scale,
                isPrimary: true,
                isActive: true
            ))
        }
        input.setViewSize(DesktopSize(width: viewSize.width, height: viewSize.height))
        if let rect = input.cursorContentRect {
            cursorModel.setSurface(size: viewSize, contentRect: rect)
        }
    }

    private func updateViewportZoom(scale: CGFloat, focalPoint: CGPoint, in viewSize: CGSize) {
        let oldZoom = viewportZoom
        let newZoom = min(max(viewportZoom * scale, 1), 5)
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
        viewportZoom = 1
        viewportOffset = .zero
    }

    private func clampedViewportOffset(_ proposed: CGSize, zoom: CGFloat, in viewSize: CGSize) -> CGSize {
        guard zoom > 1, let window = vm.streamedWindow,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }

        let streamAspect = window.pointWidth / max(window.pointHeight, 1)
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

/// Keeps a locked host attached and offers the same authenticated Remote Unlock path as
/// Vamp Control. The password is cleared before it is sent and is never retained by this view.
@available(iOS 16.1, *)
private struct AppStreamLockedStateView: View {
    @ObservedObject var sessionCoordinator: ClientSessionCoordinator
    let onDisconnect: () -> Void

    @State private var password = ""
    @State private var isSubmitting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(StreamDesign.accent)

                Text("Mac is locked")
                    .font(.largeTitle.weight(.medium))
                    .foregroundStyle(PR.fg)

                Text(sessionCoordinator.canOfferRemoteUnlock ? "Enter your Mac login password to unlock remotely." : "Unlock your Mac in person to view its app windows here.")
                    .font(.subheadline)
                    .foregroundStyle(StreamDesign.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                if sessionCoordinator.canOfferRemoteUnlock {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .privacySensitive()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .foregroundStyle(PR.fg)
                        .streamGlass(radius: 20)
                        .frame(maxWidth: 340)
                        .onSubmit(submitUnlock)
                        .accessibilityLabel("Mac login password")

                    StreamPrimaryButton(title: isSubmitting ? "Unlocking…" : "Unlock Mac", symbol: "lock.open", isDisabled: password.isEmpty || isSubmitting, action: submitUnlock)
                        .frame(maxWidth: 340)

                    Text("Turn on Remote Unlock in \(VampProductIdentity.syncName) on your Mac.")
                        .font(.caption)
                        .foregroundStyle(StreamDesign.secondary)
                }
                VStack(spacing: 12) {
                    VampGlassActionButton(title: "Check connection", systemImage: "arrow.clockwise") { sessionCoordinator.sendConnectionProbe() }
                    VampGlassActionButton(title: "Back to Macs", systemImage: "chevron.left", action: onDisconnect)
                }
                .frame(maxWidth: 340)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollDismissesKeyboard(.interactively)
    }

    private func submitUnlock() {
        guard sessionCoordinator.canOfferRemoteUnlock, !password.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        let submittedPassword = password
        password = ""
        sessionCoordinator.sendUnlockPassword(submittedPassword)

        // A failed password intentionally produces no detailed authentication response. Re-enable
        // the form after a short delay so another attempt is possible while the Mac remains locked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            isSubmitting = false
        }
    }
}
/// One app row. Compact, on a quiet grouped surface, with a consistent icon/name/context/affordance
/// column layout. The supplied icon is drawn at its own aspect inside a fixed box — never stretched
/// — and gets no ornamental frame of its own.
struct AppStreamApplicationRow: View {
    let application: RemoteApplication
    let isFavorite: Bool
    let onOpen: () -> Void
    private static let icons = NSCache<NSString, UIImage>()

    /// Resolve the image as the row appears. A task attached to a lazy row can be cancelled
    /// while the list settles, leaving its placeholder in place until the row is recreated.
    /// Include the payload in the cache key so a refreshed icon replaces the previous one.
    private var icon: UIImage? {
        guard let encoded = application.iconPNGBase64,
              !encoded.isEmpty else { return nil }
        let key = "\(application.id):\(encoded.count):\(encoded.hashValue)" as NSString
        if let cached = Self.icons.object(forKey: key) { return cached }
        guard let data = Data(base64Encoded: encoded),
              let decoded = UIImage(data: data) else { return nil }
        Self.icons.countLimit = 256
        Self.icons.setObject(decoded, forKey: key)
        return decoded
    }

    /// A disclosure chevron belongs only where another selection level actually follows: an app
    /// with several windows offers the Windows menu. An installed app that simply launches, or a
    /// running app with one window, opens directly and must not imply a submenu.
    private var hasWindowChoices: Bool { application.windowIDs.count > 1 }

    /// Meaningful context for a running app is how many windows it has, which is also what decides
    /// whether the Windows picker is reachable. Raw pixel dimensions stay out of the list.
    private var contextLine: String? {
        if application.isActive { return "Active now" }
        if application.isRunning {
            switch application.windowIDs.count {
            case 0: return "Running · no open window"
            case 1: return "Running · 1 window"
            default: return "Running · \(application.windowIDs.count) windows"
            }
        }
        // An installed app needs no "Installed · tap to open" narration on every row; the row is
        // already a button and the section is already "All Apps".
        return nil
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: AppSpacing.sm) {
                Group {
                    if let icon {
                        Image(uiImage: icon)
                            .resizable()
                            .interpolation(.high)
                            // Fit, not fill: a non-square icon stays undistorted.
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "app.dashed")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(9)
                            .foregroundStyle(PR.fg2)
                            .background(PR.fg.opacity(0.08), in: RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous))
                    }
                }
                .frame(width: AppHostMetrics.appIcon, height: AppHostMetrics.appIcon)
                .clipShape(RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(application.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PR.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    if let contextLine {
                        Text(contextLine)
                            .font(.caption)
                            .foregroundStyle(PR.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(StreamDesign.accent)
                        .accessibilityLabel("Favorite")
                }
                if hasWindowChoices {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PR.dim)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, AppHostMetrics.cardPadding)
            .padding(.vertical, AppSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: AppHostMetrics.rowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .accessibilityLabel(application.name)
        .accessibilityValue(Text(verbatim: contextLine ?? String(localized: "Installed"))
            + (isFavorite ? Text(", Favorite") : Text("")))
        .accessibilityHint(
            hasWindowChoices
                ? "Opens the app. Long-press for more actions, including choosing a window."
                : "Opens the app. Long-press for more actions.")
    }
}


#endif
