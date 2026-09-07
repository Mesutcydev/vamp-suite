import Foundation
import SharedModels
import SharedProtocol
import SharedUtilities
import TransportWebRTC
import os
#if canImport(UIKit)
import UIKit
import QuartzCore
#endif

/// Retains the CADisplayLink target without creating a retain cycle back to the
/// view model (CADisplayLink retains its target).
private final class DisplayLinkProxy {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func tick() { handler() }
}

/// Converts touch gestures into input commands and sends them over the data channel.
/// Owns the `GestureInterpreter` and `ViewportCoordinateMapper`, feeding from the
/// display layout and current view geometry.
@MainActor
final class RemoteInteractionViewModel: ObservableObject {

    enum InteractionState: Equatable {
        case disabled
        case ready
        case dragging
        case dragLocked
    }

    @Published private(set) var interactionState: InteractionState = .disabled
    @Published var interactionMode: ViewportCoordinateMapper.InteractionMode = .absolute {
        didSet { rebuildMapper() }
    }
    @Published var displayMode: DisplayMappingEngine.DisplayMode = RemoteInteractionViewModel.loadPersistedDisplayMode() {
        didSet {
            RemoteInteractionViewModel.persistDisplayMode(displayMode)
            rebuildMapper()
        }
    }

    private static let displayModeDefaultsKey = "client.remote.displayMode"

    private static func loadPersistedDisplayMode() -> DisplayMappingEngine.DisplayMode {
        guard let raw = UserDefaults.standard.string(forKey: displayModeDefaultsKey),
              let mode = DisplayMappingEngine.DisplayMode(rawValue: raw) else {
            return .fitDisplay
        }
        return mode
    }

