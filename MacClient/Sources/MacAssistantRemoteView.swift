import AppKit
import Combine
import CoreImage
import SwiftUI
import SharedModels
import SharedUtilities
import UniformTypeIdentifiers

/// Vamp Assistant uses its private HTTP transport behind the same window chrome and
/// AppKit event surface as a normal Vamp Control session. Transport differences must
/// never create a second, reduced remote-control interface.
struct MacAssistantRemoteView: View {
    @ObservedObject var model: MacAssistantSession
    @StateObject private var renderer = BeetCodeVideoRendererViewModel()
    @StateObject private var input: MacAssistantInputController
    @State private var isRefreshing = false
    @State private var refreshError: String?
    @State private var selectedDisplayID: UInt32?
    @State private var fullControl = true
    @State private var keyboardFocused = false
    @State private var isCompactToolbar = true
    @State private var showsConnectionDetails = false
    @State private var showsKeyboardHelp = false
    @State private var showsStats = true
    @State private var sessionToast: String?
    @State private var sessionToastIsError = false
    @State private var unlockPassword = ""
    @State private var isUnlockSubmitting = false
    @State private var unlockError: String?
    @FocusState private var unlockPasswordFieldFocused: Bool
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var preferences = MacConnectionPreferences()
    @State private var loadedPreferenceKey: String?

    init(model: MacAssistantSession) {
        self.model = model
        _input = StateObject(
            wrappedValue: MacAssistantInputController(client: model.connected?.client)
        )
    }

    /// Vamp Assistant streams at whatever resolution the client asks for. The
    /// renderer's shared default is 1080p, which was sized for a phone and left
    /// every Retina Mac looking soft; Vamp Stream already moved this path to
    /// native. A Mac decodes native comfortably, so ask for it here too.
    private static let streamResolution = "native"

    private var displayMode: DisplayMappingEngine.DisplayMode {
        DisplayMappingEngine.DisplayMode(rawValue: preferences.displayModeRaw) ?? .fitDisplay
    }

    private var preferenceKey: String? { model.connected.map { MacConnectionPreferenceStore.assistantKey(address: $0.address) } }

    private func loadPreferences() {
        guard let key = preferenceKey, key != loadedPreferenceKey else { return }
        preferences = MacConnectionPreferenceStore().load(for: key)
        loadedPreferenceKey = key
    }

    private var inputReadiness: MacInputReadiness {
        .resolve(connected: model.connected != nil && renderer.lastError == nil,
                 locked: model.connected?.status.ready != true,
                 choosingApp: false, receivingVideo: renderer.isReceiving,
                 viewOnly: !fullControl)
    }

