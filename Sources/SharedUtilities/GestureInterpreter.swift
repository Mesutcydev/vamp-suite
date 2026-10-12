import Foundation
import SharedModels

/// Pure-logic interpreter that converts iOS touch gestures into `InputCommand` values.
/// Isolated from UIKit/SwiftUI gesture recognizers — those call into this.
public struct GestureInterpreter: Sendable {

    /// The display being targeted.
    public var displayID: String

    /// Coordinate mapper for the current viewport.
    public var mapper: ViewportCoordinateMapper

    public init(displayID: String, mapper: ViewportCoordinateMapper) {
        self.displayID = displayID
        self.mapper = mapper
    }

    // MARK: - Tap → Click

    /// Single tap at a view-space point → left click at display-local position (absolute mode)
    /// or at the supplied location (relative mode, nil location means click-in-place).
    public func tap(at viewPoint: DesktopPoint) -> InputCommand? {
        switch mapper.interactionMode {
        case .absolute:
            guard let displayLocal = mapper.viewToDisplayLocal(viewPoint) else { return nil }
            return .pointerButton(PointerButtonCommand(
                button: .left,
                action: .click,
                location: displayLocal,
                displayID: displayID
            ))
        case .relative:
            return .pointerButton(PointerButtonCommand(
                button: .left,
                action: .click,
                location: nil
            ))
        }
    }

    /// Double tap → double-click.
    public func doubleTap(at viewPoint: DesktopPoint) -> InputCommand? {
        switch mapper.interactionMode {
        case .absolute:
            guard let displayLocal = mapper.viewToDisplayLocal(viewPoint) else { return nil }
            return .pointerButton(PointerButtonCommand(
                button: .left,
                action: .doubleClick,
                location: displayLocal,
                displayID: displayID
            ))
        case .relative:
            return .pointerButton(PointerButtonCommand(
                button: .left,
                action: .doubleClick,
                location: nil
            ))
        }
    }

    /// Two-finger tap → right-click.
    public func twoFingerTap(at viewPoint: DesktopPoint) -> InputCommand? {
        switch mapper.interactionMode {
        case .absolute:
            guard let displayLocal = mapper.viewToDisplayLocal(viewPoint) else { return nil }
            return .pointerButton(PointerButtonCommand(
                button: .right,
                action: .click,
                location: displayLocal,
                displayID: displayID
            ))
        case .relative:
            return .pointerButton(PointerButtonCommand(
                button: .right,
                action: .click,
                location: nil
            ))
        }
    }

    /// Three-finger tap → middle-click.
    public func threeFingerTap(at viewPoint: DesktopPoint) -> InputCommand? {
        switch mapper.interactionMode {
        case .absolute:
            guard let displayLocal = mapper.viewToDisplayLocal(viewPoint) else { return nil }
            return .pointerButton(PointerButtonCommand(
                button: .middle,
                action: .click,
                location: displayLocal,
                displayID: displayID
            ))
        case .relative:
            return .pointerButton(PointerButtonCommand(
                button: .middle,
                action: .click,
                location: nil
            ))
        }
    }

    // MARK: - Drag → Pointer Move

    /// Single-finger drag delta → pointer move (relative mode) or absolute move.
    public func drag(translation: DesktopPoint, currentViewPoint: DesktopPoint) -> InputCommand {
        switch mapper.interactionMode {
        case .absolute:
            if let displayLocal = mapper.viewToDisplayLocal(currentViewPoint) {
                return .pointerMove(PointerMoveCommand(
                    location: displayLocal,
                    displayID: displayID,
                    isAbsolute: true
                ))
            }
            // Outside the streamed content (letterbox/pillarbox): clamp to the
            // nearest content edge and STAY absolute, so the cursor tracks to the
            // edge instead of discontinuously jumping when switching to relative.
            let rect = mapper.fittedContentRect
            let clampedView = DesktopPoint(
                x: min(max(currentViewPoint.x, rect.origin.x), rect.origin.x + rect.size.width - 1),
                y: min(max(currentViewPoint.y, rect.origin.y), rect.origin.y + rect.size.height - 1)
            )
            if let edge = mapper.viewToDisplayLocal(clampedView) {
                return .pointerMove(PointerMoveCommand(
                    location: edge,
                    displayID: displayID,
                    isAbsolute: true
                ))
            }
            // Last-resort fallback to relative.
            let delta = mapper.viewDeltaToDisplayDelta(dx: translation.x, dy: translation.y)
            return .pointerMove(PointerMoveCommand(
                location: delta,
                displayID: displayID,
                isAbsolute: false
            ))
        case .relative:
            let delta = mapper.viewDeltaToDisplayDelta(dx: translation.x, dy: translation.y)
            return .pointerMove(PointerMoveCommand(
                location: delta,
                displayID: displayID,
                isAbsolute: false
            ))
        }
    }

    // MARK: - Drag Lock Scaffold

    /// Begin a drag-lock: mouse down at current position.
    public func dragLockBegin(at viewPoint: DesktopPoint) -> InputCommand? {
        switch mapper.interactionMode {
        case .absolute:
            guard let displayLocal = mapper.viewToDisplayLocal(viewPoint) else { return nil }
            return .pointerButton(PointerButtonCommand(
                button: .left,
                action: .down,
                location: displayLocal,
                displayID: displayID
            ))
        case .relative:
            return .pointerButton(PointerButtonCommand(
                button: .left,
                action: .down,
                location: nil
            ))
        }
    }

    /// End a drag-lock: mouse up.
    public func dragLockEnd(at viewPoint: DesktopPoint) -> InputCommand? {
        switch mapper.interactionMode {
        case .absolute:
            guard let displayLocal = mapper.viewToDisplayLocal(viewPoint) else { return nil }
            return .pointerButton(PointerButtonCommand(
                button: .left,
                action: .up,
                location: displayLocal,
                displayID: displayID
            ))
        case .relative:
            return .pointerButton(PointerButtonCommand(
                button: .left,
                action: .up,
                location: nil
            ))
        }
    }

    // MARK: - Scroll

    /// Two-finger scroll: convert view-space scroll delta to scroll command.
    public func scroll(deltaX: Double, deltaY: Double) -> InputCommand {
        // Scale scroll deltas using the same display-to-view ratio
        let scaled = mapper.viewDeltaToDisplayDelta(dx: deltaX, dy: deltaY)
        return .scroll(ScrollCommand(
            deltaX: scaled.x,
            deltaY: scaled.y,
            isPrecise: true
        ))
    }

    // MARK: - Text & Key

    /// Send a text string.
    public func textInput(_ text: String) -> InputCommand {
        .text(TextInputCommand(text: text))
    }

    /// Send a key press with optional modifiers.
    public func keyPress(keyCode: UInt16, action: KeyAction, modifiers: KeyboardModifierFlags = []) -> InputCommand {
        .key(KeyCommand(keyCode: keyCode, action: action, modifiers: modifiers))
    }
}