    private static func persistDisplayMode(_ mode: DisplayMappingEngine.DisplayMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: displayModeDefaultsKey)
    }
    private(set) var commandsSent: UInt64 = 0
    @Published private(set) var lastError: String?
    @Published private(set) var isDragLocked: Bool = false
    @Published var sessionMode: SessionControlMode = .fullControl {
        didSet {
            if sessionMode.blocksRemoteInput {
                interactionState = .disabled
            } else {
                updateForConnectionState(webRTCSessionManager.connectionState)
            }
        }
    }

    private let webRTCSessionManager: any WebRTCSessionManaging
    private let displayLayoutViewModel: DisplayLayoutViewModel

    private(set) var mapper: ViewportCoordinateMapper?
    private(set) var interpreter: GestureInterpreter?

    /// Current session ID used for InputCommandMessage envelope.
    var sessionID: UUID?

    /// Cached view size — updated by the SwiftUI view via `updateViewSize`.
    private var viewSize: DesktopSize = .zero
    private var viewInsets: DesktopEdgeInsets = .zero
    private var viewPixelScale: Double = 1
    private let logger = Logger(subsystem: "com.mesutcy.remotedesktop.ios", category: "DisplayMapping")

    // MARK: - Pointer feel (relative / trackpad mode)
    /// Multiplier applied to relative cursor movement (set from the sensitivity slider).
    var pointerSensitivity: Double = 1.0
    /// Velocity-based acceleration: slow = precise, fast = covers more distance.
    var pointerAccelerationEnabled: Bool = true

    // MARK: - Ordered, coalesced send pipeline
    // All commands go through one serial async consumer so they're delivered in
    // order (a per-call Task could reorder). High-frequency continuous input
    // (pointer moves, scroll) is coalesced and flushed once per display refresh
    // instead of emitting one authenticated envelope per touch sample.
    private var sendContinuation: AsyncStream<InputCommandMessage>.Continuation?
    private var senderTask: Task<Void, Never>?
    private var pendingMove: PointerMoveCommand?
    private var pendingScrollDX: Double = 0
    private var pendingScrollDY: Double = 0
    private var hasPendingScroll = false
    private var flushLink: CADisplayLink?

    init(
        webRTCSessionManager: any WebRTCSessionManaging,
        displayLayoutViewModel: DisplayLayoutViewModel
    ) {
        self.webRTCSessionManager = webRTCSessionManager
        self.displayLayoutViewModel = displayLayoutViewModel
    }

    deinit {
        flushLink?.invalidate()
        sendContinuation?.finish()
        senderTask?.cancel()
    }

    // MARK: - Configuration

    func updateViewSize(_ size: DesktopSize) {
        viewSize = size
        rebuildMapper()
    }

    func updateViewportInsets(_ insets: DesktopEdgeInsets) {
        viewInsets = insets
        rebuildMapper()
    }

    func updateViewPixelScale(_ scale: Double) {
        viewPixelScale = max(scale, 1)
        rebuildMapper()
    }

    func refreshMapping() {
        rebuildMapper()
    }

    var selectedDisplay: DisplayDescriptor? {
        displayLayoutViewModel.selectedDisplay ?? displayLayoutViewModel.primaryDisplay
    }

    var targetDisplayID: String? {
        selectedDisplay?.id
    }

    var usesPreciseDisplayMapping: Bool {
        displayLayoutViewModel.selectedStreamConfiguration != nil
    }

    var currentDisplayLabel: String? {
        guard let display = selectedDisplay else { return nil }
        let pixelSize = displayLayoutViewModel.selectedStreamConfiguration?.sourceDisplayPixelSize ?? display.pixelSize
        return "\(display.name) · \(Int(pixelSize.width))×\(Int(pixelSize.height))"
    }

    var mappingContentRect: DesktopRect? {
        mapper?.fittedContentRect
    }

    var mappingSourceDisplaySizeText: String {
        let size = displayLayoutViewModel.selectedStreamConfiguration?.sourceDisplayPixelSize
            ?? selectedDisplay?.pixelSize
            ?? .zero
        return "\(Int(size.width))×\(Int(size.height))"
    }

    var mappingStreamFrameSizeText: String {
        let size = displayLayoutViewModel.selectedStreamConfiguration?.streamSize
            ?? selectedDisplay?.pixelSize
            ?? .zero
        return "\(Int(size.width))×\(Int(size.height))"
    }

    var mappingViewRenderSizeText: String {
        "\(Int(viewSize.width))×\(Int(viewSize.height))"
    }

    var mappingLetterboxOffsetsText: String {
        guard let rect = mappingContentRect else { return "n/a" }
        return "x:\(Int(rect.origin.x)) y:\(Int(rect.origin.y))"
    }

    var mappingSampleText: String {
        guard let mapper,
              let center = mapper.viewToDisplayLocal(DesktopPoint(x: viewSize.width / 2, y: viewSize.height / 2)) else {
            return "n/a"
        }
        return "\(Int(center.x)),\(Int(center.y))"
    }

    private func rebuildMapper() {
        guard let display = selectedDisplay, viewSize.width > 0, viewSize.height > 0 else {
            mapper = nil
            interpreter = nil
            interactionState = .disabled
            return
        }

        let newMapper = ViewportCoordinateMapper(
            display: display,
            streamConfiguration: displayLayoutViewModel.selectedStreamConfiguration,
            viewSize: viewSize,
            viewInsets: viewInsets,
            viewPixelScale: viewPixelScale,
            displayMode: displayMode,
            interactionMode: interactionMode
        )
        mapper = newMapper
        interpreter = GestureInterpreter(displayID: display.id, mapper: newMapper)

        if webRTCSessionManager.connectionState == .connected && !sessionMode.blocksRemoteInput {
            interactionState = isDragLocked ? .dragLocked : .ready
        }

        let content = newMapper.fittedContentRect
        let source = displayLayoutViewModel.selectedStreamConfiguration?.sourceDisplayPixelSize ?? display.pixelSize
        let stream = displayLayoutViewModel.selectedStreamConfiguration?.streamSize ?? display.pixelSize
        let sample = newMapper.viewToDisplayLocal(DesktopPoint(x: viewSize.width / 2, y: viewSize.height / 2)) ?? .zero
        logger.info(
            "Display mapping updated: display=\(display.id, privacy: .public) source=\(Int(source.width))x\(Int(source.height)) stream=\(Int(stream.width))x\(Int(stream.height)) view=\(Int(self.viewSize.width))x\(Int(self.viewSize.height)) mode=\(self.displayMode.rawValue, privacy: .public) offsets=\(Int(content.origin.x)),\(Int(content.origin.y)) sample=\(Int(sample.x)),\(Int(sample.y)) precise=\(self.usesPreciseDisplayMapping, privacy: .public)"
        )
    }

    func updateForConnectionState(_ state: ConnectionState) {
        if sessionMode.blocksRemoteInput {
            interactionState = .disabled
            return
        }
        if state == .connected {
            if interpreter != nil {
                interactionState = isDragLocked ? .dragLocked : .ready
            }
        } else {
            interactionState = .disabled
            isDragLocked = false
            stopFlushLink()
        }
    }

    // MARK: - Gesture Handling

    func handleTap(at viewPoint: DesktopPoint) {
        guard gestureAllowed(), let command = interpreter?.tap(at: viewPoint) else { return }
        AppHaptics.impact(.light)
        sendDiscrete(command)
    }

    func handleDoubleTap(at viewPoint: DesktopPoint) {
        guard gestureAllowed(), let command = interpreter?.doubleTap(at: viewPoint) else { return }
        AppHaptics.impact(.medium)
        sendDiscrete(command)
    }

    func handleTwoFingerTap(at viewPoint: DesktopPoint) {
        guard gestureAllowed(), let command = interpreter?.twoFingerTap(at: viewPoint) else { return }
        AppHaptics.impact(.light)
        sendDiscrete(command)
    }

    func handleThreeFingerTap(at viewPoint: DesktopPoint) {
        guard gestureAllowed(), let command = interpreter?.threeFingerTap(at: viewPoint) else { return }
        AppHaptics.impact(.light)
        sendDiscrete(command)
    }

    func handleDragChanged(translation: DesktopPoint, currentViewPoint: DesktopPoint) {
        guard gestureAllowed(), let interpreter else { return }
        var command = interpreter.drag(translation: translation, currentViewPoint: currentViewPoint)
        // Apply sensitivity + acceleration to *relative* (trackpad) movement only.
        // Absolute mapping positions the cursor directly, so dynamics don't apply.
        if case .pointerMove(let m) = command, !m.isAbsolute {
            command = .pointerMove(PointerMoveCommand(
                location: dynamics(m.location), displayID: m.displayID, isAbsolute: false))
        }
        let targetState: InteractionState = isDragLocked ? .dragLocked : .dragging
        if interactionState != targetState { interactionState = targetState }
        route(command)
    }

    func handleDragEnded() {
        // Flush the final accumulated sample so the cursor lands precisely.
        flushPending()
        if !isDragLocked {
            interactionState = .ready
        }
    }

    func handleScroll(deltaX: Double, deltaY: Double) {
        guard gestureAllowed(), let interpreter else { return }
        route(interpreter.scroll(deltaX: deltaX, deltaY: deltaY))
    }

    // MARK: - Drag Lock

    func toggleDragLock(at viewPoint: DesktopPoint) {
        guard let interpreter else { return }
        if isDragLocked {
            if let cmd = interpreter.dragLockEnd(at: viewPoint) {
                sendDiscrete(cmd)
            }
            AppHaptics.impact(.soft)
            isDragLocked = false
            interactionState = .ready
        } else {
            if let cmd = interpreter.dragLockBegin(at: viewPoint) {
                sendDiscrete(cmd)
            }
            AppHaptics.impact(.rigid)
            isDragLocked = true
            interactionState = .dragLocked
        }
    }

    // MARK: - Text & Key

    func sendText(_ text: String) {
        guard gestureAllowed(), let interpreter, !text.isEmpty else { return }
        sendDiscrete(interpreter.textInput(text))
    }

    func sendKey(keyCode: UInt16, action: KeyAction, modifiers: KeyboardModifierFlags = []) {
        guard gestureAllowed(), let interpreter else { return }
        sendDiscrete(interpreter.keyPress(keyCode: keyCode, action: action, modifiers: modifiers))
    }

    // MARK: - Bluetooth Mouse / Direct Pointer

    /// Sends a relative pointer delta from a Bluetooth mouse / hover.
    /// Bypasses interactionState — BLE deltas don't use the viewport mapper.
    /// (Sensitivity is already applied upstream; we add acceleration here.)
    func sendRelativePointerMove(deltaX: Double, deltaY: Double) {
        guard rawAllowed(), let displayID = targetDisplayID else { return }
        coalesceMove(PointerMoveCommand(
            location: accelerated(DesktopPoint(x: deltaX, y: deltaY)),
            displayID: displayID,
            isAbsolute: false
        ))
    }

    func sendPointerButton(_ button: MouseButton, action: ButtonAction) {
        guard rawAllowed() else { return }
        sendDiscrete(.pointerButton(PointerButtonCommand(button: button, action: action)))
    }

    func sendScrollInput(deltaX: Double, deltaY: Double) {
        guard rawAllowed() else { return }
        coalesceScroll(dx: deltaX, dy: deltaY)
    }

    // MARK: - Pointer dynamics

    private func accelerated(_ d: DesktopPoint) -> DesktopPoint {
        PointerDynamics.accelerate(d, enabled: pointerAccelerationEnabled)
    }

    private func dynamics(_ d: DesktopPoint) -> DesktopPoint {
        PointerDynamics.apply(
            d,
            sensitivity: pointerSensitivity,
            accelerationEnabled: pointerAccelerationEnabled)
    }

    // MARK: - Guards

    private func gestureAllowed() -> Bool {
        guard interactionState != .disabled else { return false }
        guard !sessionMode.blocksRemoteInput else {
            lastError = "View-only mode is enabled."
            return false
        }
        guard sessionID != nil else { lastError = "No active session"; return false }
        return true
    }

    private func rawAllowed() -> Bool {
        guard !sessionMode.blocksRemoteInput else {
            lastError = "View-only mode is enabled."
            return false
        }
        guard webRTCSessionManager.connectionState == .connected, sessionID != nil else { return false }
        return true
    }

    // MARK: - Ordered, coalesced send pipeline

    private func route(_ command: InputCommand) {
        switch command {
        case .pointerMove(let m): coalesceMove(m)
        case .scroll(let s): coalesceScroll(dx: s.deltaX, dy: s.deltaY)
        default: sendDiscrete(command)
        }
    }

    private func coalesceMove(_ cmd: PointerMoveCommand) {
        if cmd.isAbsolute {
            if pendingMove?.isAbsolute == false { flushPendingMove() }
            pendingMove = cmd                    // latest position wins
        } else if let p = pendingMove, !p.isAbsolute, p.displayID == cmd.displayID {
            pendingMove = PointerMoveCommand(
                location: DesktopPoint(x: p.location.x + cmd.location.x,
                                       y: p.location.y + cmd.location.y),
                displayID: p.displayID, isAbsolute: false)   // sum deltas
        } else {
            if pendingMove?.isAbsolute == true { flushPendingMove() }
            pendingMove = cmd
        }
        ensureFlushLink()
    }

    private func coalesceScroll(dx: Double, dy: Double) {
        pendingScrollDX += dx
        pendingScrollDY += dy
        hasPendingScroll = true
        ensureFlushLink()
    }

    private func sendDiscrete(_ command: InputCommand) {
        flushPending()   // preserve ordering relative to accumulated moves/scroll
        enqueue(command)
    }

    private func flushPendingMove() {
        if let m = pendingMove { enqueue(.pointerMove(m)); pendingMove = nil }
    }

    private func flushPendingScroll() {
        if hasPendingScroll {
            enqueue(.scroll(ScrollCommand(deltaX: pendingScrollDX, deltaY: pendingScrollDY, isPrecise: true)))
            pendingScrollDX = 0; pendingScrollDY = 0; hasPendingScroll = false
        }
    }

    private func flushPending() {
        flushPendingMove()
        flushPendingScroll()
    }

    private func ensureFlushLink() {
        #if canImport(UIKit)
        guard flushLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.flushPending() },
                                 selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        flushLink = link
        #else
        flushPending()
        #endif
    }

    private func stopFlushLink() {
        flushLink?.invalidate()
        flushLink = nil
        pendingMove = nil
        pendingScrollDX = 0; pendingScrollDY = 0; hasPendingScroll = false
    }

    private func enqueue(_ command: InputCommand) {
        guard let sessionID else { return }
        startSenderIfNeeded()
        sendContinuation?.yield(InputCommandMessage(sessionID: sessionID, command: command))
    }

    private func startSenderIfNeeded() {
        guard senderTask == nil else { return }
        let stream = AsyncStream<InputCommandMessage>(bufferingPolicy: .unbounded) { cont in
            self.sendContinuation = cont
        }
        senderTask = Task { [weak self] in
            for await message in stream {
                guard let self else { break }
                do {
                    try await self.webRTCSessionManager.sendInputCommand(message)
                    self.commandsSent &+= 1
                    if self.lastError != nil { self.lastError = nil }
                } catch {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }
}

/// Vamp Control's pointer surface for a paired Bluetooth mouse/keyboard. The methods already
/// existed with exactly these signatures; declaring the conformance lets the shared
/// `BluetoothInputController` drive Control and Stream alike.
extension RemoteInteractionViewModel: RemotePointerInputSink {}