    var body: some View {
        Group {
            if let session = model.connected {
                if session.status.ready {
                    stream(session)
                } else if session.status.shouldOfferRemoteUnlock {
                    remoteUnlockState(session)
                } else {
                    permissionState(session)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .onDisappear {
            renderer.stop()
            input.stop()
        }
    }

    private func stream(_ session: MacAssistantSession.ConnectedSession) -> some View {
        ZStack {
            MacAssistantVideoStreamView(
                renderer: renderer,
                input: input,
                isInputEnabled: inputReadiness.canSendInput,
                usesLocalCursor: session.status.supportsCursorlessCapture == true,
                displayMode: displayMode,
                onKeyboardFocusChange: { keyboardFocused = $0 },
                keepsDisplayShortcutsLocal: preferences.keepsDisplayShortcutsLocal)
                .ignoresSafeArea()
                .accessibilityLabel("Remote control surface for \(session.displayName)")

            VStack {
                MacKeyboardFocusHint(readiness: inputReadiness, keyboardFocused: keyboardFocused)
                Spacer()
            }.padding(.top, 10)

            if !renderer.isReceiving {
                streamStatus(session)
            }

            if let error = input.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.red.opacity(0.84), in: Capsule())
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .background(Color.black)
        .modifier(MacSessionWidthReader(isCompact: $isCompactToolbar))
        .toolbar { assistantWindowToolbar(session).compactSessionChrome() }
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
        .sheet(isPresented: $showsKeyboardHelp) { MacKeyboardHelp(keepsDisplayShortcutsLocal: $preferences.keepsDisplayShortcutsLocal) }
        .overlay(alignment: .bottomLeading) {
            if showsStats { assistantLiveStats.padding(12).allowsHitTesting(false) }
        }
        .overlay(alignment: .bottom) {
            if let sessionToast {
                Label(
                    sessionToast,
                    systemImage: sessionToastIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(sessionToastIsError ? Color.red.opacity(0.86) : Color.black.opacity(0.72), in: Capsule())
                    .padding(.bottom, 28)
            }
        }
        .task(id: "\(session.id)-\(selectedDisplayID ?? 0)") {
            input.updateClient(session.client)
            renderer.start(
                client: session.client,
                resolution: Self.streamResolution,
                displayID: selectedDisplayID,
                showsCursor: session.status.supportsCursorlessCapture != true)
        }
    }

    @ToolbarContentBuilder
    private func assistantWindowToolbar(_ session: MacAssistantSession.ConnectedSession) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { showsConnectionDetails.toggle() } label: {
                SessionToolbarStatusPill(hostName: session.displayName,
                    qualityColor: renderer.isReceiving ? .green : .orange,
                    qualityLabel: renderer.isReceiving ? "Assistant" : "Waiting for video",
                    differentiateWithoutColor: differentiateWithoutColor)
                    .frame(maxWidth: isCompactToolbar ? 170 : 220)
            }
            .buttonStyle(.plain)
            .help("Connection details")
            .popover(isPresented: $showsConnectionDetails) {
                MacConnectionDetails(hostName: session.displayName,
                    transportConnected: renderer.lastError == nil,
                    receivingVideo: renderer.isReceiving, readiness: inputReadiness,
                    keyboardFocused: keyboardFocused,
                    unavailable: ["Clipboard", "File transfer", "Terminal", "Screen AI", "Remote audio"])
            }
        }
        if let displays = session.status.displays, displays.count > 1 {
            ToolbarItem(placement: .primaryAction) {
                Menu("Display") {
                    ForEach(displays) { display in
                        Button(display.name) {
                            guard selectedDisplayID != display.id else { return }
                            input.isEnabled = false
                            renderer.stop()
                            selectedDisplayID = display.id
                        }
                    }
                }
            }
        }
        ToolbarItem(placement: .primaryAction) { displaySizingMenu }
        ToolbarItem(placement: .primaryAction) {
            MacSessionAccessButton(viewOnly: Binding(get: { !fullControl }, set: { fullControl = !$0 }),
                readiness: inputReadiness, keyboardFocused: keyboardFocused)
        }
        ToolbarItem(placement: .primaryAction) {
            MacSessionToolsMenu(actions: sessionActions, canSendInput: inputReadiness.canSendInput,
                sendKey: { key in
                    guard inputReadiness.canSendInput else { return }
                    input.keyPress(key.assistantKey, modifiers: key.assistantModifiers)
                }, showKeyboardHelp: { showsKeyboardHelp = true }, showsStats: $showsStats, quickActionID: $preferences.quickActionID)
        }
        if !isCompactToolbar, let quick = sessionActions.first(where: { $0.id == preferences.quickActionID }) {
            ToolbarItem(placement: .primaryAction) { MacSessionQuickAction(action: quick) }
        }
        ToolbarItem(placement: .primaryAction) {
            SessionToolbarDisconnectButton { model.disconnect() }
        }
    }

    private var sessionActions: [MacSessionAction] {
        [.init(id: "screenshot", title: "Save Screenshot…", symbol: "camera",
               enabled: renderer.isReceiving, shortcut: "s", perform: captureScreenshot)]
    }

    private var displaySizingMenu: some View {
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
                displayMode == .actualSize ? resizeWindowToActualSize() : matchWindowToDisplay()
            } label: {
                Label("Match Window to Display", systemImage: "aspectratio")
            }
            .disabled(renderer.geometry == nil)
        } label: {
            SessionToolbarToggleLabel(
                title: isCompactToolbar ? compactDisplaySizingTitle : displaySizingTitle,
                systemImage: displaySizingSymbol,
                isActive: displayMode != .fitDisplay)
        }
        .menuStyle(.borderlessButton)
        .help(displaySizingHelp)
        .accessibilityLabel("Remote display sizing")
        .accessibilityValue(displaySizingTitle)
    }

