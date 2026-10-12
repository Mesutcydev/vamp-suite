import Foundation
import SharedModels

public protocol InputInjectionServiceProtocol {
    func inject(_ command: InputCommand) async throws
    func perform(_ shortcut: ShortcutCommand) async throws

    /// Release any held pointer button. Called when a session ends. Default no-op.
    func releaseHeldPointerButton()
    func releaseHeldKeys()
}

public extension InputInjectionServiceProtocol {
    func releaseHeldPointerButton() {}
    func releaseHeldKeys() {}
}
