import Foundation
import SharedModels

// MARK: - Platform Input Bridge Protocol

/// Abstraction over the OS-level input event posting mechanism.
/// On macOS, the concrete implementation uses `CGEvent`.
/// This protocol isolates platform-specific code from the injection service.
public protocol PlatformInputBridge: Sendable {
    /// Post an absolute mouse move event to the given global desktop coordinate.
    func postMouseMove(to point: DesktopPoint) throws

    /// Post a relative mouse move (delta) event.
    func postMouseMoveRelative(deltaX: Double, deltaY: Double) throws

    /// Post a mouse button event (down / up / click / doubleClick).
    func postMouseButton(_ button: MouseButton, action: ButtonAction, at point: DesktopPoint?) throws

    /// Post a scroll wheel event (vertical and/or horizontal).
    func postScroll(deltaX: Double, deltaY: Double, isPrecise: Bool) throws

    /// Post a key down or key up event with optional modifier flags.
    func postKeyEvent(keyCode: UInt16, action: KeyAction, modifiers: KeyboardModifierFlags) throws

    /// Post a text input event using Unicode string insertion.
    func postTextInput(_ text: String) throws

    /// Release any mouse button currently held down (a drag in progress). Called
    /// when a session ends so a lost button-up can't leave the host stuck in a
    /// permanent drag. Default implementation is a no-op.
    func releaseHeldPointerButton()
    func releaseHeldKeys()
}

public extension PlatformInputBridge {
    func releaseHeldPointerButton() {}
    func releaseHeldKeys() {}
}
