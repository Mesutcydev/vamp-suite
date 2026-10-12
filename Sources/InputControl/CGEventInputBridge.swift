#if os(macOS)
import CoreGraphics
import Foundation
import SharedModels

/// macOS implementation of `PlatformInputBridge` using CGEvent API.
/// Posts mouse, keyboard, scroll, and text events via the HID event tap.
///
/// Tracks mouse button state to correctly send drag events (leftMouseDragged, etc.)
/// instead of plain mouseMoved when a button is held.
public final class CGEventInputBridge: PlatformInputBridge, @unchecked Sendable {
    /// A physical ANSI key paired with the modifier state needed to reproduce a
    /// printable ASCII character.  The login window ignores Unicode-only events
    /// (virtual key 0) for secure fields, so remote unlock needs a real hardware
    /// key code as well as the Unicode payload.
    struct PhysicalKey: Equatable {
        let keyCode: UInt16
        let modifiers: KeyboardModifierFlags
    }

    /// Standard macOS ANSI virtual key codes. These are intentionally limited to
    /// printable ASCII: any character outside this set still uses Unicode input
    /// below, which preserves normal typing for non-ASCII keyboard layouts.
    private static let ansiUnshiftedKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
        "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49,
        "`": 50
    ]

    private static let ansiShiftedKeyCodes: [Character: UInt16] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5,
        "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11,
        "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17,
        "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23,
        "+": 24, "(": 25, "&": 26, "_": 27, "*": 28, ")": 29,
        "}": 30, "O": 31, "U": 32, "{": 33, "I": 34, "P": 35,
        "L": 37, "J": 38, "\"": 39, "K": 40, ":": 41, "|": 42,
        "<": 43, "?": 44, "N": 45, "M": 46, ">": 47, "~": 50
    ]

    static func physicalKey(for character: Character) -> PhysicalKey? {
        if let keyCode = ansiUnshiftedKeyCodes[character] {
            return PhysicalKey(keyCode: keyCode, modifiers: [])
        }
        if let keyCode = ansiShiftedKeyCodes[character] {
            return PhysicalKey(keyCode: keyCode, modifiers: .shift)
        }
        return nil
    }

    private let eventSource: CGEventSource?
    // Guards the mutable pointer state below. `releaseHeldPointerButton()` is
    // invoked from the MainActor at session teardown while the router's input
    // task may still be mid-inject on a background executor, so these fields are
    // touched from two threads. Keep CGEvent.post calls outside the lock.
    private let stateLock = NSLock()
    private var _heldButton: MouseButton?
    private var heldKeys: Set<UInt16> = []
    // Carry the truncated fraction of a scroll between events so slow, precise
    // scrolling isn't silently dropped by Int32() rounding to zero.
    private var _scrollResidualX: Double = 0
    private var _scrollResidualY: Double = 0
    // Authoritative last-posted cursor position for relative moves. Re-reading the live
    // CGEvent cursor each relative event folds in external/asynchronous cursor motion and
    // compounds jitter; instead we accumulate deltas against this internal position and
    // resync to the live cursor only when it's nil (session start / first move) or on an
    // absolute move. nil → next relative move seeds it from the live cursor.
    private var _lastPostedPoint: CGPoint?

    public init(sourceState: CGEventSourceStateID = .privateState) {
        // Desktop control defaults to independent keyboard/modifier state. The
        // dedicated login-window service selects HID state for its physical keys.
        // Both paths explicitly set keyboard flags and post through the HID tap.
        eventSource = CGEventSource(stateID: sourceState)
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    // MARK: - Mouse Move

    public func postMouseMove(to point: DesktopPoint) throws {
        let cgPoint = CGPoint(x: point.x, y: point.y)
        // Absolute move is authoritative — resync the relative-move anchor to it so the
        // next relative delta builds from the true on-screen position.
        let held = withStateLock { () -> MouseButton? in
            _lastPostedPoint = cgPoint
            return _heldButton
        }
        let eventType: CGEventType
        if let held {
            eventType = mouseDragType(for: held)
        } else {
            eventType = .mouseMoved
        }
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: eventType,
            mouseCursorPosition: cgPoint,
            mouseButton: cgMouseButton(for: held ?? .left)
        ) else {
            throw InputInjectionError.platformBridgeFailed("Failed to create mouse move event")
        }
        event.post(tap: .cghidEventTap)
    }

    public func postMouseMoveRelative(deltaX: Double, deltaY: Double) throws {
        // Anchor the delta to our internal last-posted position rather than re-reading the
        // live cursor each event. Seed from the live cursor only when the anchor is nil
        // (session start / first move after an absolute move), which avoids compounding
        // external cursor jitter into every relative move.
        let anchor: CGPoint
        if let existing = withStateLock({ _lastPostedPoint }) {
            anchor = existing
        } else {
            guard let currentEvent = CGEvent(source: nil) else {
                throw InputInjectionError.platformBridgeFailed("Failed to query cursor position")
            }
            anchor = currentEvent.location
        }
        var newPoint = CGPoint(x: anchor.x + deltaX, y: anchor.y + deltaY)
        // Clamp to the union of all displays so a fast flick can't strand the
        // cursor off-screen or warp it to a non-streamed display.
        let bounds = Self.globalDisplayBounds()
        if !bounds.isInfinite, !bounds.isNull {
            newPoint.x = min(max(newPoint.x, bounds.minX), bounds.maxX - 1)
            newPoint.y = min(max(newPoint.y, bounds.minY), bounds.maxY - 1)
        }

        // Store the clamped position as the new anchor for the next relative delta.
        let held = withStateLock { () -> MouseButton? in
            _lastPostedPoint = newPoint
            return _heldButton
        }
        let eventType: CGEventType
        if let held {
            eventType = mouseDragType(for: held)
        } else {
            eventType = .mouseMoved
        }
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: eventType,
            mouseCursorPosition: newPoint,
            mouseButton: cgMouseButton(for: held ?? .left)
        ) else {
            throw InputInjectionError.platformBridgeFailed("Failed to create relative mouse move event")
        }
        event.post(tap: .cghidEventTap)
    }

    /// Union of all active display bounds, in global (top-left origin) coordinates
    /// that match `CGEvent` cursor positions.
    private static func globalDisplayBounds() -> CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return .infinite }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return .infinite }
        var union = CGRect.null
        for id in ids { union = union.union(CGDisplayBounds(id)) }
        return union.isNull ? .infinite : union
    }

    /// Release a held mouse button (drag in progress) so an end-of-session or a
    /// lost button-up can't leave the host permanently dragging.
    public func releaseHeldPointerButton() {
        // Clear accumulated sub-pixel scroll so a residual can't carry into the next session,
        // and atomically read-and-clear the held button so a teardown overlapping an in-flight
        // input event can't lose the mouse-up that prevents a stuck drag.
        let held = withStateLock { () -> MouseButton? in
            _scrollResidualX = 0
            _scrollResidualY = 0
            // Drop the relative-move anchor so the next session reseeds from the live
            // cursor instead of carrying a stale position across a teardown.
            _lastPostedPoint = nil
            let previous = _heldButton
            _heldButton = nil
            return previous
        }
        guard let held else { return }
        let cgPoint = CGEvent(source: nil)?.location ?? .zero
        if let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: mouseUpType(for: held),
            mouseCursorPosition: cgPoint,
            mouseButton: cgMouseButton(for: held)
        ) {
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Mouse Button

    public func postMouseButton(_ button: MouseButton, action: ButtonAction, at point: DesktopPoint?) throws {
        let cgPoint: CGPoint
        if let point {
            cgPoint = CGPoint(x: point.x, y: point.y)
            // A button at an explicit point moves the cursor there — treat it as an
            // absolute move and resync the relative-move anchor.
            withStateLock { _lastPostedPoint = cgPoint }
        } else {
            cgPoint = CGEvent(source: nil)?.location ?? .zero
        }

        let cgButton = cgMouseButton(for: button)

        switch action {
        case .down:
            withStateLock { _heldButton = button }
            let eventType = mouseDownType(for: button)
            guard let event = CGEvent(
                mouseEventSource: eventSource,
                mouseType: eventType,
                mouseCursorPosition: cgPoint,
                mouseButton: cgButton
            ) else {
                throw InputInjectionError.platformBridgeFailed("Failed to create mouse down event")
            }
            event.post(tap: .cghidEventTap)

        case .up:
            withStateLock { _heldButton = nil }
            let eventType = mouseUpType(for: button)
            guard let event = CGEvent(
                mouseEventSource: eventSource,
                mouseType: eventType,
                mouseCursorPosition: cgPoint,
                mouseButton: cgButton
            ) else {
                throw InputInjectionError.platformBridgeFailed("Failed to create mouse up event")
            }
            event.post(tap: .cghidEventTap)

        case .click:
            // Capture and encoding can keep the host busy enough that two freshly-created
            // CGEvents receive the same default timestamp. Some controls then observe cursor
            // movement but discard the zero-duration down/up pair. Make every click explicitly
            // ordered, just as the double-click path already does.
            let base = mach_absolute_time()
            try postSingleClick(
                button: button,
                cgButton: cgButton,
                at: cgPoint,
                clickCount: 1,
                downTimestamp: base,
                upTimestamp: base + 1
            )

        case .doubleClick:
            // The two click pairs are posted back-to-back, so their CGEvents can carry
            // near-identical default timestamps and fail to register as a double-click.
            // Stamp explicit, strictly-increasing timestamps (mach absolute time) so the
            // window server sees an ordered click1 → click2 sequence — no Thread.sleep on
            // this hot path. Spread by ~1ms each so down<up<down<up ordering is unambiguous.
            let base = mach_absolute_time()
            let step: UInt64 = 1_000_000  // ~1ms in mach time units (close enough for ordering)
            try postSingleClick(button: button, cgButton: cgButton, at: cgPoint, clickCount: 1,
                                downTimestamp: base, upTimestamp: base + step)
            try postSingleClick(button: button, cgButton: cgButton, at: cgPoint, clickCount: 2,
                                downTimestamp: base + step * 2, upTimestamp: base + step * 3)
        }
    }

    private func postSingleClick(
        button: MouseButton,
        cgButton: CGMouseButton,
        at cgPoint: CGPoint,
        clickCount: Int64,
        downTimestamp: CGEventTimestamp? = nil,
        upTimestamp: CGEventTimestamp? = nil
    ) throws {
        let downType = mouseDownType(for: button)
        let upType = mouseUpType(for: button)

        guard let downEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: downType,
            mouseCursorPosition: cgPoint,
            mouseButton: cgButton
        ),
        let upEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: upType,
            mouseCursorPosition: cgPoint,
            mouseButton: cgButton
        ) else {
            throw InputInjectionError.platformBridgeFailed("Failed to create click events")
        }

        downEvent.setIntegerValueField(.mouseEventClickState, value: clickCount)
        upEvent.setIntegerValueField(.mouseEventClickState, value: clickCount)
        // Apply explicit timestamps so the window server always sees down before up.
        if let downTimestamp { downEvent.timestamp = downTimestamp }
        if let upTimestamp { upEvent.timestamp = upTimestamp }
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Scroll

    public func postScroll(deltaX: Double, deltaY: Double, isPrecise: Bool) throws {
        let units: CGScrollEventUnit = isPrecise ? .pixel : .line

        // Accumulate sub-unit deltas instead of truncating each event to zero.
        let (intX, intY) = withStateLock { () -> (Double, Double) in
            let accumulatedY = deltaY + _scrollResidualY
            let accumulatedX = deltaX + _scrollResidualX
            let roundedY = accumulatedY.rounded(.towardZero)
            let roundedX = accumulatedX.rounded(.towardZero)
            _scrollResidualY = accumulatedY - roundedY
            _scrollResidualX = accumulatedX - roundedX
            return (roundedX, roundedY)
        }

        // Nothing whole to emit yet — the remainder is carried to the next event.
        guard intY != 0 || intX != 0 else { return }

        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: units,
            wheelCount: 2,
            wheel1: Int32(intY),
            wheel2: Int32(intX),
            wheel3: 0
        ) else {
            throw InputInjectionError.platformBridgeFailed("Failed to create scroll event")
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    public func releaseHeldKeys() {
        let keys = withStateLock { () -> Set<UInt16> in
            let keys = heldKeys
            heldKeys.removeAll()
            return keys
        }
        for key in keys {
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: false) else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }

    public func postKeyEvent(keyCode: UInt16, action: KeyAction, modifiers: KeyboardModifierFlags) throws {
        try postKeyEvent(keyCode: keyCode, action: action, modifiers: modifiers, unicodeString: nil)
    }

    func postKeyEvent(
        keyCode: UInt16,
        action: KeyAction,
        modifiers: KeyboardModifierFlags,
        unicodeString: String?
    ) throws {
        let keyDown = action == .down
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: keyCode,
            keyDown: keyDown
        ) else {
            throw InputInjectionError.platformBridgeFailed("Failed to create key event")
        }
        event.flags = cgEventFlags(from: modifiers)
        if let unicodeString, !unicodeString.isEmpty {
            let utf16 = Array(unicodeString.utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        }
        withStateLock {
            if keyDown { heldKeys.insert(keyCode) } else { heldKeys.remove(keyCode) }
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Text Input

    public func postTextInput(_ text: String) throws {
        guard !text.isEmpty else { return }

        // Type one character per key-down/up pair instead of stuffing the whole string into a
        // single event's Unicode buffer. For ASCII, pair that payload with the corresponding
        // physical ANSI virtual key. loginwindow's secure field rejects virtual-key-0 Unicode-only
        // events, whereas a real key code is accepted as hardware input. Unicode remains attached
        // so the intended character survives non-US keyboard layouts; unsupported characters keep
        // the existing Unicode-only behavior.
        for character in text {
            let utf16 = Array(String(character).utf16)
            let physicalKey = Self.physicalKey(for: character)
            guard let downEvent = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: physicalKey?.keyCode ?? 0,
                keyDown: true
            ) else {
                throw InputInjectionError.platformBridgeFailed("Failed to create text input event")
            }
            downEvent.flags = cgEventFlags(from: physicalKey?.modifiers ?? [])
            downEvent.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            downEvent.post(tap: .cghidEventTap)

            guard let upEvent = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: physicalKey?.keyCode ?? 0,
                keyDown: false
            ) else { continue }
            upEvent.flags = cgEventFlags(from: physicalKey?.modifiers ?? [])
            upEvent.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            upEvent.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Helpers

    private func cgMouseButton(for button: MouseButton) -> CGMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    private func mouseDownType(for button: MouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    private func mouseUpType(for button: MouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    private func mouseDragType(for button: MouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }

    private func cgEventFlags(from modifiers: KeyboardModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}
#endif
