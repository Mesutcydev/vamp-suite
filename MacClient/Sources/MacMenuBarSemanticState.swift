import Foundation

enum MacMenuBarSemanticState: Equatable {
    case disconnected
    case connecting
    case connected
    case warning
}

/// Pure, independently testable equality gate used before any AppKit update.
struct MacMenuBarStateGate {
    private(set) var current: MacMenuBarSemanticState?
    private(set) var effectiveUpdateCount = 0

    mutating func accept(_ state: MacMenuBarSemanticState) -> Bool {
        guard state != current else { return false }
        current = state
        effectiveUpdateCount += 1
        return true
    }
}
