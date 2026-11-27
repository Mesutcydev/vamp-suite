import Foundation
import GameController
import SharedModels

/// The pointer/keyboard surface a Bluetooth device drives.
///
/// Vamp Control (`RemoteInteractionViewModel`) and Vamp Stream
/// (`AppStreamInputController`) both implement this, so the same GCKeyboard/GCMouse
/// bridge serves either app. Stream previously had no Bluetooth mouse support at
/// all: a paired mouse moved the on-screen hover cursor but its buttons and scroll
/// wheel went nowhere, and there was no sensitivity control.
@MainActor
protocol RemotePointerInputSink: AnyObject {
    /// A mouse button changed state. Location is nil — the pointer is wherever it already is.
    func sendPointerButton(_ button: MouseButton, action: ButtonAction)
    /// Physical scroll wheel / trackpad scroll deltas.
    func sendScrollInput(deltaX: Double, deltaY: Double)
    /// A key changed state, with the modifiers currently held on the physical keyboard.
    func sendKey(keyCode: UInt16, action: KeyAction, modifiers: KeyboardModifierFlags)
}

/// Bridges connected Bluetooth keyboard and mouse to the remote session via
/// GCKeyboard / GCMouse (Apple's GameController framework HID layer).
/// Start / stop observation when a session becomes active / inactive.
@MainActor
final class BluetoothInputController: ObservableObject {

    // MARK: - Published state

    @Published private(set) var isKeyboardConnected = false
    @Published private(set) var isMouseConnected = false
    @Published private(set) var keyboardName: String = "None"
    @Published private(set) var mouseName: String = "None"
    @Published var mouseSensitivity: Double = 1.0   // 0.25 … 3.0
    @Published var scrollSensitivity: Double = 1.0  // 0.25 … 3.0
    @Published private(set) var activeModifiers: KeyboardModifierFlags = []

    // MARK: - Internals

    /// The session this device drives. Either client's input controller.
    weak var sink: (any RemotePointerInputSink)?
    private var notificationObservers: [NSObjectProtocol] = []
    private var isObserving = false

