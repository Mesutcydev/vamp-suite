import AppKit
import CoreImage
import SwiftUI
import SharedModels
import SharedProtocol
import SharedUtilities
import TransportWebRTC
import UniformTypeIdentifiers

/// The active streaming screen: remote video with full keyboard/mouse control,
/// a control bar (display switching, clipboard sync, audio mute, stats) and the
/// same renderer/session wiring the iOS RemoteDesktopView performs.
struct MacRemoteSessionView: View {
    @ObservedObject var environment: ClientAppEnvironment
    @ObservedObject private var coordinator: ClientSessionCoordinator
    @ObservedObject private var displayLayoutVM: DisplayLayoutViewModel
    /// Owned by `MacShellView` so it outlives a transient `.error` phase.
    @ObservedObject private var reconnectCoordinator: ClientReconnectCoordinator

    @StateObject private var rendererVM: VideoRendererViewModel
    @StateObject private var multiDisplay: MultiDisplayRenderer
    @State private var multiActive = false
    @State private var browsingApps = false
    @State private var desktopDisplays: [DisplayDescriptor] = []
    @State private var pendingDesktopID: String?
    @StateObject private var inputController: MacRemoteInputController
    @StateObject private var statsVM: SessionStatsViewModel
    @StateObject private var audioRenderer = ClientAudioRenderer()
    @StateObject private var clipboardSync = ClientClipboardSyncManager()
    @StateObject private var fileTransferManager: ClientFileTransferManager
    @StateObject private var terminalSession = ClientTerminalSessionManager()
    /// Drives the app browser for hosts that stream a single window (Vamp Sync).
    @StateObject private var appStream: AppStreamViewModel
    @ObservedObject private var nicknames = MacHostNicknameStore.shared

    @State private var displaySwitchObserverTask: Task<Void, Never>?
    @State private var isTerminalPresented = false

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// Transient confirmation toast (e.g. after saving a screenshot).
    @State private var sessionToast: String?
    @State private var sessionToastIsError = false

    /// Remote login-screen unlock: when the host reports it's locked, the client
    /// shows a password field and sends it over the control channel (the host
    /// types it into the login window). Mirrors the iOS client's unlock overlay.
    @State private var unlockPasswordText = ""
    @State private var isUnlockSubmitting = false
    @FocusState private var unlockPasswordFieldFocused: Bool
    @State private var showScreenAI = false
    @State private var keyboardFocused = false
    @State private var isCompactToolbar = true
    @State private var showsConnectionDetails = false
    @State private var showsKeyboardHelp = false
    @State private var showsQualitySettings = false

    @AppStorage("client.clipboard.enabled") private var clipboardEnabled = true
    @AppStorage("com.remotedesktop.client.filetransfer.enabled") private var fileTransferEnabled = true
    @State private var preferences = MacConnectionPreferences()
    @State private var loadedPreferenceKey: String?
    private var displayMode: DisplayMappingEngine.DisplayMode {
        DisplayMappingEngine.DisplayMode(rawValue: preferences.displayModeRaw) ?? .fitDisplay
    }

    init(environment: ClientAppEnvironment, reconnectCoordinator: ClientReconnectCoordinator) {
        self.environment = environment
        self.coordinator = environment.sessionCoordinator
        self.displayLayoutVM = environment.displayLayoutViewModel
        self.reconnectCoordinator = reconnectCoordinator
        let renderer = VideoRendererViewModel(webRTCSessionManager: environment.webRTCSessionManager)
        _rendererVM = StateObject(wrappedValue: renderer)
        _multiDisplay = StateObject(wrappedValue: MultiDisplayRenderer(
            webRTCSessionManager: environment.webRTCSessionManager, primary: renderer
        ))
        _inputController = StateObject(wrappedValue: MacRemoteInputController(
            sessionManager: environment.webRTCSessionManager
        ))
        _statsVM = StateObject(wrappedValue: SessionStatsViewModel(
            webRTCSessionManager: environment.webRTCSessionManager,
            sessionCoordinator: environment.sessionCoordinator
        ))
        _fileTransferManager = StateObject(wrappedValue: ClientFileTransferManager(
            webRTCSessionManager: environment.webRTCSessionManager,
            sessionCoordinator: environment.sessionCoordinator,
            clientIdentity: environment.clientIdentity
        ))
        _appStream = StateObject(wrappedValue: AppStreamViewModel(environment: environment))
    }

    /// Honours a local rename for the whole session, not just the host list.
    private var hostDisplayName: String {
        if let endpoint = coordinator.lastEndpoint {
            return nicknames.displayName(for: endpoint)
        }
        return coordinator.connectedHostName ?? "Connected"
    }

    // MARK: - App streaming (Vamp Sync)

    /// True when the host negotiated App Streaming but has no display stream to
    /// offer — Vamp Sync. Such a host starts no capture at all until the client
    /// names a window, so the session must present the app browser instead of
    /// waiting for video that is never coming.
    private var isAppStreamingOnlyHost: Bool {
        coordinator.appStreamingOnlySession
    }

    /// The browser replaces the video surface until the host confirms a target.
    private var showsAppBrowser: Bool {
        guard isAppStreamingOnlyHost || browsingApps else { return false }
        if case .streaming = appStream.status { return false }
        return true
    }

    private var preferenceKey: String? { coordinator.lastEndpoint.map { MacHostNicknameStore.key(for: $0) } }

    private func loadPreferences() {
        guard let key = preferenceKey, key != loadedPreferenceKey else { return }
        preferences = MacConnectionPreferenceStore().load(for: key)
        loadedPreferenceKey = key
    }

    private var inputReadiness: MacInputReadiness {
        .resolve(connected: coordinator.activeSessionID != nil
                    && (coordinator.phase == .receiving || coordinator.phase == .waitingForMedia)
                    && !reconnectCoordinator.isReconnecting && !coordinator.isReconnectInProgress,
                 locked: coordinator.hostLockState == .lockedOrLoginWindow,
                 choosingApp: showsAppBrowser,
                 receivingVideo: rendererVM.isReceiving && !displayLayoutVM.isSwitchingDisplay,
                 viewOnly: environment.prefersViewOnly)
    }

