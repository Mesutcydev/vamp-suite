import AppKit
import SharedModels
import SharedUtilities

/// Receives arrows before SwiftUI can interpret them as local focus navigation.
/// Only the focused streaming view may consume events; local fields and sheets
/// continue to use AppKit's normal keyboard handling.
@MainActor
final class RemoteArrowKeyMonitor {
    private var monitor: Any?
    private var windowObserver: Any?
    private var pressed: [UInt16: NSEvent] = [:]
    private var send: ((NSEvent, KeyAction) -> Void)?

    func start(for view: NSView, isEnabled: @escaping () -> Bool,
               send: @escaping (NSEvent, KeyAction) -> Void) {
        stop()
        self.send = send
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak view] event in
            guard let self, let view, let window = view.window else { return event }
            return self.handle(event, ownsKeyboard: isEnabled()
                && window.isKeyWindow && event.window === window
                && window.firstResponder === view && window.attachedSheet == nil)
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: view.window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releasePressedKeys() }
        }
    }

    /// Returning nil prevents duplicate delivery through keyDown/keyUp.
    func handle(_ event: NSEvent, ownsKeyboard: Bool) -> NSEvent? {
        guard ownsKeyboard, (123...126).contains(event.keyCode),
              event.type == .keyDown || event.type == .keyUp else { return event }
        if event.type == .keyDown {
            pressed[event.keyCode] = event
            send?(event, .down)
        } else if pressed.removeValue(forKey: event.keyCode) != nil {
            send?(event, .up)
        } else {
            return event
        }
        return nil
    }

    func releasePressedKeys() {
        let events = pressed.values
        pressed.removeAll()
        for event in events { send?(event, .up) }
    }

    func stop() {
        releasePressedKeys()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        monitor = nil
        windowObserver = nil
        send = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }
}

/// AppKit no longer consistently promotes Control-primary click to a secondary
/// event. Keeping this mapping pure makes the behavior testable.
enum RemotePrimaryClickTranslation {
    static func button(controlPressed: Bool) -> MouseButton {
        controlPressed ? .right : .left
    }
}

/// Which ⌘-shortcuts Vamp Control keeps for itself instead of forwarding to the
/// host.
///
/// The rule is deliberately narrow and easy to state: **every shortcut this app
/// shows in its own menu bar works locally; everything else goes to the remote
/// Mac.** The previous predicate matched on the character alone and then bailed
/// out whenever Shift was held, so ⇧⌘D — the documented way to leave a session —
/// was forwarded to the host and never disconnected anything. ⌘0/⌘1/⌘2 in the
/// View menu were swallowed the same way.
///
/// Session actions that are *not* in a menu (screenshot, terminal, clipboard,
/// the app picker) deliberately use ⌃⌥ combinations instead of taking more ⌘
/// keys away from the remote Mac.
enum RemoteKeyEquivalentPolicy {
    private static let commandOnly: Set<String> = [
        "q", "m", "h", ",",  // application menu
        "r",                 // Session ▸ Refresh Hosts
        "0", "1", "2"        // View ▸ Fit Display / Fill Window / Actual Size
    ]
    private static let commandShift: Set<String> = [
        "d"                  // Session ▸ Disconnect from Host
    ]

    static func staysLocal(characters: String, modifiers: NSEvent.ModifierFlags,
                           keepsDisplayShortcutsLocal: Bool = true) -> Bool {
        guard modifiers.contains(.command) else { return false }
        // A ⌃ or ⌥ in the mix is never one of ours, so it belongs to the host.
        guard !modifiers.contains(.control), !modifiers.contains(.option) else { return false }
        let key = characters.lowercased()
        if !keepsDisplayShortcutsLocal, !modifiers.contains(.shift), ["0", "1", "2"].contains(key) { return false }
        return modifiers.contains(.shift) ? commandShift.contains(key) : commandOnly.contains(key)
    }
}

/// Connection readiness is independent of keyboard focus. Explicit toolbar
/// actions may send input while a local control is focused, but never while the
/// remote attachment or video is unavailable.
enum MacInputReadiness: Equatable {
    case reconnecting, locked, choosingApp, waitingForVideo, viewOnly, ready

    static func resolve(connected: Bool, locked: Bool, choosingApp: Bool,
                        receivingVideo: Bool, viewOnly: Bool) -> Self {
        if !connected { return .reconnecting }
        if locked { return .locked }
        if choosingApp { return .choosingApp }
        if !receivingVideo { return .waitingForVideo }
        return viewOnly ? .viewOnly : .ready
    }

    var canSendInput: Bool { self == .ready }

    var message: String {
        switch self {
        case .reconnecting: "Reconnecting — input paused"
        case .locked: "Mac locked — input paused"
        case .choosingApp: "Choose an app to control"
        case .waitingForVideo: "Waiting for video — input paused"
        case .viewOnly: "View only — mouse and keyboard are off"
        case .ready: "Click the stream to control"
        }
    }
}

/// Explicit presses for shortcuts macOS may consume before the app sees them.
enum MacRemoteShortcut: String, CaseIterable, Identifiable {
    case commandTab, commandSpace, escape, left, right, up, down
    case controlLeft, controlRight, controlUp, controlDown

    var id: String { rawValue }
    var title: String {
        switch self {
        case .commandTab: "Switch apps (⌘Tab)"
        case .commandSpace: "Spotlight (⌘Space)"
        case .escape: "Escape"
        case .left: "Left arrow ←"
        case .right: "Right arrow →"
        case .up: "Up arrow ↑"
        case .down: "Down arrow ↓"
        case .controlLeft: "Control-Left (⌃←)"
        case .controlRight: "Control-Right (⌃→)"
        case .controlUp: "Control-Up (⌃↑)"
        case .controlDown: "Control-Down (⌃↓)"
        }
    }
    var keyCode: UInt16 {
        switch self {
        case .commandTab: 48
        case .commandSpace: 49
        case .escape: 53
        case .left, .controlLeft: 123
        case .right, .controlRight: 124
        case .up, .controlUp: 126
        case .down, .controlDown: 125
        }
    }
    var modifiers: KeyboardModifierFlags {
        switch self {
        case .commandTab, .commandSpace: [.command]
        case .controlLeft, .controlRight, .controlUp, .controlDown: [.control]
        default: []
        }
    }
    var assistantKey: String {
        switch self {
        case .commandSpace: "space"
        default: MacAssistantKeyMapping.name(for: keyCode) ?? "escape"
        }
    }
    var assistantModifiers: [String] {
        if modifiers.contains(.command) { return ["command"] }
        if modifiers.contains(.control) { return ["control"] }
        return []
    }
}

/// Matches Assistant presentation to pointer mapping, including Retina 1:1.
enum MacRemoteContentLayout {
    static func rect(imageSize: CGSize, viewSize: CGSize, pixelScale: Double,
                     mode: DisplayMappingEngine.DisplayMode) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return nil }
        let scale: Double
        switch mode {
        case .actualSize: scale = 1 / max(1, pixelScale)
        case .fitDisplay: scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        case .fillScreen: scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        }
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
