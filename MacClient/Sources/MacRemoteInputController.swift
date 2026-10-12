import AppKit
import Foundation
import SharedModels
import SharedProtocol
import SharedUtilities
import TransportWebRTC

/// Converts local `NSEvent` input into `InputCommand`s for the host.
///
/// The Mac client uses absolute pointer mapping: the local cursor position over
/// the (aspect-fit) video is mapped to display-local coordinates with the same
/// `ViewportCoordinateMapper` the iOS client uses. Pointer moves and scrolls are
/// coalesced (~120 Hz) so a fast mouse doesn't flood the data channel, while
/// clicks and keys are sent immediately, ordered after any pending move.
@MainActor
final class MacRemoteInputController: ObservableObject {

    var sessionID: UUID?
    /// View-only mode gate; when false, all input is dropped.
    var isEnabled = false {
        didSet {
            guard !isEnabled else { return }
            pendingMove = nil
            pendingScrollDX = 0
            pendingScrollDY = 0
            flushTask?.cancel()
            flushTask = nil
            sendQueue.discardPendingInteractions()
        }
    }

    private let sessionManager: any WebRTCSessionManaging

    private var display: DisplayDescriptor?
    private var streamConfiguration: DisplayStreamConfiguration?
    private var viewSize: CGSize = .zero
    private var viewPixelScale: Double = 1
    private var displayMode: DisplayMappingEngine.DisplayMode = .fitDisplay
    private(set) var mapper: ViewportCoordinateMapper?

    private var sendQueue = MacRemoteInputSendQueue()
    private var sendTask: Task<Void, Never>?

    // Coalesced continuous input
    private var pendingMove: PointerMoveCommand?
    private var pendingScrollDX: Double = 0
    private var pendingScrollDY: Double = 0
    private var pendingScrollPrecise = true
    private var flushTask: Task<Void, Never>?

    init(sessionManager: any WebRTCSessionManaging) {
        self.sessionManager = sessionManager
    }

    func teardown() {
        flushTask?.cancel()
        flushTask = nil
        pendingMove = nil
        pendingScrollDX = 0
        pendingScrollDY = 0
        sendQueue.removeAll()
        sendTask?.cancel()
        sendTask = nil
    }

    // MARK: - Mapping

    func updateMapping(display: DisplayDescriptor?, streamConfiguration: DisplayStreamConfiguration?) {
        self.display = display
        self.streamConfiguration = streamConfiguration
        rebuildMapper()
    }

    func updateViewGeometry(size: CGSize, pixelScale: Double) {
        guard size != viewSize || pixelScale != viewPixelScale else { return }
        viewSize = size
        viewPixelScale = pixelScale
        rebuildMapper()
    }

    func updateDisplayMode(_ displayMode: DisplayMappingEngine.DisplayMode) {
        guard self.displayMode != displayMode else { return }
        self.displayMode = displayMode
        rebuildMapper()
    }

    private func rebuildMapper() {
        guard let display, viewSize.width > 1, viewSize.height > 1 else {
            mapper = nil
            return
        }
        mapper = ViewportCoordinateMapper(
            display: display,
            streamConfiguration: streamConfiguration,
            viewSize: DesktopSize(width: viewSize.width, height: viewSize.height),
            viewInsets: .zero,
            viewPixelScale: viewPixelScale,
            displayMode: displayMode,
            interactionMode: .absolute
        )
    }

    // MARK: - Pointer

    /// `viewPoint` is in top-left-origin view coordinates.
    func pointerMoved(to viewPoint: CGPoint) {
        guard isEnabled, let mapper, let display else { return }
        let point = DesktopPoint(x: viewPoint.x, y: viewPoint.y)
        guard let local = mapper.viewToDisplayLocal(point) else { return }
        pendingMove = PointerMoveCommand(location: local, displayID: display.id, isAbsolute: true)
        ensureFlushLoop()
    }