    /// The Assistant transport reports neither latency nor bitrate, so this
    /// shows only what is actually measured. It previously reused the WebRTC
    /// three-metric cluster with all three values hardcoded to nil, which
    /// rendered a permanent "— — —" beside a Stats toggle that changed nothing.
    private var assistantLiveStats: some View {
        HStack(spacing: 12) {
            SessionToolbarMetric(
                label: "FPS",
                value: renderer.framesPerSecond
                    .map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—"
            )
            SessionToolbarMetric(
                label: "Stream",
                value: renderer.geometry
                    .map { "\($0.imageWidth)×\($0.imageHeight)" } ?? "—"
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .sessionToolbarClusterChrome()
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stream statistics")
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
        case .fitDisplay: "Fit Display"
        case .fillScreen: "Fill Window"
        case .actualSize: "Actual Size"
        }
    }

    private var displaySizingSymbol: String {
        switch displayMode {
        case .fitDisplay: "rectangle.inset.filled"
        case .fillScreen: "arrow.up.left.and.arrow.down.right"
        case .actualSize: "1.magnifyingglass"
        }
    }

    private var displaySizingHelp: String {
        switch displayMode {
        case .fitDisplay: "Fit Display — show the whole remote screen"
        case .fillScreen: "Fill Window — edges may be cropped"
        case .actualSize: "Actual Size — 1:1 remote pixels"
        }
    }

    private func matchWindowToDisplay() {
        guard let geometry = renderer.geometry else { return }
        resizeLocalWindow(
            to: CGSize(width: CGFloat(geometry.imageWidth), height: CGFloat(geometry.imageHeight)),
            actualPixels: false)
    }

    private func resizeWindowToActualSize() {
        guard let geometry = renderer.geometry else { return }
        resizeLocalWindow(
            to: CGSize(width: CGFloat(geometry.imageWidth), height: CGFloat(geometry.imageHeight)),
            actualPixels: true)
    }

    private func resizeLocalWindow(to streamSize: CGSize, actualPixels: Bool) {
        guard streamSize.width > 0, streamSize.height > 0,
              let window = NSApp.keyWindow,
              let screen = window.screen ?? NSScreen.main else { return }
        let currentContent = window.contentRect(forFrameRect: window.frame)
        let chromeHeight = window.frame.height - currentContent.height
        let maximum = CGSize(width: screen.visibleFrame.width, height: max(320, screen.visibleFrame.height - chromeHeight))
        let scale = actualPixels ? screen.backingScaleFactor : 1
        var target = CGSize(width: streamSize.width / scale, height: streamSize.height / scale)
        if !actualPixels {
            target.width = currentContent.width
            target.height = target.width * streamSize.height / streamSize.width
        }
        let downscale = min(1, min(maximum.width / target.width, maximum.height / target.height))
        target.width *= downscale
        target.height *= downscale
        var content = currentContent
        content.size = target
        var frame = window.frameRect(forContentRect: content)
        frame.origin.x = min(max(window.frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(window.frame.maxY - frame.height, screen.visibleFrame.minY), screen.visibleFrame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }

    private func captureScreenshot() {
        guard let pixelBuffer = renderer.latestPixelBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            showToast("Couldn't save screenshot", isError: true)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Vamp Assistant Screenshot.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return }
            do {
                try data.write(to: url, options: .atomic)
                showToast("Screenshot saved")
            } catch {
                showToast("Couldn't save screenshot", isError: true)
            }
        }
    }

    private func showToast(_ message: String, isError: Bool = false) {
        sessionToast = message
        sessionToastIsError = isError
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard sessionToast == message else { return }
            sessionToast = nil
        }
    }

