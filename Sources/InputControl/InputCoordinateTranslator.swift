import Foundation
import SharedModels

// MARK: - Input Coordinate Translator

/// Centralized, pure coordinate translation from display-local to host-global coordinates.
/// Uses DisplayLayout to handle multi-monitor setups, negative origins, and scale factors.
public enum InputCoordinateTranslator {

    /// Translate a display-local point to the host's global desktop coordinate space.
    ///
    /// - Parameters:
    ///   - localPoint: Point relative to the display's logical origin (0,0 = top-left of the display).
    ///   - displayID: Identifier of the display the point is relative to.
    ///   - layout: The current host display layout.
    /// - Returns: The global desktop point, or an error if the display is unknown.
    public static func localToGlobal(
        _ localPoint: DesktopPoint,
        displayID: String,
        layout: DisplayLayout
    ) -> Result<DesktopPoint, InputInjectionError> {
        // If the requested display is gone (e.g. a monitor was unplugged mid-session), fall back to
        // the primary display instead of dropping the input — the client re-syncs to a valid display
        // shortly, and routing to primary keeps control responsive in the meantime. Only fail when
        // there are no displays at all.
        let display = layout.display(withID: displayID)
            ?? layout.primaryDisplayID.flatMap { layout.display(withID: $0) }
            ?? layout.displays.first
        guard let display else {
            return .failure(.displayNotFound(displayID))
        }
        let globalPoint = DesktopPoint(
            x: localPoint.x + display.frame.origin.x,
            y: localPoint.y + display.frame.origin.y
        )
        return .success(globalPoint)
    }

    /// Translate a global desktop point back to display-local coordinates.
    public static func globalToLocal(
        _ globalPoint: DesktopPoint,
        displayID: String,
        layout: DisplayLayout
    ) -> Result<DesktopPoint, InputInjectionError> {
        guard let display = layout.display(withID: displayID) else {
            return .failure(.displayNotFound(displayID))
        }
        let localPoint = DesktopPoint(
            x: globalPoint.x - display.frame.origin.x,
            y: globalPoint.y - display.frame.origin.y
        )
        return .success(localPoint)
    }

    /// Convert a display-local point to physical pixel coordinates.
    /// Applies the display's scale factor after translating to local.
    public static func localToPixel(
        _ localPoint: DesktopPoint,
        displayID: String,
        layout: DisplayLayout
    ) -> Result<DesktopPoint, InputInjectionError> {
        guard let display = layout.display(withID: displayID) else {
            return .failure(.displayNotFound(displayID))
        }
        return .success(localPoint.scaled(by: display.scaleFactor))
    }

    /// Validate that a local point is within the display's logical bounds.
    public static func isWithinBounds(
        _ localPoint: DesktopPoint,
        displayID: String,
        layout: DisplayLayout
    ) -> Bool {
        guard let display = layout.display(withID: displayID) else { return false }
        return localPoint.x >= 0
            && localPoint.y >= 0
            && localPoint.x <= display.frame.size.width
            && localPoint.y <= display.frame.size.height
    }

    /// Translate an `InputCommand`'s embedded coordinates from display-local to global.
    /// Only pointer move (absolute) commands have display-local coordinates that need translation.
    /// All other command types pass through unchanged.
    public static func translateToGlobal(
        _ command: InputCommand,
        layout: DisplayLayout
    ) -> Result<InputCommand, InputInjectionError> {
        switch command {
        case .pointerMove(let move):
            guard move.isAbsolute else {
                // Relative moves are deltas, no translation needed
                return .success(command)
            }
            switch localToGlobal(move.location, displayID: move.displayID, layout: layout) {
            case .success(let globalPoint):
                let translated = PointerMoveCommand(
                    location: globalPoint,
                    displayID: move.displayID,
                    isAbsolute: true
                )
                return .success(.pointerMove(translated))
            case .failure(let error):
                return .failure(error)
            }

        case .pointerButton(let button):
            guard let location = button.location, let displayID = button.displayID else {
                return .success(command)
            }
            switch localToGlobal(location, displayID: displayID, layout: layout) {
            case .success(let globalPoint):
                let translated = PointerButtonCommand(
                    button: button.button,
                    action: button.action,
                    location: globalPoint,
                    displayID: displayID
                )
                return .success(.pointerButton(translated))
            case .failure(let error):
                return .failure(error)
            }

        case .scroll, .key, .text:
            return .success(command)
        }
    }
}
