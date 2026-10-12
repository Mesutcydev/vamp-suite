import Foundation

public enum MouseButton: String, Codable, Hashable, Sendable {
    case left
    case right
    case middle
}

public enum ButtonAction: String, Codable, Hashable, Sendable {
    case down
    case up
    case click
    case doubleClick
}

public enum KeyAction: String, Codable, Hashable, Sendable {
    case down
    case up
}

public struct KeyboardModifierFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public static let command = KeyboardModifierFlags(rawValue: 1 << 0)
    public static let shift = KeyboardModifierFlags(rawValue: 1 << 1)
    public static let option = KeyboardModifierFlags(rawValue: 1 << 2)
    public static let control = KeyboardModifierFlags(rawValue: 1 << 3)
    public static let function = KeyboardModifierFlags(rawValue: 1 << 4)

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

public enum InputCommand: Codable, Hashable, Sendable {
    case pointerMove(PointerMoveCommand)
    case pointerButton(PointerButtonCommand)
    case scroll(ScrollCommand)
    case key(KeyCommand)
    case text(TextInputCommand)
}

public struct PointerMoveCommand: Codable, Hashable, Sendable {
    public var location: DesktopPoint
    public var displayID: String
    public var isAbsolute: Bool

    public init(location: DesktopPoint, displayID: String, isAbsolute: Bool = true) {
        self.location = location
        self.displayID = displayID
        self.isAbsolute = isAbsolute
    }
}

public struct PointerButtonCommand: Codable, Hashable, Sendable {
    public var button: MouseButton
    public var action: ButtonAction
    public var location: DesktopPoint?
    public var displayID: String?

    public init(button: MouseButton, action: ButtonAction, location: DesktopPoint? = nil, displayID: String? = nil) {
        self.button = button
        self.action = action
        self.location = location
        self.displayID = displayID
    }
}

public struct ScrollCommand: Codable, Hashable, Sendable {
    public var deltaX: Double
    public var deltaY: Double
    public var isPrecise: Bool

    public init(deltaX: Double, deltaY: Double, isPrecise: Bool = true) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.isPrecise = isPrecise
    }
}

public struct KeyCommand: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var action: KeyAction
    public var modifiers: KeyboardModifierFlags

    public init(keyCode: UInt16, action: KeyAction, modifiers: KeyboardModifierFlags = []) {
        self.keyCode = keyCode
        self.action = action
        self.modifiers = modifiers
    }
}

public struct TextInputCommand: Codable, Hashable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public enum ShortcutAction: String, Codable, Hashable, Sendable {
    case copy
    case paste
    case cut
    case undo
    case redo
    case spotlight
    case appSwitcher
    case showDesktop
    case lockScreen
}

public struct ShortcutCommand: Codable, Hashable, Sendable {
    public var action: ShortcutAction
    public var modifiers: KeyboardModifierFlags

    public init(action: ShortcutAction, modifiers: KeyboardModifierFlags = []) {
        self.action = action
        self.modifiers = modifiers
    }
}