    // MARK: - Lifecycle

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        attachConnectedDevices()
        subscribeToConnectionEvents()
    }

    func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        detachKeyboard(GCKeyboard.coalesced)
        detachMouse(GCMouse.current)
    }

    // MARK: - Connection Events

    private func subscribeToConnectionEvents() {
        let nc = NotificationCenter.default

        notificationObservers.append(nc.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.attachKeyboard(note.object as? GCKeyboard)
            }
        })

        notificationObservers.append(nc.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isKeyboardConnected = false
                self.keyboardName = "None"
                self.activeModifiers = []
            }
        })

        notificationObservers.append(nc.addObserver(
            forName: .GCMouseDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.attachMouse(note.object as? GCMouse)
            }
        })

        notificationObservers.append(nc.addObserver(
            forName: .GCMouseDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isMouseConnected = false
                self.mouseName = "None"
            }
        })
    }

    private func attachConnectedDevices() {
        attachKeyboard(GCKeyboard.coalesced)
        attachMouse(GCMouse.current)
    }

    // MARK: - Keyboard

    private func attachKeyboard(_ keyboard: GCKeyboard?) {
        guard let keyboard else { return }
        isKeyboardConnected = true
        keyboardName = keyboard.vendorName ?? "Bluetooth Keyboard"

        keyboard.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            Task { @MainActor [weak self] in
                self?.handleKeyChange(keyCode, pressed: pressed)
            }
        }
    }

    private func detachKeyboard(_ keyboard: GCKeyboard?) {
        keyboard?.keyboardInput?.keyChangedHandler = nil
        isKeyboardConnected = false
        keyboardName = "None"
    }

    private func handleKeyChange(_ keyCode: GCKeyCode, pressed: Bool) {
        // Update modifier tracking
        if let mod = Self.gcModifierMap[keyCode] {
            if pressed { activeModifiers.insert(mod) }
            else { activeModifiers.remove(mod) }
            return  // modifiers don't generate key events on their own
        }

        guard let sink,
              let macCode = Self.gcToMacKeyCode[keyCode] else { return }

        sink.sendKey(keyCode: macCode, action: pressed ? .down : .up, modifiers: activeModifiers)
    }

    // MARK: - Mouse

    private func attachMouse(_ mouse: GCMouse?) {
        guard let mouse else { return }
        isMouseConnected = true
        mouseName = mouse.vendorName ?? "Bluetooth Mouse"

        // Mouse movement is handled by UIHoverGestureRecognizer in MirrorFullscreenGestureView,
        // which is more reliable on iOS than GCMouse.mouseMovedHandler.

        mouse.mouseInput?.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor [weak self] in
                self?.sink?.sendPointerButton(.left, action: pressed ? .down : .up)
            }
        }

        mouse.mouseInput?.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor [weak self] in
                self?.sink?.sendPointerButton(.right, action: pressed ? .down : .up)
            }
        }

        mouse.mouseInput?.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor [weak self] in
                self?.sink?.sendPointerButton(.middle, action: pressed ? .down : .up)
            }
        }

        mouse.mouseInput?.scroll.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor [weak self] in
                guard let self, let sink = self.sink else { return }
                let scale = self.scrollSensitivity
                sink.sendScrollInput(deltaX: Double(xValue) * scale,
                                     deltaY: Double(yValue) * scale)
            }
        }
    }

    private func detachMouse(_ mouse: GCMouse?) {
        mouse?.mouseInput?.mouseMovedHandler = nil
        mouse?.mouseInput?.leftButton.pressedChangedHandler = nil
        mouse?.mouseInput?.rightButton?.pressedChangedHandler = nil
        mouse?.mouseInput?.middleButton?.pressedChangedHandler = nil
        mouse?.mouseInput?.scroll.valueChangedHandler = nil
        isMouseConnected = false
        mouseName = "None"
    }

    // MARK: - Key Mapping

    private static let gcModifierMap: [GCKeyCode: KeyboardModifierFlags] = [
        .leftShift: .shift,     .rightShift: .shift,
        .leftAlt: .option,      .rightAlt: .option,
        .leftControl: .control, .rightControl: .control,
        .leftGUI: .command,     .rightGUI: .command,
    ]

    /// GCKeyCode → macOS CGKeyCode (Carbon virtual key codes)
    static let gcToMacKeyCode: [GCKeyCode: UInt16] = [
        // Letters
        .keyA: 0,  .keyB: 11, .keyC: 8,  .keyD: 2,  .keyE: 14,
        .keyF: 3,  .keyG: 5,  .keyH: 4,  .keyI: 34, .keyJ: 38,
        .keyK: 40, .keyL: 37, .keyM: 46, .keyN: 45, .keyO: 31,
        .keyP: 35, .keyQ: 12, .keyR: 15, .keyS: 1,  .keyT: 17,
        .keyU: 32, .keyV: 9,  .keyW: 13, .keyX: 7,  .keyY: 16,
        .keyZ: 6,
        // Numbers
        .one: 18, .two: 19, .three: 20, .four: 21, .five: 23,
        .six: 22, .seven: 26, .eight: 28, .nine: 25, .zero: 29,
        // Special
        .returnOrEnter: 36, .escape: 53, .deleteOrBackspace: 51,
        .spacebar: 49, .tab: 48,
        // Arrows
        .upArrow: 126, .downArrow: 125, .leftArrow: 123, .rightArrow: 124,
        // Function keys
        .F1: 122, .F2: 120, .F3: 99,  .F4: 118, .F5: 96,  .F6: 97,
        .F7: 98,  .F8: 100, .F9: 101, .F10: 109, .F11: 103, .F12: 111,
        // Punctuation / symbols
        .hyphen: 27, .equalSign: 24, .openBracket: 33, .closeBracket: 30,
        .backslash: 42, .semicolon: 41, .quote: 39,
        .graveAccentAndTilde: 50, .comma: 43, .period: 47, .slash: 44,
        // Navigation cluster
        .home: 115, .end: 119, .pageUp: 116, .pageDown: 121,
        .deleteForward: 117,
        // Numpad
        .keypad0: 82, .keypad1: 83, .keypad2: 84, .keypad3: 85,
        .keypad4: 86, .keypad5: 87, .keypad6: 88, .keypad7: 89,
        .keypad8: 91, .keypad9: 92,
        .keypadAsterisk: 67, .keypadPlus: 69, .keypadHyphen: 78,
        .keypadSlash: 75, .keypadEnter: 76, .keypadPeriod: 65,
        .keypadEqualSign: 81,
        // Extra
        .printScreen: 105, .scrollLock: 107, .pause: 113,
        .insert: 114, .application: 110,
        .F13: 105, .F14: 107, .F15: 113, .F16: 106, .F17: 64,
        .F18: 79,  .F19: 80,  .F20: 90,
    ]
}
