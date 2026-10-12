import Foundation
import SharedModels

// MARK: - Input Command Validation

/// Pure validation rules for the host-side input command routing pipeline.
/// Separates validation logic from the router so it can be unit-tested independently.

public enum InputRouterRejection: Error, Equatable, Sendable {
    case routerDisabled
    case noActiveSession
    case sessionMismatch(expected: UUID, received: UUID)
    case notConnected(ConnectionState)
    case invalidContent(String)
}

public enum InputCommandValidation {

    /// Maximum allowed absolute coordinate value (generous for multi-display).
    private static let maxCoordinate: Double = 100_000
    /// Maximum magnitude of a single *relative* pointer delta (px per event).
    /// Bounds how far one event can warp the cursor; coalesced moves stay well under this.
    private static let maxRelativeDelta: Double = 4_000
    /// Maximum allowed text input length (characters).
    private static let maxTextLength: Int = 2_000

    // MARK: - Dangerous Key Combinations

    /// Key codes that are blocked when combined with Cmd modifier.
    /// These can cause data loss, logout, or system-level actions.
    private static let dangerousCmdKeyCodes: Set<UInt16> = [
        12,   // Cmd+Q — Quit application
        13,   // Cmd+W — Close window
        46,   // Cmd+M — Minimise window
        51,   // Cmd+Delete — Move to Trash (in Finder)
    ]

    /// Key codes blocked with Cmd+Shift.
    private static let dangerousCmdShiftKeyCodes: Set<UInt16> = [
        51,   // Cmd+Shift+Delete — Empty Trash
    ]

    /// Key codes blocked with Cmd+Option.
    private static let dangerousCmdOptionKeyCodes: Set<UInt16> = [
        53,   // Cmd+Option+Esc — Force Quit dialog
    ]

    /// Key codes blocked with Ctrl+Cmd.
    private static let dangerousCtrlCmdKeyCodes: Set<UInt16> = [
        12,   // Ctrl+Cmd+Q — Lock Screen
    ]

    /// Key codes blocked with Control regardless of other modifiers.
    private static let dangerousControlKeyCodes: Set<UInt16> = [
        2,    // Ctrl+D — often interpreted as EOF/logout in terminal apps
        32    // Ctrl+U — line kill in terminal apps
    ]

    /// Maximum scroll delta per event to prevent scroll injection attacks.
    private static let maxScrollDelta: Double = 10_000

    /// Validate whether an incoming input command should be accepted for injection.
    ///
    /// - Parameters:
    ///   - commandSessionID: The session ID attached to the incoming command.
    ///   - activeSessionID: The currently active session on the host, if any.
    ///   - isRouterEnabled: Whether the input router is currently enabled.
    ///   - connectionState: The current WebRTC connection state.
    /// - Returns: `nil` if the command should be accepted, or a rejection reason.
    public static func validateRouting(
        commandSessionID: UUID,
        activeSessionID: UUID?,
        isRouterEnabled: Bool,
        connectionState: ConnectionState
    ) -> InputRouterRejection? {
        guard isRouterEnabled else {
            return .routerDisabled
        }
        guard let active = activeSessionID else {
            return .noActiveSession
        }
        guard commandSessionID == active else {
            return .sessionMismatch(expected: active, received: commandSessionID)
        }
        guard connectionState == .connected else {
            return .notConnected(connectionState)
        }
        return nil
    }

    /// Validate the content of an input command for sanity bounds.
    /// Returns `nil` if valid, or a rejection reason.
    public static func validateContent(_ command: InputCommand) -> InputRouterRejection? {
        switch command {
        case .pointerMove(let move):
            if !isReasonablePoint(move.location) {
                return .invalidContent("Pointer coordinates out of range")
            }
            // For a relative move the "location" is a per-event delta; a single
            // event should never teleport the cursor thousands of px. (Absolute
            // moves legitimately span the whole desktop, so only bound relatives.)
            if !move.isAbsolute,
               abs(move.location.x) > maxRelativeDelta || abs(move.location.y) > maxRelativeDelta {
                return .invalidContent("Relative pointer delta out of range")
            }
        case .pointerButton(let btn):
            if let loc = btn.location, !isReasonablePoint(loc) {
                return .invalidContent("Button coordinates out of range")
            }
        case .scroll(let scroll):
            if abs(scroll.deltaX) > maxScrollDelta || abs(scroll.deltaY) > maxScrollDelta {
                return .invalidContent("Scroll delta out of range")
            }
        case .text(let text):
            if text.text.isEmpty {
                return .invalidContent("Empty text input")
            }
            if text.text.count > maxTextLength {
                return .invalidContent("Text too long (\(text.text.count) chars)")
            }
            // Block control characters (except newline/tab) to prevent injection
            let controlRange = Unicode.Scalar(0)...Unicode.Scalar(8)
            let controlRange2 = Unicode.Scalar(14)...Unicode.Scalar(31)
            for scalar in text.text.unicodeScalars {
                // Allow only tab (9), newline (10), carriage return (13); block the rest of C0,
                // including vertical tab (11) and form feed (12).
                if controlRange.contains(scalar) || controlRange2.contains(scalar)
                    || scalar.value == 11 || scalar.value == 12 {
                    return .invalidContent("Text contains forbidden control characters")
                }
            }
        case .key(let key):
            if isDangerousKeyCombination(key) {
                return .invalidContent("Blocked dangerous key combination (keyCode=\(key.keyCode))")
            }
        }
        return nil
    }

    /// Check whether a key command is a dangerous system shortcut.
    private static func isDangerousKeyCombination(_ key: KeyCommand) -> Bool {
        let mods = key.modifiers

        // Cmd+<key>
        if mods.contains(.command) && !mods.contains(.shift) && !mods.contains(.option) && !mods.contains(.control) {
            if dangerousCmdKeyCodes.contains(key.keyCode) { return true }
        }

        // Cmd+Shift+<key>
        if mods.contains(.command) && mods.contains(.shift) && !mods.contains(.option) && !mods.contains(.control) {
            if dangerousCmdShiftKeyCodes.contains(key.keyCode) { return true }
        }

        // Cmd+Option+<key>
        if mods.contains(.command) && mods.contains(.option) && !mods.contains(.shift) && !mods.contains(.control) {
            if dangerousCmdOptionKeyCodes.contains(key.keyCode) { return true }
        }

        // Ctrl+Cmd+<key>
        if mods.contains(.command) && mods.contains(.control) {
            if dangerousCtrlCmdKeyCodes.contains(key.keyCode) { return true }
        }

        // Control+<key> destructive terminal shortcuts.
        if mods.contains(.control) && dangerousControlKeyCodes.contains(key.keyCode) {
            return true
        }

        return false
    }

    private static func isReasonablePoint(_ point: DesktopPoint) -> Bool {
        !point.x.isNaN && !point.x.isInfinite
            && !point.y.isNaN && !point.y.isInfinite
            && abs(point.x) <= maxCoordinate
            && abs(point.y) <= maxCoordinate
    }
}
