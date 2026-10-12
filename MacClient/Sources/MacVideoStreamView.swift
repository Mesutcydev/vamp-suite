import AppKit
import AVFoundation
import Combine
import CoreMedia
import SharedModels
import SharedUtilities
import SwiftUI

@MainActor
protocol MacRemoteInputHandling: AnyObject {
    var isEnabled: Bool { get set }
    func updateViewGeometry(size: CGSize, pixelScale: Double)
    func updateDisplayMode(_ displayMode: DisplayMappingEngine.DisplayMode)
    func containsRemoteContent(_ point: CGPoint) -> Bool
    func remoteContentRect(in viewSize: CGSize) -> CGRect?
    func pointerMoved(to viewPoint: CGPoint)
    func pointerButton(_ button: MouseButton, action: ButtonAction, at viewPoint: CGPoint)
    func scrolled(deltaX: Double, deltaY: Double, isPrecise: Bool)
    func keyEvent(_ event: NSEvent, action: KeyAction)
}

extension MacRemoteInputController: MacRemoteInputHandling {
    func containsRemoteContent(_ point: CGPoint) -> Bool {
        mapper?.viewToDisplayLocal(DesktopPoint(x: point.x, y: point.y)) != nil
    }

    func remoteContentRect(in viewSize: CGSize) -> CGRect? {
        guard let rect = mapper?.fittedContentRect else { return nil }
        return CGRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height)
    }

    func keyEvent(_ event: NSEvent, action: KeyAction) {
        keyEvent(
            keyCode: event.keyCode,
            action: action,
            modifiers: Self.modifierFlags(from: event.modifierFlags))
    }
}

/// SwiftUI wrapper around the AppKit streaming surface: renders decoded frames
/// into an `AVSampleBufferDisplayLayer` and captures mouse/keyboard input.
struct MacVideoStreamView: NSViewRepresentable {
    let renderer: VideoRendererViewModel
    let input: any MacRemoteInputHandling
    var isInputEnabled: Bool
    var usesLocalCursor: Bool
    var displayMode: DisplayMappingEngine.DisplayMode = .fitDisplay
    var onKeyboardFocusChange: (Bool) -> Void = { _ in }
    var keepsDisplayShortcutsLocal = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RemoteStreamNSView {
        let view = RemoteStreamNSView()
        view.keepsDisplayShortcutsLocal = keepsDisplayShortcutsLocal
        view.onKeyboardFocusChange = onKeyboardFocusChange
        view.input = input
        view.isInputEnabled = isInputEnabled
        view.usesLocalCursor = usesLocalCursor
        view.displayMode = displayMode
        input.isEnabled = isInputEnabled
        input.updateDisplayMode(displayMode)
        context.coordinator.cancellable = renderer.framePublisher
            .sink { [weak view] buffer in view?.display(pixelBuffer: buffer) }
        return view
    }

    func updateNSView(_ nsView: RemoteStreamNSView, context: Context) {
        nsView.keepsDisplayShortcutsLocal = keepsDisplayShortcutsLocal
        nsView.onKeyboardFocusChange = onKeyboardFocusChange
        nsView.isInputEnabled = isInputEnabled
        nsView.usesLocalCursor = usesLocalCursor
        nsView.displayMode = displayMode
        // Keep the controller's own gate in sync so any coalesced send path is
        // also suppressed in view-only mode, not just the event handlers.
        input.isEnabled = isInputEnabled
        input.updateDisplayMode(displayMode)
    }

    static func dismantleNSView(_ nsView: RemoteStreamNSView, coordinator: Coordinator) {
        coordinator.cancellable?.cancel()
        nsView.stopInputCapture()
        nsView.isInputEnabled = false
        nsView.input?.isEnabled = false
        nsView.setLocalCursorHidden(false)
        nsView.display(pixelBuffer: nil)
    }

    final class Coordinator {
        var cancellable: AnyCancellable?
    }
}

/// Layer-backed NSView whose backing layer is an `AVSampleBufferDisplayLayer`
/// (zero-copy GPU presentation of decoded frames). Also the first responder for
/// the session: every local mouse/keyboard event over the video is translated
/// into a remote input command.
final class RemoteStreamNSView: NSView {