    var body: some View {
        ZStack(alignment: .top) {
            MacVideoStreamView(
                renderer: rendererVM,
                input: inputController,
                isInputEnabled: inputReadiness.canSendInput,
                usesLocalCursor: coordinator.negotiatedCapabilities?.supportsCursorlessCapture == true,
                displayMode: displayMode,
                onKeyboardFocusChange: { keyboardFocused = $0 },
                keepsDisplayShortcutsLocal: preferences.keepsDisplayShortcutsLocal
            )
            .ignoresSafeArea()

            // Two distinct loss paths must both surface the overlay:
            // 1. transport-level .disconnected/.failed → reconnectCoordinator.isReconnecting
            // 2. half-open connection (host sleep, AP roam with TCP kept alive) — the
            //    transport still reports .connected, only the pong-liveness watchdog
            //    notices and flips coordinator.phase to .error while it auto-retries.
            //    Without this branch the view kept showing the last frozen frame with
            //    no feedback and the app looked hung until the user force-quit it.
            if reconnectCoordinator.isReconnecting || coordinator.phase == .error {
                reconnectOverlay
            } else if showsAppBrowser {
                MacAppStreamPicker(
                    vm: appStream,
                    hostName: hostDisplayName,
                    onDisconnect: { Task { await coordinator.endSession() } }
                )
            } else if !rendererVM.isReceiving {
                waitingForVideoOverlay
            }

            VStack(spacing: 8) {
                MacKeyboardFocusHint(readiness: inputReadiness, keyboardFocused: keyboardFocused)

                if let warning = displayLayoutVM.mappingWarningMessage, !showsAppBrowser, appStream.streamedWindow == nil {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .macGlassSurface(in: Capsule())
                }
                if let transfer = fileTransferManager.activeTransfer {
                    fileTransferPanel(transfer)
                }
                if multiActive {
                    MultiDisplayThumbnailStrip(multi: multiDisplay, onFocus: focusDisplay)
                }
                multiDisplayToggle
            }
            .padding(.top, 10)
            .padding(.horizontal, 12)
        }
        .background(Color.black)
        // Tell an app-streaming host the shape of the surface it is streaming
        // into, so it fits the window to this window instead of guessing.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { appStream.updateClientViewport(size: proxy.size) }
                    .onChange(of: proxy.size) { appStream.updateClientViewport(size: $0) }
            }
        }
        .modifier(MacSessionWidthReader(isCompact: $isCompactToolbar))
        .toolbar { sessionWindowToolbar.compactSessionChrome() }
        .focusedSceneValue(\.remoteDisplayMode, $preferences.displayModeRaw)
        .focusedSceneValue(\.keepsDisplayShortcutsLocal, preferences.keepsDisplayShortcutsLocal)
        .onAppear(perform: loadPreferences)
        .onChange(of: preferences.displayModeRaw) { raw in
            if raw == DisplayMappingEngine.DisplayMode.actualSize.rawValue { resizeWindowToActualSize() }
        }
        .onChange(of: preferenceKey) { _ in loadPreferences() }
        .onChange(of: preferences) { value in
            guard let key = loadedPreferenceKey, key == preferenceKey else { return }
            MacConnectionPreferenceStore().save(value, for: key)
        }
        .sheet(isPresented: $showsQualitySettings) {
            MacSessionQualitySettings(selection: Binding(
                get: { coordinator.activeQualityPreset },
                set: { preset in
                    guard coordinator.phase == .receiving else { return }
                    environment.preferredQualityPreset = preset
                    coordinator.setPreferredQuality(preset)
                }), supportsUltra: environment.isUltraQualityEntitled,
                isConnected: coordinator.phase == .receiving)
        }
        .sheet(isPresented: $showsKeyboardHelp) { MacKeyboardHelp(keepsDisplayShortcutsLocal: $preferences.keepsDisplayShortcutsLocal) }
        .overlay(alignment: .bottomLeading) {
            if environment.showsStatsOverlay && !showsAppBrowser {
                SessionToolbarLiveStats(framesPerSecond: statsVM.metrics.framesPerSecond,
                    latencyMs: statsVM.metrics.latencyMs, bitrateKbps: statsVM.metrics.bitrateKbps)
                    .padding(12).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let sessionToast {
                sessionToastView(sessionToast, isError: sessionToastIsError)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if coordinator.hostLockState == .lockedOrLoginWindow {
                hostLockedOverlay
            }
        }
        .onAppear(perform: startSession)
        .onDisappear {
            multiDisplay.stopAll()
            appStream.stop()
            stopSession()
        }
        .onChange(of: coordinator.isReconnectInProgress) { reconnecting in
            guard reconnecting else { return }
            // A fresh host attachment starts with its negotiated source. Do not
            // keep a stale window coordinate map over a newly captured desktop.
            appStream.stop()
            browsingApps = false
            pendingDesktopID = nil
            desktopDisplays = []
        }
        .onChange(of: coordinator.appStreamingOnlySession) { _ in
            startAppStreamingIfNeeded()
        }
        .onChange(of: coordinator.hostLockState) { lockState in
            guard showsAppBrowser else { return }
            // A locked Mac rejects app inventory and launch commands outright,
            // so pause the bounded retries instead of burning them on refusals.
            if lockState == .lockedOrLoginWindow {
                appStream.pauseForHostLock()
            } else {
                appStream.resumeAfterHostUnlock()
            }
        }
        .onChange(of: coordinator.activeSessionID) { sessionID in
            inputController.sessionID = sessionID
            if let sessionID {
                recordReconnectState(sessionID: sessionID)
                clipboardSync.activate(sessionID: sessionID, send: { [weak coordinator] envelope in
                    coordinator?.sendClipboardEnvelope(envelope)
                })
                terminalSession.activate(sessionID: sessionID, send: { [weak coordinator] envelope in
                    coordinator?.sendClipboardEnvelope(envelope)
                })
            }
        }
        .onChange(of: appStream.streamedWindow) { _ in refreshMapping() }
        .onChange(of: displayLayoutVM.selectedDisplayID) { _ in refreshMapping() }
        .onChange(of: displayLayoutVM.streamConfiguration) { _ in refreshMapping() }
        .onChange(of: rendererVM.frameSize) { frameSize in
            guard let frameSize else { return }
            displayLayoutVM.noteFirstFrameAfterSwitch()
            if appStream.streamedWindow != nil || showsAppBrowser {
                refreshMapping()
                return
            }
            if displayLayoutVM.reconcileStreamFrameSize(frameSize) {
                coordinator.requestKeyframeRefresh(reason: "display mapping frame size mismatch")
            } else {
                displayLayoutVM.noteMissingStreamConfigurationIfNeeded(frameSize: frameSize)
            }
            refreshMapping()
        }
        .alert("Incoming File", isPresented: incomingFilePromptBinding, presenting: fileTransferManager.incomingPrompt) { _ in
            Button("Decline", role: .cancel) { fileTransferManager.rejectIncomingTransfer() }
            Button("Accept") { fileTransferManager.acceptIncomingTransfer() }
        } message: { prompt in
            Text("\(coordinator.connectedHostName ?? "Your Mac") wants to send “\(prompt.fileName)” (\(Self.byteString(prompt.fileSize))). Save it to this Mac?")
        }
        .onChange(of: fileTransferManager.isReceivedFileSavePresented) { presented in
            if presented { presentReceivedFileSave() }
        }
        .sheet(isPresented: $isTerminalPresented) {
            MacTerminalScreen(session: terminalSession)
        }
        .sheet(isPresented: $showScreenAI) {
            MacScreenAIView(
                frameProvider: { rendererVM.latestPixelBuffer },
                onSendText: { if inputReadiness.canSendInput { inputController.insertText($0) } },
                onSendKey: { keyCode in
                    guard inputReadiness.canSendInput else { return }
                    inputController.keyEvent(keyCode: keyCode, action: .down, modifiers: [])
                    inputController.keyEvent(keyCode: keyCode, action: .up, modifiers: [])
                }
            )
        }
    }

    // MARK: - Window toolbar (native title-bar chrome)

    @ToolbarContentBuilder
    private var sessionWindowToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { showsConnectionDetails.toggle() } label: {
                SessionToolbarStatusPill(hostName: hostDisplayName,
                    qualityColor: inputReadiness == .reconnecting ? .orange : networkQualityColor,
                    qualityLabel: inputReadiness == .reconnecting ? "Reconnecting" : coordinator.activeQualityPreset.rawValue.capitalized,
                    differentiateWithoutColor: differentiateWithoutColor)
                    .frame(maxWidth: isCompactToolbar ? 170 : 220)
            }
            .buttonStyle(.plain)
            .help("Connection details")
            .popover(isPresented: $showsConnectionDetails) {
                MacConnectionDetails(hostName: hostDisplayName,
                    transportConnected: coordinator.phase == .receiving || coordinator.phase == .waitingForMedia,
                    receivingVideo: rendererVM.isReceiving, readiness: inputReadiness,
                    keyboardFocused: keyboardFocused, unavailable: unavailableFeatures)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if !isAppStreamingOnlyHost {
                    ForEach(desktopDisplays.isEmpty ? displayLayoutVM.displays : desktopDisplays) { display in
                        Button { requestDesktop(to: display.id) } label: {
                            Label(display.name, systemImage: "display")
                        }
                    }
                    Divider()
                } else {
                    Text("Desktop requires an updated Vamp Sync host.")
                    Divider()
                }
                if coordinator.negotiatedCapabilities?.supportsAppStreaming == true {
                    Button("Choose an app…", action: browseApps)
                        .keyboardShortcut("a", modifiers: [.control, .option])
                }
            } label: {
                Label(isAppStreamingOnlyHost || appStream.streamedWindow != nil || showsAppBrowser ? "App" : "Desktop",
                      systemImage: isAppStreamingOnlyHost || appStream.streamedWindow != nil || showsAppBrowser ? "macwindow" : "display")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .disabled(displayLayoutVM.isSwitchingDisplay)
            .help("Choose the full desktop or an application window")
        }
        ToolbarItem(placement: .primaryAction) { sessionToolbarDisplaySizingMenu }
        ToolbarItem(placement: .primaryAction) {
            MacSessionAccessButton(viewOnly: $environment.prefersViewOnly,
                readiness: inputReadiness, keyboardFocused: keyboardFocused)
        }
        ToolbarItem(placement: .primaryAction) {
            MacSessionToolsMenu(actions: sessionActions, canSendInput: inputReadiness.canSendInput,
                sendKey: { key in
                    guard inputReadiness.canSendInput else { return }
                    inputController.keyPress(keyCode: key.keyCode, modifiers: key.modifiers)
                }, showKeyboardHelp: { showsKeyboardHelp = true }, showsStats: $environment.showsStatsOverlay, quickActionID: $preferences.quickActionID)
        }
        if !isCompactToolbar, let quick = sessionActions.first(where: { $0.id == preferences.quickActionID }) {
            ToolbarItem(placement: .primaryAction) { MacSessionQuickAction(action: quick) }
        }
        ToolbarItem(placement: .primaryAction) {
            SessionToolbarDisconnectButton { Task { await coordinator.endSession() } }
        }
    }

    private var unavailableFeatures: [String] {
        var features: [String] = []
        if coordinator.negotiatedCapabilities?.supportsTerminal != true { features.append("Terminal") }
        if coordinator.negotiatedCapabilities?.supportsAudio != true { features.append("Remote audio") }
        if !clipboardEnabled { features.append("Clipboard (disabled in Settings)") }
        if !fileTransferEnabled { features.append("File transfer (disabled in Settings)") }
        return features
    }

    private var sessionActions: [MacSessionAction] {
        var actions: [MacSessionAction] = [
            .init(id: "quality", title: "Stream Quality…", symbol: "dial.high",
                  enabled: coordinator.phase == .receiving, perform: { showsQualitySettings = true })
        ]
        if clipboardEnabled {
            actions.append(.init(id: "sendClipboard", title: "Send Clipboard to Host", symbol: "doc.on.clipboard",
                enabled: inputReadiness.canSendInput, shortcut: "v", perform: {
                    guard inputReadiness.canSendInput else { return }; clipboardSync.pushToHost()
                }))
            actions.append(.init(id: "fetchClipboard", title: "Fetch Clipboard from Host", symbol: "clipboard",
                enabled: inputReadiness.canSendInput, shortcut: "c", perform: {
                    guard inputReadiness.canSendInput else { return }; clipboardSync.requestFromHost()
                }))
        }
        actions.append(.init(id: "screenshot", title: "Save Screenshot…", symbol: "camera",
            enabled: rendererVM.isReceiving, shortcut: "s", perform: captureScreenshot))
        if fileTransferEnabled {
            actions.append(.init(id: "file", title: "Send File…", symbol: "arrow.up.doc",
                enabled: inputReadiness.canSendInput, perform: {
                    guard inputReadiness.canSendInput else { return }; presentSendFilePicker()
                }))
        }
        if coordinator.negotiatedCapabilities?.supportsTerminal == true {
            actions.append(.init(id: "terminal", title: "Open Terminal…", symbol: "terminal",
                enabled: inputReadiness.canSendInput, shortcut: "t", perform: { isTerminalPresented = true }))
        }
        actions.append(.init(id: "screenAI", title: "Screen AI…", symbol: "sparkles",
            enabled: rendererVM.isReceiving, perform: { showScreenAI = true }))
        if coordinator.negotiatedCapabilities?.supportsAudio == true {
            actions.append(.init(id: "audio", title: audioRenderer.isMuted ? "Unmute Remote Audio" : "Mute Remote Audio",
                symbol: audioRenderer.isMuted ? "speaker.slash" : "speaker.wave.2", perform: { audioRenderer.isMuted.toggle() }))
        }
        return actions
    }

    /// First-class Fit Display control. Kept as its own toolbar item so its
    /// help tag cannot leak onto Screen AI (AppKit collapses `.help` when
    /// several buttons share one `ToolbarItem`).
    private var sessionToolbarDisplaySizingMenu: some View {
        Menu {
            Button {
                preferences.displayModeRaw = DisplayMappingEngine.DisplayMode.fitDisplay.rawValue
            } label: {
                Label("Fit Display", systemImage: displayMode == .fitDisplay ? "checkmark" : "rectangle.inset.filled")
            }

            Button {
                preferences.displayModeRaw = DisplayMappingEngine.DisplayMode.fillScreen.rawValue
            } label: {
                Label("Fill Window", systemImage: displayMode == .fillScreen ? "checkmark" : "arrow.up.left.and.arrow.down.right")
            }

            Button {
                preferences.displayModeRaw = DisplayMappingEngine.DisplayMode.actualSize.rawValue
            } label: {
                Label("Actual Size", systemImage: displayMode == .actualSize ? "checkmark" : "1.magnifyingglass")
            }

            Divider()

            Button {
                if displayMode == .actualSize {
                    resizeWindowToActualSize()
                } else {
                    matchWindowToDisplay()
                }
            } label: {
                Label("Match Window to Display", systemImage: "aspectratio")
            }
            .disabled(rendererVM.frameSize == nil)
            .help(displayMode == .actualSize
                  ? "Resize the window so the stream renders 1:1"
                  : "Resize the window to the display's aspect ratio")
        } label: {
            SessionToolbarToggleLabel(
                title: isCompactToolbar ? compactDisplaySizingTitle : displaySizingTitle,
                systemImage: displaySizingSymbol,
                isActive: displayMode != .fitDisplay
            )
        }
        .menuStyle(.borderlessButton)
        .help(displaySizingHelp)
        .accessibilityLabel("Remote display sizing")
        .accessibilityValue(displaySizingTitle)
    }

    private var compactDisplaySizingTitle: String {
        switch displayMode {
        case .fitDisplay: "Fit"
        case .fillScreen: "Fill"
        case .actualSize: "1:1"
        }
    }

    private var displaySizingTitle: String {
        switch displayMode {
        case .fitDisplay: return "Fit Display"
        case .fillScreen: return "Fill Window"
        case .actualSize: return "Actual Size"
        }
    }

    private var displaySizingSymbol: String {
        switch displayMode {
        case .fitDisplay: return "rectangle.inset.filled"
        case .fillScreen: return "arrow.up.left.and.arrow.down.right"
        case .actualSize: return "1.magnifyingglass"
        }
    }

    private var displaySizingHelp: String {
        switch displayMode {
        case .fitDisplay: return "Fit Display — show the whole remote screen"
        case .fillScreen: return "Fill Window — edges may be cropped"
        case .actualSize: return "Actual Size — 1:1 remote pixels"
        }
    }

    private var appStreamedAppName: String? {
        if case .streaming(_, let name) = appStream.status { return name }
        return nil
    }

    private func matchWindowToDisplay() {
        guard let frameSize = rendererVM.frameSize,
              frameSize.width > 0,
              frameSize.height > 0,
              let window = NSApp.keyWindow,
              let screen = window.screen ?? NSScreen.main else { return }

        let currentContent = window.contentRect(forFrameRect: window.frame)
        let streamAspect = frameSize.width / frameSize.height
        let maximumContentHeight = max(320, screen.visibleFrame.height - (window.frame.height - currentContent.height))

        var targetContentSize = NSSize(
            width: currentContent.width,
            height: currentContent.width / streamAspect
        )
        if targetContentSize.height > maximumContentHeight {
            targetContentSize.height = maximumContentHeight
            targetContentSize.width = maximumContentHeight * streamAspect
        }

        var targetContent = currentContent
        targetContent.size = targetContentSize
        var targetFrame = window.frameRect(forContentRect: targetContent)
        targetFrame.origin.x = min(
            max(window.frame.minX, screen.visibleFrame.minX),
            screen.visibleFrame.maxX - targetFrame.width
        )
        targetFrame.origin.y = min(
            max(window.frame.maxY - targetFrame.height, screen.visibleFrame.minY),
            screen.visibleFrame.maxY - targetFrame.height
        )
        window.setFrame(targetFrame, display: true, animate: true)
    }

    /// Resizes the session window so the stream renders at its native 1:1
    /// size (Actual Size). If the stream is larger than the visible screen
    /// area, the window clamps to the largest aspect-preserving size that
    /// fits — the same fallback the content-rect mapper uses.
    private func resizeWindowToActualSize() {
        guard let frameSize = rendererVM.frameSize,
              frameSize.width > 0,
              frameSize.height > 0,
              let window = NSApp.keyWindow,
              let screen = window.screen ?? NSScreen.main else { return }

        let scale = screen.backingScaleFactor
        let currentContent = window.contentRect(forFrameRect: window.frame)
        let chromeHeight = window.frame.height - currentContent.height
        let maximumContentHeight = max(320, screen.visibleFrame.height - chromeHeight)
        let maximumContentWidth = screen.visibleFrame.width

        var targetContentSize = NSSize(
            width: frameSize.width / scale,
            height: frameSize.height / scale
        )
        if targetContentSize.width > maximumContentWidth || targetContentSize.height > maximumContentHeight {
            let streamAspect = frameSize.width / frameSize.height
            targetContentSize.width = min(maximumContentWidth, maximumContentHeight * streamAspect)
            targetContentSize.height = targetContentSize.width / streamAspect
        }

        var targetContent = currentContent
        targetContent.size = targetContentSize
        var targetFrame = window.frameRect(forContentRect: targetContent)
        targetFrame.origin.x = min(
            max(window.frame.minX, screen.visibleFrame.minX),
            screen.visibleFrame.maxX - targetFrame.width
        )
        targetFrame.origin.y = min(
            max(window.frame.maxY - targetFrame.height, screen.visibleFrame.minY),
            screen.visibleFrame.maxY - targetFrame.height
        )
        window.setFrame(targetFrame, display: true, animate: true)
    }

    // MARK: - Multi-display (Tier 4a)

    @ViewBuilder private var multiDisplayToggle: some View {
        let displays = displayLayoutVM.layout?.displays ?? []
        if displays.count > 1 {
            Button(action: toggleMultiDisplay) {
                Label(multiActive ? "Showing All Displays" : "Show All Displays",
                      systemImage: multiActive ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .macGlassSurface(in: Capsule(), isInteractive: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var currentPrimaryDisplayID: String? {
        displayLayoutVM.hostSelectedDisplayID
            ?? displayLayoutVM.layout?.displays.first(where: \.isPrimary)?.id
            ?? displayLayoutVM.layout?.displays.first?.id
    }

    private func toggleMultiDisplay() {
        let displays = displayLayoutVM.layout?.displays ?? []
        guard displays.count > 1, let primary = currentPrimaryDisplayID else { return }
        if multiActive {
            multiActive = false
            multiDisplay.setActive(count: 1)
            coordinator.setStreamedDisplays([primary])
        } else {
            let ordered = [primary] + displays.map(\.id).filter { $0 != primary }
            coordinator.setStreamedDisplays(ordered)
            multiDisplay.setActive(count: ordered.count)
            multiActive = true
        }
    }

    private func focusDisplay(_ wireID: UInt8) {
        multiDisplay.focus(wireID)
        coordinator.requestKeyframeRefresh(reason: "multi-display focus")
    }

    /// Bridges the manager's optional prompt to the alert's Bool binding; a
    /// dismissal that isn't an explicit Accept counts as a decline.
    private var incomingFilePromptBinding: Binding<Bool> {
        Binding(
            get: { fileTransferManager.incomingPrompt != nil },
            set: { isPresented in
                if !isPresented, fileTransferManager.incomingPrompt != nil {
                    fileTransferManager.rejectIncomingTransfer()
                }
            }
        )
    }

    // MARK: - Overlays

    private var waitingForVideoOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(displayLayoutVM.isSwitchingDisplay ? "Switching display…" : "Waiting for video…")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var reconnectOverlay: some View {
        let status = reconnectCoordinator.reconnectStatus
        // No full-frame scrim — keep the last remote frame at full brightness.
        return VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Connection lost — reconnecting…")
                .font(.headline)
                .foregroundStyle(.primary)
            if status.maxAttempts > 0, status.attempt > 0 {
                Text("Attempt \(status.attempt) of \(status.maxAttempts)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = status.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            HStack(spacing: 12) {
                Button("Retry Now") { reconnectCoordinator.retryNow() }
                    .buttonStyle(.borderedProminent)
                Button("Disconnect", role: .destructive) {
                    reconnectCoordinator.cancelReconnect()
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.top, 2)
        }
        .padding(32)
        .macGlassSurface(
            in: RoundedRectangle(cornerRadius: MacBrand.cardCornerRadius, style: .continuous),
            isInteractive: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var networkQualityColor: Color {
        switch statsVM.quality {
        case .excellent, .good: return .green
        case .fair: return .yellow
        case .poor: return .red
        case .reconnecting: return .orange
        }
    }

    // MARK: - Session lifecycle

    /// Vamp Sync publishes its app registry only on request, and capabilities
    /// can land either side of this view appearing — so this runs from both
    /// `onAppear` and the capability change.
    private func startAppStreamingIfNeeded() {
        guard isAppStreamingOnlyHost else { return }
        appStream.start()
        if case .idle = appStream.status {
            appStream.requestApplicationList()
        }
    }

    private func startSession() {
        startAppStreamingIfNeeded()
        inputController.sessionID = coordinator.activeSessionID
        inputController.isEnabled = inputReadiness.canSendInput
        refreshMapping()

        // Reconnect: drive recovery through the session coordinator's full connect
        // flow (so phase transitions back to .receiving cleanly), mirroring iOS.
        reconnectCoordinator.onRebuildSignaling = { [weak coordinator] sessionID, qualityPreset in
            coordinator?.restartSignalingListener(sessionID: sessionID, qualityPreset: qualityPreset)
        }
        reconnectCoordinator.onPerformReconnect = { [weak coordinator] in
            guard let coordinator else { throw ReconnectError.coordinatorDeallocated }
            try await coordinator.forceReconnectLast()
        }
        // When reconnect is exhausted or the user cancels it, end the session.
        reconnectCoordinator.onRequestSessionDisconnect = { [weak coordinator] in
            Task { await coordinator?.endSession() }
        }
        reconnectCoordinator.startObserving()
        if let sessionID = coordinator.activeSessionID {
            recordReconnectState(sessionID: sessionID)
        }

        rendererVM.onNeedsKeyframe = { [weak coordinator] in
            coordinator?.requestKeyframeRefresh(reason: "decoder requested keyframe")
        }
        multiDisplay.onNeedsKeyframe = { [weak coordinator] in
            coordinator?.requestKeyframeRefresh(reason: "secondary display keyframe")
        }
        rendererVM.startReceiving()

        audioRenderer.start()
        coordinator.onAudioFrame = { [weak audioRenderer] message in
            audioRenderer?.receive(message)
        }

        if let sessionID = coordinator.activeSessionID {
            clipboardSync.activate(sessionID: sessionID, send: { [weak coordinator] envelope in
                coordinator?.sendClipboardEnvelope(envelope)
            })
            terminalSession.activate(sessionID: sessionID, send: { [weak coordinator] envelope in
                coordinator?.sendClipboardEnvelope(envelope)
            })
        }
        coordinator.onClipboardSync = { [weak clipboardSync] message in
            clipboardSync?.receive(message)
        }
        coordinator.onTerminalOutput = { [weak terminalSession] message in
            terminalSession?.receiveOutput(message)
        }
        coordinator.onTerminalClose = { [weak terminalSession] message in
            terminalSession?.receiveClose(message)
        }

        statsVM.start(refreshInterval: environment.lowPowerModeEnabled ? 1.5 : 1.0)
        fileTransferManager.startObserving()

        displaySwitchObserverTask = Task {
            for await envelope in environment.webRTCSessionManager.receiveDataMessages() {
                guard !Task.isCancelled else { break }
                guard envelope.kind == .displaySwitch,
                      let result = try? envelope.decodeDisplaySwitchResult() else { continue }
                handleDisplaySwitchResult(result)
            }
        }
    }

    // MARK: - Remote unlock

    private var hostLockedOverlay: some View {
        ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                Text("Mac is locked")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text("Enter your Mac login password to unlock it remotely.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                SecureField("Password", text: $unlockPasswordText)
                    .focused($unlockPasswordFieldFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .macGlassSurface(
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                        isInteractive: true
                    )
                    .foregroundStyle(.white)
                    .frame(maxWidth: 300)
                    .onSubmit(submitUnlock)
                Button(action: submitUnlock) {
                    Text("Unlock")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .background(
                            Color.accentColor.opacity(unlockPasswordText.isEmpty || isUnlockSubmitting ? 0.4 : 1.0),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(unlockPasswordText.isEmpty || isUnlockSubmitting)
            }
            .padding(36)
        }
        .onAppear {
            focusUnlockPasswordField()
        }
        .onChange(of: coordinator.hostLockState) { newState in
            if newState == .unlockedActiveSession {
                unlockPasswordText = ""
                isUnlockSubmitting = false
                unlockPasswordFieldFocused = false
            } else if newState == .lockedOrLoginWindow {
                focusUnlockPasswordField()
            }
        }
    }

    private func submitUnlock() {
        guard !unlockPasswordText.isEmpty, !isUnlockSubmitting else { return }
        isUnlockSubmitting = true
        let password = unlockPasswordText
        unlockPasswordText = ""
        coordinator.sendUnlockPassword(password)
        // Re-enable after a short window so the user can retry if it didn't take.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            isUnlockSubmitting = false
            if coordinator.hostLockState == .lockedOrLoginWindow {
                focusUnlockPasswordField()
            }
        }
    }

    private func focusUnlockPasswordField() {
        DispatchQueue.main.async {
            unlockPasswordFieldFocused = true
        }
    }

    private func stopSession() {
        rendererVM.stopReceiving()
        rendererVM.onNeedsKeyframe = nil
        statsVM.stop()
        audioRenderer.stop()
        coordinator.onAudioFrame = nil
        clipboardSync.deactivate()
        coordinator.onClipboardSync = nil
        terminalSession.deactivate()
        coordinator.onTerminalOutput = nil
        coordinator.onTerminalClose = nil
        isTerminalPresented = false
        fileTransferManager.stopObserving()
        displaySwitchObserverTask?.cancel()
        displaySwitchObserverTask = nil
        reconnectCoordinator.stopObserving()
        reconnectCoordinator.onRebuildSignaling = nil
        reconnectCoordinator.onPerformReconnect = nil
        reconnectCoordinator.onRequestSessionDisconnect = nil
        inputController.teardown()
    }

    /// Preserve everything the reconnect coordinator needs to rebuild the session.
    private func recordReconnectState(sessionID: UUID) {
        reconnectCoordinator.recordSessionState(
            sessionID: sessionID,
            displayID: displayLayoutVM.selectedDisplayID,
            hostName: coordinator.connectedHostName,
            qualityPreset: coordinator.activeQualityPreset,
            sessionTokenHex: coordinator.currentSessionTokenHex
        )
        reconnectCoordinator.recordConnectionEndpoint(
            hostAddress: coordinator.connectedHostAddress,
            signalingPort: coordinator.connectedSignalingPort,
            hostFingerprint: coordinator.connectedHostFingerprint
        )
    }

    private func refreshMapping() {
        // An app-streamed session shows one window, but the host still publishes
        // its full display layout — mapping pointer input against that would
        // scale every click by the window-to-display ratio and land it in the
        // wrong place. Map against the streamed window instead, as iOS does.
        if let window = appStream.streamedWindow {
            inputController.updateMapping(
                display: Self.descriptor(for: window),
                streamConfiguration: nil
            )
            return
        }
        inputController.updateMapping(
            display: displayLayoutVM.selectedDisplay ?? displayLayoutVM.primaryDisplay,
            streamConfiguration: displayLayoutVM.selectedStreamConfiguration
        )
    }

    /// The streamed window presented as a display, so the shared coordinate
    /// mapper can treat an app window exactly like a screen.
    private static func descriptor(
        for window: AppStreamViewModel.StreamedWindow
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            id: window.windowID,
            name: "window",
            frame: DesktopRect(
                origin: DesktopPoint(x: 0, y: 0),
                size: DesktopSize(width: window.pointWidth, height: window.pointHeight)
            ),
            pixelSize: DesktopSize(
                width: window.pointWidth * window.scale,
                height: window.pointHeight * window.scale
            ),
            scaleFactor: window.scale,
            isPrimary: true,
            isActive: true
        )
    }

    private func browseApps() {
        if appStream.streamedWindow == nil && !showsAppBrowser {
            desktopDisplays = displayLayoutVM.displays
        }
        browsingApps = true
        appStream.start()
        appStream.backToApps()
    }

    private func requestDesktop(to displayID: String) {
        guard !isAppStreamingOnlyHost, let sessionID = coordinator.activeSessionID,
              coordinator.phase == .receiving || coordinator.phase == .waitingForMedia else { return }
        guard coordinator.negotiatedCapabilities?.supportsAppStreaming == true else {
            requestDisplaySwitch(to: displayID)
            return
        }
        pendingDesktopID = displayID
        displayLayoutVM.beginDisplaySwitch(to: displayID)
        do {
            let request = StreamTargetSwitchRequestMessage(sessionID: sessionID,
                target: .display(displayID), launchIfNeeded: false,
                senderDeviceID: environment.clientIdentity.id)
            try environment.webRTCSessionManager.sendDataMessage(try DataChannelEnvelope.streamTargetSwitch(request))
        } catch {
            pendingDesktopID = nil
            displayLayoutVM.failDisplaySwitch(reason: "Could not return to the desktop.", fallbackID: displayLayoutVM.hostSelectedDisplayID)
        }
    }

    // MARK: - Display switching

    private func requestDisplaySwitch(to displayID: String) {
        guard let sessionID = coordinator.activeSessionID else { return }
        guard coordinator.phase == .receiving || coordinator.phase == .waitingForMedia else { return }
        displayLayoutVM.beginDisplaySwitch(to: displayID)
        let message = DisplaySwitchRequestMessage(
            sessionID: sessionID,
            targetDisplayID: displayID,
            senderDeviceID: environment.clientIdentity.id
        )
        do {
            try environment.webRTCSessionManager.sendDataMessage(try DataChannelEnvelope.displaySwitch(message))
        } catch {
            displayLayoutVM.failDisplaySwitch(
                reason: "Could not request the display change.",
                fallbackID: displayLayoutVM.hostSelectedDisplayID
            )
        }
    }

    private func handleDisplaySwitchResult(_ result: DisplaySwitchResultMessage) {
        switch result.status {
        case .accepted:
            break
        case .completed:
            if pendingDesktopID == result.selectedDisplayID {
                appStream.stop()
                browsingApps = false
                pendingDesktopID = nil
            }
            displayLayoutVM.completeDisplaySwitch(selectedID: result.selectedDisplayID)
            refreshMapping()
        case .rejected, .failed:
            pendingDesktopID = nil
            displayLayoutVM.failDisplaySwitch(
                reason: result.reason ?? "The host could not switch displays.",
                fallbackID: displayLayoutVM.hostSelectedDisplayID
            )
        }
    }

    // MARK: - Screenshot

    /// GPU-backed context shared across captures for converting frames to images.
    private static let screenshotContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Capture the current remote frame as a PNG and let the user choose where to
    /// save it. A no-op until at least one frame has been decoded.
    private func captureScreenshot() {
        guard let pixelBuffer = rendererVM.latestPixelBuffer else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = Self.screenshotContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: cgImage.width, height: cgImage.height)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = screenshotFileName()
        panel.title = "Save Screenshot"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try pngData.write(to: url, options: .atomic)
                showSessionToast("Screenshot saved", isError: false)
            } catch {
                showSessionToast("Couldn't save screenshot", isError: true)
            }
        }
    }

    private func screenshotFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        let host = coordinator.connectedHostName.map { " — \($0)" } ?? ""
        return "Vamp Control Screenshot\(host) \(stamp).png"
    }

    // MARK: - Session toast

    private func showSessionToast(_ message: String, isError: Bool) {
        withAnimation(.easeOut(duration: 0.18)) {
            sessionToast = message
            sessionToastIsError = isError
        }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if sessionToast == message {
                withAnimation(.easeOut(duration: 0.25)) { sessionToast = nil }
            }
        }
    }

    private func sessionToastView(_ message: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(isError ? Color.orange : Color.green)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .macGlassSurface(in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    // MARK: - File transfer

    private func presentSendFilePicker() {
        guard inputReadiness.canSendInput, let targetSession = coordinator.activeSessionID else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Send File to Host"
        panel.prompt = "Send"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard inputReadiness.canSendInput, coordinator.activeSessionID == targetSession else { return }
            fileTransferManager.sendFile(url: url)
        }
    }

    private func presentReceivedFileSave() {
        guard let pending = fileTransferManager.pendingReceivedFile else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = pending.fileName
        panel.canCreateDirectories = true
        panel.title = "Save Received File"
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                fileTransferManager.handleReceivedFileSaveResult(.failure(URLError(.cancelled)))
                return
            }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.copyItem(at: pending.url, to: url)
                fileTransferManager.handleReceivedFileSaveResult(.success(url))
            } catch {
                fileTransferManager.handleReceivedFileSaveResult(.failure(error))
            }
        }
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func fileTransferPanel(_ transfer: ClientFileTransferManager.TransferState) -> some View {
        let isActive = fileTransferIsActive(transfer.status)
        return HStack(spacing: 12) {
            Image(systemName: transfer.direction == .toMac ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.fileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                if isActive {
                    ProgressView(value: transfer.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                }
                Text(fileTransferStatusText(transfer))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if isActive {
                Button("Cancel") { fileTransferManager.cancelActiveTransfer() }
                    .controlSize(.small)
            } else {
                Button("Dismiss") { fileTransferManager.dismissTransfer() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .macGlassSurface(in: Capsule(), isInteractive: true)
        .environment(\.colorScheme, .dark)
    }

    private func fileTransferIsActive(_ status: ClientFileTransferManager.TransferState.Status) -> Bool {
        switch status {
        case .preparing, .waitingForMac, .sending, .receiving: return true
        case .completed, .canceled, .failed: return false
        }
    }

    private func fileTransferStatusText(_ transfer: ClientFileTransferManager.TransferState) -> String {
        switch transfer.status {
        case .preparing: return "Preparing…"
        case .waitingForMac: return "Waiting for host…"
        case .sending: return "Sending — \(Int(transfer.progress * 100))%"
        case .receiving: return "Receiving — \(Int(transfer.progress * 100))%"
        case .completed(let message): return message
        case .canceled: return "Canceled"
        case .failed(let message): return message
        }
    }
}

// MARK: - Session toolbar chrome

struct SessionToolbarStatusPill: View {
    let hostName: String
    let qualityColor: Color
    let qualityLabel: String
    let differentiateWithoutColor: Bool

    /// Every other control in the window desaturates when the window loses key;
    /// a fully saturated status dot in an inactive window reads as the only live
    /// thing on screen.
    @Environment(\.controlActiveState) private var controlActiveState

    private var isWindowActive: Bool { controlActiveState != .inactive }

    private var dotColor: Color {
        isWindowActive ? qualityColor : Color.secondary
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(dotColor).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(hostName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 4)
        .frame(height: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status")
        .accessibilityValue("\(hostName), \(qualityLabel)")
        .help("\(hostName) · \(qualityLabel) — Connection details")
    }
}

struct SessionToolbarLiveStats: View {
    let framesPerSecond: Double?
    let latencyMs: Double?
    let bitrateKbps: Double?

    var body: some View {
        HStack(spacing: 12) {
            SessionToolbarMetric(
                label: "FPS",
                value: framesPerSecond?.formatted(.number.precision(.fractionLength(0))) ?? "—"
            )
            SessionToolbarMetric(
                label: "Latency",
                value: latencyMs.map {
                    "\($0.formatted(.number.precision(.fractionLength(0)))) ms"
                } ?? "—"
            )
            SessionToolbarMetric(
                label: "Bitrate",
                value: bitrateKbps.map {
                    "\(($0 / 1_000).formatted(.number.precision(.fractionLength(1)))) Mbps"
                } ?? "—"
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .sessionToolbarClusterChrome()
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection statistics")
    }
}

struct SessionToolbarMetric: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SessionToolbarIconLabel: View {
    let systemImage: String
    var isActive: Bool = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isActive ? Color.accentColor : Color.primary.opacity(0.85))
            .frame(width: 28, height: 28)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SessionToolbarToggleLabel: View {
    /// Nil renders icon-only. State toggles carry their meaning in the symbol
    /// and tint; spelling every one out blew the toolbar past the window width,
    /// which pushed items into AppKit's overflow menu where these custom views
    /// render poorly. Mode indicators (display sizing) keep their title.
    let title: String?
    let systemImage: String
    var isActive: Bool = false

    init(title: String? = nil, systemImage: String, isActive: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.isActive = isActive
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, title == nil ? 7 : 9)
        .frame(minHeight: 28)
        .contentShape(Capsule())
    }
}

struct SessionToolbarDisconnectButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "power")
                Text("Disconnect")
            }
                .font(.system(size: 12))
                .padding(.horizontal, 4)
                .frame(height: 26)
        }
        .buttonStyle(.plain)
        .help("Disconnect from host")
        .accessibilityLabel("Disconnect from host")
        .accessibilityHint("Ends the remote session")
    }
}

struct SessionToolbarIconButtonStyle: ButtonStyle {
    var active: Bool = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundFill(pressed: configuration.isPressed))
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }

    private func backgroundFill(pressed: Bool) -> Color {
        if active { return Color.accentColor.opacity(0.18) }
        if pressed { return Color.primary.opacity(0.12) }
        if hovering { return Color.primary.opacity(0.08) }
        return .clear
    }
}

struct SessionToolbarToggleButtonStyle: ButtonStyle {
    var active: Bool = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.82))
            .background {
                Capsule(style: .continuous)
                    .fill(backgroundFill(pressed: configuration.isPressed))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        active ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06),
                        lineWidth: 0.5
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: active)
            .onHover { hovering = $0 }
    }

    private func backgroundFill(pressed: Bool) -> Color {
        if active { return Color.accentColor.opacity(0.16) }
        if pressed { return Color.primary.opacity(0.1) }
        if hovering { return Color.primary.opacity(0.06) }
        return Color.primary.opacity(0.03)
    }
}

extension View {
    func sessionToolbarClusterChrome() -> some View {
        self
            .background {
                Capsule(style: .continuous)
                    .fill(.quaternary.opacity(0.55))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}
