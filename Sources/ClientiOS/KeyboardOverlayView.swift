import SwiftUI
import SharedModels
import SharedUtilities
#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

struct KeyboardOverlayView: View {
    @ObservedObject var interactionVM: RemoteInteractionViewModel
    let onDismiss: () -> Void
    var onVoiceInput: (() -> Void)? = nil

    @State private var textInput: String = ""
    @State private var activeModifiers: KeyboardModifierFlags = []
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            header
            composer
            quickActions
            shortcutRow
            modifierRow
            keyRow
            helper
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(PR.card.opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(PR.borderHi, lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .onDisappear {
            isTextFieldFocused = false
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(PR.borderHi)
                .frame(width: 28, height: 4)

            Text("keyboard")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.fg)

            Spacer()

            headerChip("focus") {
                refocusTextField()
            }
            headerChip("hide kb") {
                dismissSystemKeyboard()
            }

            Button {
                dismissSystemKeyboard()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(PR.fg)
                    .frame(width: 28, height: 28)
                    .background(PR.bg2, in: Circle())
                    .overlay(Circle().strokeBorder(PR.border))
            }
            .buttonStyle(.plain)
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("type and send", text: $textInput)
                .font(.system(size: 15, weight: .regular, design: .monospaced))
                .focused($isTextFieldFocused)
                .submitLabel(.send)
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
                .autocorrectionDisabled()
                .onSubmit {
                    sendText()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(PR.cardHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(PR.border, lineWidth: 0.8)
                )

            Button {
                sendText()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(textInput.isEmpty ? PR.dim : PR.bg)
                    .frame(width: 40, height: 40)
                    .background(textInput.isEmpty ? PR.bg2 : PR.accent, in: Circle())
                    .overlay(Circle().strokeBorder(textInput.isEmpty ? PR.border : PR.accent.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .disabled(textInput.isEmpty)
        }
    }

    private var quickActions: some View {
        HStack(spacing: 7) {
            rowButton("paste", icon: "doc.on.clipboard") { pasteClipboard() }
            rowButton("backspace", icon: "delete.left") { tapSpecialKey(51) }
            rowButton("return", icon: "return") { tapSpecialKey(36) }
            rowButton("space", icon: "space") { interactionVM.sendText(" ") }
            if onVoiceInput != nil {
                voiceMicButton
            }
        }
    }

    private var voiceMicButton: some View {
        Button {
            dismissSystemKeyboard()
            onVoiceInput?()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(PR.bg)
                .frame(width: 40, height: 36)
                .background(PR.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PR.accent.opacity(0.45)))
        }
        .buttonStyle(.plain)
    }

    private var shortcutRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                shortcutChip("⌘C copy") { tapCombo(8, [.command]) }
                shortcutChip("⌘V paste") { tapCombo(9, [.command]) }
                shortcutChip("⌘A all") { tapCombo(0, [.command]) }
                shortcutChip("⌘Z undo") { tapCombo(6, [.command]) }
                shortcutChip("⌘⇧3 shot") { tapCombo(20, [.command, .shift]) }
                shortcutChip("⌘⇧4 area") { tapCombo(21, [.command, .shift]) }
                shortcutChip("⌘␣ spotlight") { tapCombo(49, [.command]) }
                shortcutChip("⌘⇥ switch") { tapCombo(48, [.command]) }
            }
        }
    }

    private func shortcutChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.fg)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(PR.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PR.border))
        }
        .buttonStyle(.plain)
    }

    /// Sends a complete key press with explicit modifiers (down+up), independent
    /// of the latched modifier row.
    private func tapCombo(_ keyCode: UInt16, _ modifiers: KeyboardModifierFlags) {
        interactionVM.sendKey(keyCode: keyCode, action: .down, modifiers: modifiers)
        interactionVM.sendKey(keyCode: keyCode, action: .up, modifiers: modifiers)
    }

    private var modifierRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                modifierKey("cmd", flag: .command)
                modifierKey("shift", flag: .shift)
                modifierKey("opt", flag: .option)
                modifierKey("ctrl", flag: .control)
                modifierKey("fn", flag: .function)
            }
        }
    }

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                keyButton("esc", keyCode: 53)
                keyButton("tab", keyCode: 48)
                keyButton("del", keyCode: 51)
                keyButton("<-", keyCode: 123)
                keyButton("->", keyCode: 124)
                keyButton("up", keyCode: 126)
                keyButton("down", keyCode: 125)
                keyButton("f1", keyCode: 122)
                keyButton("f2", keyCode: 120)
                keyButton("f3", keyCode: 99)
                keyButton("f4", keyCode: 118)
            }
        }
    }

    private var helper: some View {
        Text("modifiers apply to the next key, then release · cmd + typed letter sends the combo")
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundColor(PR.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headerChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.fg2)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(PR.bg2, in: Capsule())
                .overlay(Capsule().strokeBorder(PR.border))
        }
        .buttonStyle(.plain)
    }

    private func rowButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.fg2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(PR.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PR.border))
        }
        .buttonStyle(.plain)
    }

    private func modifierKey(_ title: String, flag: KeyboardModifierFlags) -> some View {
        let isActive = activeModifiers.contains(flag)

        return Button {
            if isActive {
                activeModifiers.remove(flag)
            } else {
                activeModifiers.insert(flag)
            }
            refocusTextField()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(isActive ? PR.bg : PR.fg2)
                .frame(minWidth: 52)
                .padding(.vertical, 9)
                .background(isActive ? PR.accent : PR.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isActive ? PR.accent.opacity(0.45) : PR.border)
                )
        }
        .buttonStyle(.plain)
    }

    private func keyButton(_ title: String, keyCode: UInt16) -> some View {
        Button {
            tapSpecialKey(keyCode)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.fg)
                .frame(minWidth: 46)
                .padding(.vertical, 9)
                .background(PR.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PR.border))
        }
        .buttonStyle(.plain)
    }

    private func sendText() {
        let payload = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return }
        // With modifiers latched, a single typed character becomes a key combo
        // (cmd + "c" → ⌘C) instead of literal text — like a hardware keyboard.
        if !activeModifiers.isEmpty,
           payload.count == 1,
           let character = payload.lowercased().first,
           let keyCode = Self.characterKeyCodes[character] {
            tapSpecialKey(keyCode)
            textInput = ""
            return
        }
        interactionVM.sendText(payload)
        textInput = ""
        refocusTextField()
    }

    private func tapSpecialKey(_ keyCode: UInt16) {
        interactionVM.sendKey(
            keyCode: keyCode,
            action: .down,
            modifiers: activeModifiers
        )
        interactionVM.sendKey(
            keyCode: keyCode,
            action: .up,
            modifiers: activeModifiers
        )
        // One-shot modifiers (industry standard on mobile remotes): the latched
        // modifiers apply to the next key only, then release automatically.
        activeModifiers = []
        refocusTextField()
    }

    /// ANSI virtual key codes for characters, so modifier combos can be typed
    /// from the composer (cmd + "t" → ⌘T).
    private static let characterKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47
    ]

    private func refocusTextField() {
        DispatchQueue.main.async {
            isTextFieldFocused = true
        }
    }

    private func dismissSystemKeyboard() {
        isTextFieldFocused = false
        #if canImport(UIKit) && !os(macOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func pasteClipboard() {
        #if canImport(UIKit) && !os(macOS)
        if let clipboardText = UIPasteboard.general.string, !clipboardText.isEmpty {
            interactionVM.sendText(clipboardText)
        }
        #endif
        refocusTextField()
    }
}