    var input: (any MacRemoteInputHandling)?
    var isInputEnabled = true {
        willSet {
            if !newValue { arrowKeyMonitor.releasePressedKeys(); setLocalCursorHidden(false) }
        }
        didSet { reportKeyboardFocus() }
    }
    var onKeyboardFocusChange: (Bool) -> Void = { _ in }
    var keepsDisplayShortcutsLocal = true
    private var reportedKeyboardFocus = false
    private var focusObservers: [NSObjectProtocol] = []
    private let arrowKeyMonitor = RemoteArrowKeyMonitor()
    var usesLocalCursor = false {
        didSet {
            if usesLocalCursor { setLocalCursorHidden(false) }
        }
    }
    var displayMode: DisplayMappingEngine.DisplayMode = .fitDisplay {
        didSet { updateVideoGravity() }
    }

    private var displayLayer = AVSampleBufferDisplayLayer()
    private var formatDescription: CMVideoFormatDescription?
    private var trackingArea: NSTrackingArea?
    /// Set when a double-click was forwarded as `.doubleClick` so the matching
    /// local mouse-up isn't also forwarded (the host posts the full pair itself).
    private var suppressNextUpForButton: Set<MouseButton> = []
    /// AppKit no longer consistently promotes Control-primary click into a secondary event.
    /// Track the translated pair explicitly so down/up can never split across buttons.
    private var controlClickIsDown = false
    /// Whether the local cursor is currently hidden over the stream content.
    /// `NSCursor.hide()`/`unhide()` are counter-balanced app-wide, so every
    /// hide must be matched by exactly one unhide.
    private var isLocalCursorHidden = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
        updateVideoGravity()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func updateVideoGravity() {
        switch displayMode {
        case .fillScreen:
            displayLayer.videoGravity = .resizeAspectFill
        case .fitDisplay, .actualSize:
            displayLayer.videoGravity = .resizeAspect
        }
        layoutDisplayLayer()
    }

    /// Top-left origin so view coordinates match the shared coordinate mapper.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isInputEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Geometry

    override func layout() {
        super.layout()
        notifyGeometry()
        layoutDisplayLayer()
    }

