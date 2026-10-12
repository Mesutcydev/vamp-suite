#if os(macOS)
import ApplicationServices
import Carbon
import Foundation
import SharedModels

/// A separate, paced physical-key path for the login window. Secure fields need a
/// real virtual key code, while the Unicode payload preserves the character selected
/// by the active keyboard layout.
@MainActor
public final class LoginWindowInputService {
    struct Key: Equatable {
        let code: UInt16
        var modifiers: KeyboardModifierFlags = []
        var unicodeString: String?

        init(code: UInt16, modifiers: KeyboardModifierFlags = [], unicodeString: String? = nil) {
            self.code = code
            self.modifiers = modifiers
            self.unicodeString = unicodeString
        }
    }

    private let isLocked: () -> Bool
    private let hasAccessibility: () -> Bool
    private let resolveKeys: (String) throws -> [Key]
    private let postKey: (Key, KeyAction) throws -> Void
    private let sleep: (Duration) async throws -> Void
    private var isSubmitting = false

    public convenience init() {
        // loginwindow belongs to the console's HID state, rather than the host's
        // private desktop input state. Every event still has explicit modifiers.
        let bridge = CGEventInputBridge(sourceState: .hidSystemState)
        self.init(
            isLocked: {
                let session = CGSessionCopyCurrentDictionary() as? [String: Any]
                return session?["CGSSessionScreenIsLocked"] as? Bool == true
            },
            hasAccessibility: { AXIsProcessTrusted() },
            resolveKeys: Self.keysForCurrentLayout,
            postKey: { key, action in
                try bridge.postKeyEvent(
                    keyCode: key.code,
                    action: action,
                    modifiers: key.modifiers,
                    unicodeString: key.unicodeString
                )
            },
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    init(
        isLocked: @escaping () -> Bool,
        hasAccessibility: @escaping () -> Bool,
        resolveKeys: @escaping (String) throws -> [Key],
        postKey: @escaping (Key, KeyAction) throws -> Void,
        sleep: @escaping (Duration) async throws -> Void
    ) {
        self.isLocked = isLocked
        self.hasAccessibility = hasAccessibility
        self.resolveKeys = resolveKeys
        self.postKey = postKey
        self.sleep = sleep
    }

    public func submit(password: String) async throws {
        guard !isSubmitting else {
            throw InputInjectionError.platformBridgeFailed("An unlock attempt is already in progress")
        }
        isSubmitting = true
        defer { isSubmitting = false }
        try checkCanType()
        guard !password.isEmpty, password.count <= 256,
              !password.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw InputInjectionError.invalidCommand("Unsupported login password input")
        }
        // Resolve the entire input before posting anything. Never fall back to a
        // different character or log the character that could not be represented.
        let keys = try resolveKeys(password)
        guard var selectAll = try resolveKeys("a").first else {
            throw InputInjectionError.platformBridgeFailed("Mac keyboard layout is unavailable")
        }
        selectAll.modifiers.insert(.command)
        // Cmd+A is a shortcut, not text input. Do not attach the mapped character
        // to it or loginwindow may treat the Unicode payload as an inserted "a".
        selectAll.unicodeString = nil

        // Space wakes/reveals the login form. If it lands in the field, the clear
        // below removes it along with any partial entry from a previous attempt.
        try await stroke(Key(code: 49))
        try await sleep(.milliseconds(750))
        try await stroke(selectAll)
        try await stroke(Key(code: 51))
        try await sleep(.milliseconds(100))
        for key in keys {
            try await stroke(key)
            try await sleep(.milliseconds(25))
        }
        try await sleep(.milliseconds(100))
        try await stroke(Key(code: 36))
    }

    private func checkCanType() throws {
        try Task.checkCancellation()
        guard hasAccessibility() else { throw InputInjectionError.accessibilityNotGranted }
        guard isLocked() else {
            throw InputInjectionError.platformBridgeFailed("Mac is no longer locked; password entry stopped")
        }
    }

    private func stroke(_ key: Key) async throws {
        // Recheck after every suspension so a local unlock stops the remaining
        // password from being typed into the newly active desktop application.
        try checkCanType()
        try postKey(key, .down)
        do {
            try await sleep(.milliseconds(20))
        } catch {
            try? postKey(key, .up)
            throw error
        }
        // Always balance the key-down, including when the lock state changes.
        try postKey(key, .up)
    }

    static func keysForCurrentLayout(_ text: String) throws -> [Key] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw InputInjectionError.platformBridgeFailed("Mac keyboard layout is unavailable")
        }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
        return try keys(text, layoutData: data)
    }

    static func keys(_ text: String, layoutData data: CFData) throws -> [Key] {
        guard let bytes = CFDataGetBytePtr(data) else {
            throw InputInjectionError.platformBridgeFailed("Mac keyboard layout is unavailable")
        }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let modifiers: [(UInt32, KeyboardModifierFlags)] = [
            (0, []), (UInt32(shiftKey >> 8), .shift),
            (UInt32(optionKey >> 8), .option),
            (UInt32((shiftKey | optionKey) >> 8), [.shift, .option])
        ]
        var mapping: [String: Key] = [:]
        for (carbonFlags, flags) in modifiers {
            for code: UInt16 in 0..<128 {
                var deadKeyState: UInt32 = 0
                var count = 0
                var units = [UniChar](repeating: 0, count: 8)
                let result = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), carbonFlags,
                    UInt32(LMGetKbdType()), 0, &deadKeyState,
                    units.count, &count, &units
                )
                guard result == noErr, deadKeyState == 0, count > 0 else { continue }
                let character = String(utf16CodeUnits: units, count: count)
                if mapping[character] == nil {
                    mapping[character] = Key(code: code, modifiers: flags, unicodeString: character)
                }
            }
        }
        return try text.map { character in
            guard let key = mapping[String(character)] else {
                throw InputInjectionError.invalidCommand("Password cannot be typed with the Mac's current keyboard layout")
            }
            return key
        }
    }
}
#endif
