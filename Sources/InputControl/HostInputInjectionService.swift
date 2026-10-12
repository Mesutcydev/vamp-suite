import Foundation
import SharedModels
import os

/// Host-side input injection service that validates accessibility permission,
/// translates coordinates using the display layout, and dispatches commands
/// through the platform input bridge.
///
/// Does **not** validate session state — that responsibility belongs to
/// the `HostInputCommandRouter` in the HostApp layer.
public final class HostInputInjectionService: InputInjectionServiceProtocol, @unchecked Sendable {
    private let bridge: any PlatformInputBridge
    private let accessibilityChecker: () -> Bool
    private let layoutProvider: () async throws -> DisplayLayout
    private let logger = Logger(subsystem: "com.remotedesktop.input", category: "InjectionService")

    public init(
        bridge: any PlatformInputBridge,
        accessibilityChecker: @escaping () -> Bool,
        layoutProvider: @escaping () async throws -> DisplayLayout
    ) {
        self.bridge = bridge
        self.accessibilityChecker = accessibilityChecker
        self.layoutProvider = layoutProvider
    }

    // MARK: - InputInjectionServiceProtocol

    public func inject(_ command: InputCommand) async throws {
        try Task.checkCancellation()
        guard accessibilityChecker() else {
            logger.warning("Input rejected: accessibility not granted")
            throw InputInjectionError.accessibilityNotGranted
        }

        // Text and key events carry no screen coordinates, so they don't need the display
        // layout. Skipping it matters at the login window: the layout query can throw or stall
        // there, and that must not abort a remote-unlock password keystroke. Inject directly —
        // translateToGlobal passes .text/.key through unchanged anyway.
        switch command {
        case .text, .key:
            try executeCommand(command)
            return
        default:
            break
        }

        let layout = try await layoutProvider()
        try Task.checkCancellation()

        switch InputCoordinateTranslator.translateToGlobal(command, layout: layout) {
        case .success(let translated):
            try executeCommand(translated)
        case .failure(let error):
            logger.warning("Coordinate translation failed: \(error.localizedDescription)")
            throw error
        }
    }

    public func releaseHeldKeys() { bridge.releaseHeldKeys() }

    public func releaseHeldPointerButton() {
        bridge.releaseHeldPointerButton()
    }

    public func perform(_ shortcut: ShortcutCommand) async throws {
        guard accessibilityChecker() else {
            logger.warning("Shortcut rejected: accessibility not granted")
            throw InputInjectionError.accessibilityNotGranted
        }

        let (keyCode, baseModifiers) = shortcutKeyMapping(shortcut.action)
        let combinedModifiers = KeyboardModifierFlags(
            rawValue: baseModifiers.rawValue | shortcut.modifiers.rawValue
        )

        try bridge.postKeyEvent(keyCode: keyCode, action: .down, modifiers: combinedModifiers)
        try bridge.postKeyEvent(keyCode: keyCode, action: .up, modifiers: combinedModifiers)
    }

    // MARK: - Command Execution

    private func executeCommand(_ command: InputCommand) throws {
        switch command {
        case .pointerMove(let move):
            if move.isAbsolute {
                try bridge.postMouseMove(to: move.location)
            } else {
                try bridge.postMouseMoveRelative(deltaX: move.location.x, deltaY: move.location.y)
            }

        case .pointerButton(let btn):
            try bridge.postMouseButton(btn.button, action: btn.action, at: btn.location)

        case .scroll(let scroll):
            try bridge.postScroll(deltaX: scroll.deltaX, deltaY: scroll.deltaY, isPrecise: scroll.isPrecise)

        case .key(let key):
            try bridge.postKeyEvent(keyCode: key.keyCode, action: key.action, modifiers: key.modifiers)

        case .text(let text):
            guard !text.text.isEmpty else {
                throw InputInjectionError.invalidCommand("Empty text input")
            }
            try bridge.postTextInput(text.text)
        }
    }

    // MARK: - Shortcut Key Mapping

    /// Maps a `ShortcutAction` to a virtual key code and base modifier flags.
    /// Virtual key codes follow the macOS ANSI keyboard layout.
    private func shortcutKeyMapping(_ action: ShortcutAction) -> (keyCode: UInt16, modifiers: KeyboardModifierFlags) {
        switch action {
        case .copy:        return (8,   .command)                 // Cmd+C
        case .paste:       return (9,   .command)                 // Cmd+V
        case .cut:         return (7,   .command)                 // Cmd+X
        case .undo:        return (6,   .command)                 // Cmd+Z
        case .redo:        return (6,   [.command, .shift])       // Cmd+Shift+Z
        case .spotlight:   return (49,  .command)                 // Cmd+Space
        case .appSwitcher: return (48,  .command)                 // Cmd+Tab
        case .showDesktop: return (103, [])                       // F11
        case .lockScreen:  return (12,  [.command, .control])     // Cmd+Ctrl+Q
        }
    }
}