    /// Positions the video layer for the current display mode. In `.actualSize`
    /// the layer is pinned to the mapper's 1:1 content rect so the rendered
    /// pixels and the input mapping always agree (the source of the
    /// offset/double-cursor bug); other modes fill the view bounds.
    private func layoutDisplayLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if displayMode == .actualSize, let rect = input?.remoteContentRect(in: bounds.size) {
            displayLayer.frame = NSRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: rect.size.width,
                height: rect.size.height
            )
        } else {
            displayLayer.frame = bounds
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notifyGeometry()
        window?.makeFirstResponder(self)
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
                focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if name == NSWindow.willBeginSheetNotification {
                            self?.arrowKeyMonitor.releasePressedKeys()
                            self?.reportKeyboardFocus(focused: false)
                        } else { self?.reportKeyboardFocus() }
                    }
                })
            }
            arrowKeyMonitor.start(for: self, isEnabled: { [weak self] in
                self?.isInputEnabled == true
            }, send: { [weak self] event, action in
                self?.input?.keyEvent(event, action: action)
            })
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { reportKeyboardFocus(focused: isInputEnabled && window?.isKeyWindow == true && window?.attachedSheet == nil) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        arrowKeyMonitor.releasePressedKeys()
        reportKeyboardFocus(focused: false)
        return super.resignFirstResponder()
    }

    private func reportKeyboardFocus(focused: Bool? = nil) {
        let value = focused ?? (isInputEnabled && window?.isKeyWindow == true
            && window?.firstResponder === self && window?.attachedSheet == nil)
        guard reportedKeyboardFocus != value else { return }
        reportedKeyboardFocus = value
        // Never mutate SwiftUI state synchronously from updateNSView.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reportedKeyboardFocus == value else { return }
            self.onKeyboardFocusChange(value)
        }
    }

    func stopInputCapture() {
        arrowKeyMonitor.stop()
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        focusObservers.removeAll()
        reportKeyboardFocus(focused: false)
    }

    private func notifyGeometry() {
        input?.updateViewGeometry(
            size: bounds.size,
            pixelScale: Double(window?.backingScaleFactor ?? 2)
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Rendering

    func display(pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer else {
            VideoLayerPresenter.updateDynamicRange(for: nil, on: displayLayer)
            displayLayer.flushAndRemoveImage()
            formatDescription = nil
            return
        }

        // A session can legitimately fall back from HDR10 to SDR. EDR must follow
        // the actual decoded buffer, not the user's quality preset or the first
        // frame that happened to create this view.
        VideoLayerPresenter.updateDynamicRange(for: pixelBuffer, on: displayLayer)

        // `flush()` does not clear a failed layer; `flushAndRemoveImage()` does.
        if displayLayer.status == .failed {
            displayLayer.flushAndRemoveImage()
            formatDescription = nil
        }

        if formatDescription == nil ||
            !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            var fmt: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fmt)
            formatDescription = fmt
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: .invalid,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return }

        // Live video: present immediately rather than by timestamp.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        displayLayer.enqueue(sampleBuffer)
    }

    // MARK: - Mouse

    private func viewPoint(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopInputCapture()
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            setLocalCursorHidden(false)
        }
    }

    /// Balanced hide/unhide of the local cursor. Hidden while it tracks over
    /// stream content so only the remote (host) cursor is visible — no
    /// doubled/offset pointers.
    func setLocalCursorHidden(_ hidden: Bool) {
        guard hidden != isLocalCursorHidden else { return }
        isLocalCursorHidden = hidden
        if hidden {
            NSCursor.hide()
        } else {
            NSCursor.unhide()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = viewPoint(for: event)
        guard isInputEnabled else {
            setLocalCursorHidden(false)
            return
        }
        input?.pointerMoved(to: point)
        let insideContent = input?.containsRemoteContent(point) == true
        setLocalCursorHidden(!usesLocalCursor && insideContent)
    }

    override func mouseExited(with event: NSEvent) {
        setLocalCursorHidden(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInputEnabled else { return }
        input?.pointerMoved(to: viewPoint(for: event))
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard isInputEnabled else { return }
        input?.pointerMoved(to: viewPoint(for: event))
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard isInputEnabled else { return }
        input?.pointerMoved(to: viewPoint(for: event))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let translated = RemotePrimaryClickTranslation.button(
            controlPressed: event.modifierFlags.contains(.control))
        if translated == .right {
            controlClickIsDown = true
        }
        handleButton(translated, isDown: true, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        if controlClickIsDown {
            controlClickIsDown = false
            handleButton(.right, isDown: false, event: event)
        } else {
            handleButton(.left, isDown: false, event: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleButton(.right, isDown: true, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        handleButton(.right, isDown: false, event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleButton(.middle, isDown: true, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        handleButton(.middle, isDown: false, event: event)
    }

    private func handleButton(_ button: MouseButton, isDown: Bool, event: NSEvent) {
        guard isInputEnabled else { return }
        let point = viewPoint(for: event)
        if isDown {
            if event.clickCount == 2 {
                // The host posts the complete double-click pair (clickState 2);
                // swallow the local mouse-up that follows.
                suppressNextUpForButton.insert(button)
                input?.pointerButton(button, action: .doubleClick, at: point)
            } else {
                input?.pointerButton(button, action: .down, at: point)
            }
        } else {
            if suppressNextUpForButton.remove(button) != nil { return }
            input?.pointerButton(button, action: .up, at: point)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard isInputEnabled else { return }
        input?.scrolled(
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY),
            isPrecise: event.hasPreciseScrollingDeltas
        )
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard isInputEnabled else { return }
        // No super: avoids the system beep for "unhandled" keys.
        input?.keyEvent(event, action: .down)
    }

    override func keyUp(with event: NSEvent) {
        guard isInputEnabled else { return }
        input?.keyEvent(event, action: .up)
    }

    /// Forward Cmd-shortcuts to the host (Cmd+C/V, Cmd+Tab won't get here, but
    /// app-level equivalents do) except the ones this app binds in its own menus
    /// — see `RemoteKeyEquivalentPolicy`. ⌘W is deliberately not reserved: in a
    /// session it should close a window on the *remote* Mac.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isInputEnabled, event.type == .keyDown,
              window?.isKeyWindow == true, window?.firstResponder === self,
              window?.attachedSheet == nil else { return false }
        guard event.modifierFlags.contains(.command) else { return false }
        if RemoteKeyEquivalentPolicy.staysLocal(
            characters: event.charactersIgnoringModifiers ?? "",
            modifiers: event.modifierFlags,
            keepsDisplayShortcutsLocal: keepsDisplayShortcutsLocal
        ) {
            return false
        }
        // Cmd-shortcuts don't generate a matching keyUp through this path, so send
        // the full down/up pair here — otherwise the key sticks down on the host.
        input?.keyEvent(event, action: .down)
        input?.keyEvent(event, action: .up)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isInputEnabled else { return }
        guard let flag = Self.modifierFlag(forKeyCode: event.keyCode) else { return }
        let isDown = event.modifierFlags.contains(flag)
        input?.keyEvent(event, action: isDown ? .down : .up)
    }

    private static func modifierFlag(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
        default: return nil
        }
    }
}
