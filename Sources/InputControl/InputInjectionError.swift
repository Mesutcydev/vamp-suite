import Foundation
import SharedModels

// MARK: - Input Injection Errors

public enum InputInjectionError: Error, LocalizedError, Sendable, Equatable {
    case accessibilityNotGranted
    case displayNotFound(String)
    case coordinateOutOfBounds(displayID: String)
    case platformBridgeFailed(String)
    case invalidCommand(String)
    case sessionNotActive
    /// The host Mac is at the lock screen or login window.
    /// macOS does not allow remote input injection in this state.
    /// No bypass is attempted — the client is notified to show a "Mac is locked" message.
    case lockedOrLoginWindow

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission not granted. Input injection requires the Accessibility privilege."
        case .displayNotFound(let id):
            return "Display not found: \(id)"
        case .coordinateOutOfBounds(let displayID):
            return "Coordinate out of bounds for display \(displayID)."
        case .platformBridgeFailed(let reason):
            return "Platform input bridge failed: \(reason)"
        case .invalidCommand(let reason):
            return "Invalid input command: \(reason)"
        case .sessionNotActive:
            return "No active session for input injection."
        case .lockedOrLoginWindow:
            return "Remote input is unavailable while the Mac is locked. Unlock locally to resume control."
        }
    }
}