    private func streamStatus(_ session: MacAssistantSession.ConnectedSession) -> some View {
        VStack(spacing: 12) {
            if let error = renderer.lastError {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 36, weight: .light))
                Text("Vamp Assistant stream stopped").font(.headline)
                Text(error).font(.callout).foregroundStyle(.white.opacity(0.74)).multilineTextAlignment(.center).frame(maxWidth: 460)
                Button("Reconnect") {
                    renderer.start(
                        client: session.client,
                        resolution: Self.streamResolution,
                        displayID: selectedDisplayID)
                }
                    .buttonStyle(.bordered)
            } else {
                ProgressView()
                Text("Opening \(session.displayName)…").font(.callout).foregroundStyle(.white.opacity(0.78))
            }
        }
        .foregroundStyle(.white)
        .padding(28)
        .macGlassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func permissionState(_ session: MacAssistantSession.ConnectedSession) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield").font(.system(size: 44, weight: .light))
            Text("Mac Control is not ready").font(.title2.weight(.semibold))
            Text(permissionMessage(session.status)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            Text("Open Vamp Assistant → Settings → Permissions on the remote Mac, grant only the requested permission, then check again.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 500)
            if let refreshError { Text(refreshError).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center) }
            HStack {
                Button("Back to Macs") { model.disconnect() }.keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        isRefreshing = true
                        refreshError = await model.refreshStatus()
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing { ProgressView().controlSize(.small) } else { Text("Check Again") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRefreshing)
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacBrand.pageBackdrop)
    }

    private func permissionMessage(_ status: BeetCodeControlStatus) -> String {
        if !status.enabled { return "Mac Control is turned off in Vamp Assistant." }
        if !status.screenRecording { return "Screen Recording permission is required to receive the remote display." }
        if !status.accessibility { return "Accessibility permission is required to send pointer and keyboard input." }
        if status.locked == true, let message = status.remoteUnlockMessage { return message }
        return status.message ?? "Vamp Assistant is still preparing Mac Control."
    }

    private func remoteUnlockState(_ session: MacAssistantSession.ConnectedSession) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 44, weight: .light))
            Text("Mac is locked")
                .font(.title2.weight(.semibold))
            Text(session.status.remoteUnlockMessage ?? "Enter the Mac login password to resume Vamp Control.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            SecureField("Mac login password", text: $unlockPassword)
                .focused($unlockPasswordFieldFocused)
                .textFieldStyle(.roundedBorder)
                .privacySensitive()
                .frame(maxWidth: 340)
                .onSubmit { submitRemoteUnlock(session) }

            Button {
                submitRemoteUnlock(session)
            } label: {
                if isUnlockSubmitting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Unlock Mac")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(unlockPassword.isEmpty || isUnlockSubmitting)

            Text("Remote Unlock is enabled. The password is sent once through the authenticated private connection, then cleared from this field.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if let unlockError {
                Text(unlockError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            Button("Back to Macs") { model.disconnect() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacBrand.pageBackdrop)
        .onAppear { focusRemoteUnlockField() }
        .onChange(of: model.connected?.status) { status in
            if status?.locked != true {
                unlockPassword = ""
                unlockError = nil
                isUnlockSubmitting = false
                unlockPasswordFieldFocused = false
            }
        }
    }

    private func submitRemoteUnlock(_ session: MacAssistantSession.ConnectedSession) {
        guard !unlockPassword.isEmpty, !isUnlockSubmitting else { return }
        let submittedPassword = unlockPassword
        unlockPassword = ""
        unlockError = nil
        isUnlockSubmitting = true

        Task {
            do {
                _ = try await session.client.unlockMac(password: submittedPassword)
                try? await Task.sleep(for: .milliseconds(700))
                unlockError = await model.refreshStatus()
            } catch {
                unlockError = error.localizedDescription
            }
            isUnlockSubmitting = false
            if model.connected?.status.locked == true {
                focusRemoteUnlockField()
            }
        }
    }

    private func focusRemoteUnlockField() {
        DispatchQueue.main.async {
            unlockPasswordFieldFocused = true
        }
    }
}

private struct MacAssistantVideoStreamView: NSViewRepresentable {
    @ObservedObject var renderer: BeetCodeVideoRendererViewModel
    let input: MacAssistantInputController
    let isInputEnabled: Bool
    let usesLocalCursor: Bool
    let displayMode: DisplayMappingEngine.DisplayMode
    let onKeyboardFocusChange: (Bool) -> Void
    let keepsDisplayShortcutsLocal: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RemoteStreamNSView {
        let view = RemoteStreamNSView()
        view.keepsDisplayShortcutsLocal = keepsDisplayShortcutsLocal
        view.onKeyboardFocusChange = onKeyboardFocusChange
        view.input = input
        view.isInputEnabled = isInputEnabled
        view.displayMode = displayMode
        view.usesLocalCursor = usesLocalCursor
        input.isEnabled = isInputEnabled
        input.updateDisplayMode(displayMode)
        input.setGeometry(renderer.geometry)
        context.coordinator.cancellable = renderer.$latestPixelBuffer.sink { [weak view] in
            view?.display(pixelBuffer: $0)
        }
        return view
    }

    func updateNSView(_ view: RemoteStreamNSView, context: Context) {
        view.keepsDisplayShortcutsLocal = keepsDisplayShortcutsLocal
        view.onKeyboardFocusChange = onKeyboardFocusChange
        view.input = input
        view.isInputEnabled = isInputEnabled
        view.displayMode = displayMode
        view.usesLocalCursor = usesLocalCursor
        input.isEnabled = isInputEnabled
        input.updateDisplayMode(displayMode)
        input.setGeometry(renderer.geometry)
    }

    static func dismantleNSView(_ view: RemoteStreamNSView, coordinator: Coordinator) {
        coordinator.cancellable?.cancel()
        view.stopInputCapture()
        view.isInputEnabled = false
        view.input?.isEnabled = false
        view.setLocalCursorHidden(false)
        view.display(pixelBuffer: nil)
    }

    final class Coordinator { var cancellable: AnyCancellable? }
}

/// Assistant HTTP input adapter for Vamp Control's mature AppKit event surface.
@MainActor
final class MacAssistantInputController: ObservableObject, MacRemoteInputHandling {
    @Published private(set) var lastError: String?
    var isEnabled = false {
        didSet {
            guard !isEnabled else { return }
            pendingMove = nil
            moveFlushTask?.cancel()
            moveFlushTask = nil
            sendQueue.discardPendingInteractions()
        }
    }

    /// Follows the live session. A `@StateObject` is built once, so capturing
    /// the client at init would keep routing input to the previously paired Mac
    /// after a re-pair.
    private var client: BeetCodeRemoteClient?
    private var viewSize: CGSize = .zero
    private var viewPixelScale: Double = 1
    private var geometry: BeetCodeDisplayGeometry?
    private var displayMode: DisplayMappingEngine.DisplayMode = .fitDisplay
    private var pendingMove: BeetCodeInputCommand?
    private var moveFlushTask: Task<Void, Never>?
    private var sendQueue = MacAssistantInputSendQueue()
    private var sendTask: Task<Void, Never>?

    init(client: BeetCodeRemoteClient?) {
        self.client = client
    }

    func updateClient(_ client: BeetCodeRemoteClient) {
        stop()
        self.client = client
    }

    func setGeometry(_ geometry: BeetCodeDisplayGeometry?) { self.geometry = geometry }
    func updateViewGeometry(size: CGSize, pixelScale: Double) {
        viewSize = size
        viewPixelScale = max(1, pixelScale)
    }
    func updateDisplayMode(_ displayMode: DisplayMappingEngine.DisplayMode) { self.displayMode = displayMode }
    func containsRemoteContent(_ point: CGPoint) -> Bool { contentRect(geometry)?.contains(point) == true }
    func remoteContentRect(in viewSize: CGSize) -> CGRect? { contentRect(geometry) }

    func pointerMoved(to point: CGPoint) {
        guard isEnabled, let mapped = map(point, clamp: true) else { return }
        pendingMove = .move(x: mapped.x, y: mapped.y)
        guard moveFlushTask == nil else { return }
        moveFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            self?.flushMove()
        }
    }

    func pointerButton(_ button: MouseButton, action: ButtonAction, at point: CGPoint) {
        guard isEnabled, let mapped = map(point, clamp: false) else { return }
        flushMove()
        enqueue(.move(x: mapped.x, y: mapped.y))
        switch action {
        case .down: enqueue(.down(button: button.rawValue))
        case .up: enqueue(.up(button: button.rawValue))
        case .click: enqueue(.click(x: mapped.x, y: mapped.y, button: button.rawValue, count: 1))
        case .doubleClick: enqueue(.click(x: mapped.x, y: mapped.y, button: button.rawValue, count: 2))
        }
    }

    func scrolled(deltaX: Double, deltaY: Double, isPrecise: Bool) {
        guard isEnabled else { return }
        enqueue(.scroll(x: nil, y: nil, dx: deltaX, dy: deltaY))
    }

    func keyEvent(_ event: NSEvent, action: KeyAction) {
        guard isEnabled, action == .down else { return }
        // Modifiers travel with the following key. Control-click is translated by
        // RemoteStreamNSView without leaking a separate Control press remotely.
        guard !Self.modifierKeyCodes.contains(event.keyCode) else { return }
        let modifiers = Self.modifierNames(event.modifierFlags)
        if let special = MacAssistantKeyMapping.name(for: event.keyCode) {
            enqueue(.key(special, modifiers: modifiers))
            return
        }
        let shortcutModifiers = event.modifierFlags.intersection([.command, .control, .option])
        if shortcutModifiers.isEmpty, let characters = event.characters, !characters.isEmpty {
            enqueue(.type(characters))
        } else if let raw = event.charactersIgnoringModifiers, !raw.isEmpty {
            enqueue(.key(raw.lowercased(), modifiers: modifiers))
        }
    }

    func keyPress(_ key: String, modifiers: [String]) { enqueue(.key(key, modifiers: modifiers)) }

    func stop() {
        moveFlushTask?.cancel()
        moveFlushTask = nil
        sendQueue.removeAll()
        sendTask?.cancel()
        sendTask = nil
        pendingMove = nil
        lastError = nil
        client = nil
    }

    private func flushMove() {
        moveFlushTask?.cancel()
        moveFlushTask = nil
        guard let pendingMove else { return }
        self.pendingMove = nil
        enqueue(pendingMove)
    }

    private func enqueue(_ command: BeetCodeInputCommand) {
        guard isEnabled, client != nil else { return }
        sendQueue.enqueue(command)
        startSenderIfNeeded()
    }

    private func startSenderIfNeeded() {
        guard sendTask == nil else { return }
        sendTask = Task { [weak self] in
            await self?.drainSendQueue()
        }
    }

    private func drainSendQueue() async {
        while !Task.isCancelled,
              let command = sendQueue.popFirst(),
              let client {
            do {
                _ = try await client.sendControlBatch([command])
                lastError = nil
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
            }
        }
        sendTask = nil
        if !sendQueue.isEmpty { startSenderIfNeeded() }
    }

    private func map(_ point: CGPoint, clamp: Bool) -> CGPoint? {
        guard let geometry, let rect = contentRect(geometry), rect.width > 0, rect.height > 0 else { return nil }
        guard clamp || rect.contains(point) else { return nil }
        let point = CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
        return CGPoint(
            x: geometry.displayX + ((point.x - rect.minX) / rect.width) * geometry.displayWidth,
            y: geometry.displayY + ((point.y - rect.minY) / rect.height) * geometry.displayHeight)
    }

    private func contentRect(_ geometry: BeetCodeDisplayGeometry?) -> CGRect? {
        guard let geometry else { return nil }
        return MacRemoteContentLayout.rect(
            imageSize: CGSize(width: geometry.imageWidth, height: geometry.imageHeight),
            viewSize: viewSize, pixelScale: viewPixelScale, mode: displayMode)
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 60, 58, 61, 59, 62, 63]

    private static func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.function) { names.append("function") }
        return names
    }
}