    func pointerButton(_ button: MouseButton, action: ButtonAction, at viewPoint: CGPoint) {
        guard isEnabled, let mapper, let display else { return }
        let point = DesktopPoint(x: viewPoint.x, y: viewPoint.y)
        let local = mapper.viewToDisplayLocal(point)
        // Move-then-click ordering: make sure the host cursor is at the click
        // location before the button event lands.
        flushPendingMove()
        enqueue(.pointerButton(PointerButtonCommand(
            button: button,
            action: action,
            location: local,
            displayID: local != nil ? display.id : nil
        )))
    }

    func scrolled(deltaX: Double, deltaY: Double, isPrecise: Bool) {
        guard isEnabled else { return }
        pendingScrollDX += deltaX
        pendingScrollDY += deltaY
        pendingScrollPrecise = isPrecise
        ensureFlushLoop()
    }

    // MARK: - Keyboard

    func keyEvent(keyCode: UInt16, action: KeyAction, modifiers: KeyboardModifierFlags) {
        guard isEnabled else { return }
        flushPendingMove()
        enqueue(.key(KeyCommand(keyCode: keyCode, action: action, modifiers: modifiers)))
    }

    /// Sends a complete press/release pair for shortcuts that macOS reserves
    /// before the remote stream view can receive them (notably Command-Tab).
    func keyPress(keyCode: UInt16, modifiers: KeyboardModifierFlags = []) {
        keyEvent(keyCode: keyCode, action: .down, modifiers: modifiers)
        keyEvent(keyCode: keyCode, action: .up, modifiers: modifiers)
    }

    func insertText(_ text: String) {
        guard isEnabled, !text.isEmpty else { return }
        enqueue(.text(TextInputCommand(text: text)))
    }

    // MARK: - Sending

    private func enqueue(_ command: InputCommand) {
        guard let sessionID else { return }
        sendQueue.enqueue(InputCommandMessage(sessionID: sessionID, command: command))
        startSenderIfNeeded()
    }

    private func startSenderIfNeeded() {
        guard sendTask == nil else { return }
        sendTask = Task { [weak self] in
            await self?.drainSendQueue()
        }
    }

    private func drainSendQueue() async {
        while !Task.isCancelled, let message = sendQueue.popFirst() {
            try? await sessionManager.sendInputCommand(message)
        }
        sendTask = nil
        // An event can arrive as the loop observes an empty queue. Recheck on
        // the actor before parking so that sample cannot be stranded.
        if !sendQueue.isEmpty { startSenderIfNeeded() }
    }

    private func flushPendingMove() {
        if let move = pendingMove {
            pendingMove = nil
            enqueue(.pointerMove(move))
        }
    }

    private func flushPendingScroll() {
        if pendingScrollDX != 0 || pendingScrollDY != 0 {
            let command = ScrollCommand(
                deltaX: pendingScrollDX,
                deltaY: pendingScrollDY,
                isPrecise: pendingScrollPrecise
            )
            pendingScrollDX = 0
            pendingScrollDY = 0
            enqueue(.scroll(command))
        }
    }

    /// Drains coalesced moves/scrolls at ~120 Hz while there is pending input,
    /// then parks itself.
    private func ensureFlushLoop() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            defer { self?.flushTask = nil }
            while let self, !Task.isCancelled {
                self.flushPendingMove()
                self.flushPendingScroll()
                try? await Task.sleep(nanoseconds: 8_000_000)
                guard let again = self.flushTask, !again.isCancelled else { return }
                if self.pendingMove == nil, self.pendingScrollDX == 0, self.pendingScrollDY == 0 {
                    return
                }
            }
        }
    }

    // MARK: - Modifier conversion

    nonisolated static func modifierFlags(from flags: NSEvent.ModifierFlags) -> KeyboardModifierFlags {
        var result: KeyboardModifierFlags = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.function) { result.insert(.function) }
        return result
    }
}
