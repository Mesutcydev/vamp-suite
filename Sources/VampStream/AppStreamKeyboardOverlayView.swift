import SwiftUI
import SharedModels
import SharedUtilities

#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

/// A real keyboard control deck for Vamp Stream. The text field owns the system
/// keyboard while the explicit rows cover Mac keys and one-shot modifiers that
/// cannot be represented reliably by a hidden UITextField.
struct AppStreamKeyboardOverlayView: View {
    enum Mode {
        case standard
        case terminal
    }

    var mode: Mode = .standard
    let onText: (String) -> Void
    let onKey: (UInt16, KeyboardModifierFlags) -> Void
    let onDismiss: () -> Void

    @State private var textInput = ""
    @State private var activeModifiers: KeyboardModifierFlags = []
    @FocusState private var isTextFieldFocused: Bool

    @ViewBuilder var body: some View {
        if mode == .terminal {
            TerminalAppStreamKeyboardDeck(
                onText: onText,
                onKey: onKey,
                onDismiss: onDismiss)
        } else {
            standardDeck
        }
    }

    /// The deck sits directly above the system keyboard, so it has to fit in what is left of the
    /// screen rather than push itself off it. The composer and header keep a stable identity —
    /// they must not be torn down and rebuilt, or the field would lose first responder and the
    /// keyboard would drop out mid-sentence — while the optional rows below them degrade through
    /// `ViewThatFits`: everything, then just the rows people actually type with, then the keys.
    private var standardDeck: some View {
        VStack(spacing: AppSpacing.xs) {
            header
            composer

            ViewThatFits(in: .vertical) {
                VStack(spacing: AppSpacing.xs) {
                    quickActions
                    shortcutRow
                    modifierRow
                    keyRow
                    helper
                }
                VStack(spacing: AppSpacing.xs) {
                    quickActions
                    modifierRow
                    keyRow
                }
                VStack(spacing: AppSpacing.xs) {
                    modifierRow
                    keyRow
                }
                keyRow
            }
        }
        .padding(.horizontal, AppSpacing.xs)
        .padding(.top, AppSpacing.xs)
        .padding(.bottom, AppSpacing.xs)
        .background(
            PR.card.opacity(0.96),
            in: RoundedRectangle(cornerRadius: PR.rCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PR.rCard, style: .continuous)
                .strokeBorder(PR.borderHi, lineWidth: 1)
        )
        .padding(.horizontal, AppSpacing.xs)
        .padding(.bottom, AppSpacing.xs)
        .onAppear { refocusTextField() }
        .onDisappear { isTextFieldFocused = false }
    }

    private var header: some View {
        HStack(spacing: AppSpacing.xs) {
            Capsule()
                .fill(PR.borderHi)
                .frame(width: 28, height: 4)
                .accessibilityHidden(true)

            Text("Keyboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PR.fg)

            Spacer()

            headerChip("Focus") { refocusTextField() }
            headerChip("Hide") { dismissSystemKeyboard() }

            Button {
                dismissSystemKeyboard()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(PR.fg)
                    .frame(width: 30, height: 30)
                    .background(PR.bg2, in: Circle())
                    .overlay(Circle().strokeBorder(PR.border))
                    .frame(
                        width: AppHostMetrics.iconControlTarget,
                        height: AppHostMetrics.iconControlTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close keyboard")
        }
    }

    private var composer: some View {
        HStack(spacing: AppSpacing.xs) {
            TextField("Type to send to your Mac", text: $textInput)
                .font(.body)
                .focused($isTextFieldFocused)
                .submitLabel(.send)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { sendText() }
                .padding(.horizontal, AppSpacing.sm)
                .frame(minHeight: AppHostMetrics.iconControlTarget)
                .background(
                    PR.cardHi,
                    in: RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous)
                        .strokeBorder(PR.border, lineWidth: 0.8)
                )

            Button { sendText() } label: {
                Image(systemName: "paperplane.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(textInput.isEmpty ? PR.dim : PR.bg)
                    .frame(
                        width: AppHostMetrics.iconControlTarget,
                        height: AppHostMetrics.iconControlTarget)
                    .background(textInput.isEmpty ? PR.bg2 : PR.accent, in: Circle())
                    .overlay(Circle().strokeBorder(textInput.isEmpty ? PR.border : PR.accent.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .disabled(textInput.isEmpty)
            .accessibilityLabel("Send text to Mac")
        }
    }

    private var quickActions: some View {
        HStack(spacing: AppSpacing.xxs) {
            rowButton("Paste", icon: "doc.on.clipboard") { pasteClipboard() }
            rowButton("Delete", icon: "delete.left") { tapSpecialKey(51) }
            rowButton("Return", icon: "return") { tapSpecialKey(36) }
            rowButton("Space", icon: "space") { onText(" ") }
        }
    }

    private var shortcutRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.xxs) {
                shortcutChip("⌘C", "Copy") { tapCombo(8, [.command]) }
                shortcutChip("⌘V", "Paste") { tapCombo(9, [.command]) }
                shortcutChip("⌘A", "Select all") { tapCombo(0, [.command]) }
                shortcutChip("⌘Z", "Undo") { tapCombo(6, [.command]) }
                shortcutChip("⌘⇧3", "Screenshot") { tapCombo(20, [.command, .shift]) }
                shortcutChip("⌘⇧4", "Capture area") { tapCombo(21, [.command, .shift]) }
                shortcutChip("⌘␣", "Spotlight") { tapCombo(49, [.command]) }
                shortcutChip("⌘⇥", "Switch app") { tapCombo(48, [.command]) }
            }
            .padding(.horizontal, 1)
        }
    }

    private var modifierRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.xxs) {
                // The Mac's own glyphs, not abbreviations: this is the vocabulary the keys
                // are printed with. VoiceOver gets the spoken name instead.
                modifierKey("⌘", name: "Command", flag: .command)
                modifierKey("⇧", name: "Shift", flag: .shift)
                modifierKey("⌥", name: "Option", flag: .option)
                modifierKey("⌃", name: "Control", flag: .control)
                modifierKey("fn", name: "Function", flag: .function)
            }
            .padding(.horizontal, 1)
        }
    }

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.xxs) {
                keyButton("esc", name: "Escape", keyCode: 53)
                keyButton("⇥", name: "Tab", keyCode: 48)
                keyButton("⌫", name: "Delete", keyCode: 51)
                keyButton("←", name: "Left arrow", keyCode: 123)
                keyButton("→", name: "Right arrow", keyCode: 124)
                keyButton("↑", name: "Up arrow", keyCode: 126)
                keyButton("↓", name: "Down arrow", keyCode: 125)
                keyButton("F1", name: "F1", keyCode: 122)
                keyButton("F2", name: "F2", keyCode: 120)
                keyButton("F3", name: "F3", keyCode: 99)
                keyButton("F4", name: "F4", keyCode: 118)
            }
            .padding(.horizontal, 1)
        }
    }

    private var helper: some View {
        Text("A modifier applies to the next key, then releases. Hold one and type a letter to send the combo.")
            .font(.caption2)
            .foregroundStyle(PR.dim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headerChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PR.fg2)
                .padding(.horizontal, AppSpacing.sm)
                .frame(minHeight: AppHostMetrics.iconControlTarget)
                .background(PR.bg2, in: Capsule())
                .overlay(Capsule().strokeBorder(PR.border))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func rowButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(PR.fg2)
                .frame(maxWidth: .infinity)
                .frame(minHeight: AppHostMetrics.iconControlTarget)
                .background(
                    PR.bg2,
                    in: RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous)
                        .strokeBorder(PR.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `glyph` is the key combination as printed on a Mac keyboard; `name` is what it does.
    /// Both are shown — the old chips ran them together ("⌘⇧3 shot") which read as neither.
    private func shortcutChip(_ glyph: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.xxs) {
                Text(glyph)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PR.fg)
                Text(name)
                    .font(.caption)
                    .foregroundStyle(PR.fg2)
            }
            .lineLimit(1)
            .padding(.horizontal, AppSpacing.sm)
            .frame(minHeight: AppHostMetrics.iconControlTarget)
            .background(
                PR.bg2,
                in: RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous)
                    .strokeBorder(PR.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(glyph)")
    }

    private func modifierKey(_ glyph: String, name: String, flag: KeyboardModifierFlags) -> some View {
        let isActive = activeModifiers.contains(flag)
        return Button {
            if isActive { activeModifiers.remove(flag) } else { activeModifiers.insert(flag) }
            refocusTextField()
        } label: {
            Text(glyph)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(isActive ? PR.bg : PR.fg2)
                .frame(minWidth: 54)
                .frame(minHeight: AppHostMetrics.iconControlTarget)
                .background(
                    isActive ? PR.accent : PR.bg2,
                    in: RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous)
                        .strokeBorder(isActive ? PR.accent.opacity(0.45) : PR.border)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(isActive ? "On, applies to the next key" : "Off")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private func keyButton(_ glyph: String, name: String, keyCode: UInt16) -> some View {
        Button { tapSpecialKey(keyCode) } label: {
            Text(glyph)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PR.fg)
                .frame(minWidth: 48)
                .frame(minHeight: AppHostMetrics.iconControlTarget)
                .background(
                    PR.bg2,
                    in: RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous)
                        .strokeBorder(PR.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    private func sendText() {
        guard !textInput.isEmpty else { return }
        if !activeModifiers.isEmpty,
           textInput.count == 1,
           let character = textInput.lowercased().first,
           let keyCode = Self.characterKeyCodes[character] {
            tapSpecialKey(keyCode)
            textInput = ""
            return
        }
        onText(textInput)
        textInput = ""
        refocusTextField()
    }

    private func tapCombo(_ keyCode: UInt16, _ modifiers: KeyboardModifierFlags) {
        onKey(keyCode, modifiers)
        refocusTextField()
    }

    private func tapSpecialKey(_ keyCode: UInt16) {
        onKey(keyCode, activeModifiers)
        activeModifiers = []
        refocusTextField()
    }

    private static let characterKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47
    ]

    /// Reverse of `characterKeyCodes`. Vamp Assistant's input protocol names keys rather than
    /// numbering them, so a shortcut like ⌃C has to travel as "c"; a raw keycode means nothing
    /// to it and the shortcut is dropped.
    static func character(forKeyCode keyCode: UInt16) -> String? {
        characterKeyCodes.first { $0.value == keyCode }.map { String($0.key) }
    }

    private func refocusTextField() {
        DispatchQueue.main.async { isTextFieldFocused = true }
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
            onText(clipboardText)
        }
#endif
        refocusTextField()
    }
}

/// A compact command deck for streamed terminal apps. Text submission is deliberately a
/// two-step wire operation (type, then Return), while auxiliary keys remain discrete Mac key
/// presses so shells, TUIs, editors, and multiplexers receive their native control sequences.
private struct TerminalAppStreamKeyboardDeck: View {
    let onText: (String) -> Void
    let onKey: (UInt16, KeyboardModifierFlags) -> Void
    let onDismiss: () -> Void

    @State private var command = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.xs) {
                // Monospace is kept here on purpose: this deck drives a terminal, and the
                // glyphs it sends are terminal glyphs. The prose beside it is not.
                Text("terminal")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(PR.fg)
                Text("Type a command, or use the keys")
                    .font(.caption2)
                    .foregroundStyle(PR.dim)
                    .lineLimit(1)
                Spacer()
                Button {
                    isFocused = false
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .background(PR.bg2, in: Circle())
                        .frame(
                            width: AppHostMetrics.iconControlTarget,
                            height: AppHostMetrics.iconControlTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close terminal controls")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.xxs) {
                    auxKey("esc", 53, hint: "Escape")
                    auxKey("⇥", 48, hint: "Tab")
                    auxKey("⌃C", 8, [.control], hint: "Interrupt")
                    auxKey("⌃L", 37, [.control], hint: "Clear terminal")
                    auxKey("←", 123, hint: "Left arrow")
                    auxKey("↑", 126, hint: "Up arrow")
                    auxKey("↓", 125, hint: "Down arrow")
                    auxKey("→", 124, hint: "Right arrow")
                    auxKey("home", 115, hint: "Home")
                    auxKey("end", 119, hint: "End")
                    auxKey("pg↑", 116, hint: "Page up")
                    auxKey("pg↓", 121, hint: "Page down")
                }
                .padding(.horizontal, 1)
            }

            HStack(spacing: AppSpacing.xxs) {
                Button(action: pasteIntoCommand) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.subheadline)
                        .frame(
                            width: AppHostMetrics.iconControlTarget,
                            height: AppHostMetrics.iconControlTarget)
                        .background(
                            PR.bg2,
                            in: RoundedRectangle(
                                cornerRadius: AppHostMetrics.chipRadius, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste into command")

                TextField("command", text: $command)
                    .font(.system(.body, design: .monospaced))
                    .focused($isFocused)
                    .submitLabel(.send)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(submit)
                    .padding(.horizontal, AppSpacing.sm)
                    .frame(minHeight: AppHostMetrics.iconControlTarget)
                    .background(
                        PR.cardHi,
                        in: RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous)
                            .strokeBorder(PR.border))

                Button(action: submit) {
                    Image(systemName: "return")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(command.isEmpty ? PR.dim : PR.bg)
                        .frame(
                            width: AppHostMetrics.iconControlTarget,
                            height: AppHostMetrics.iconControlTarget)
                        .background(
                            command.isEmpty ? PR.bg2 : PR.accent,
                            in: RoundedRectangle(
                                cornerRadius: AppHostMetrics.chipRadius, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(command.isEmpty)
                .accessibilityLabel("Run command")
            }
        }
        .padding(.horizontal, AppSpacing.xs)
        .padding(.vertical, AppSpacing.xs)
        .background(
            PR.card.opacity(0.97),
            in: RoundedRectangle(cornerRadius: PR.rCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PR.rCard, style: .continuous)
                .strokeBorder(PR.borderHi))
        .padding(.horizontal, AppSpacing.xs)
        .padding(.bottom, AppSpacing.xxs)
        .onAppear { refocus() }
    }

    private func auxKey(
        _ title: String,
        _ keyCode: UInt16,
        _ modifiers: KeyboardModifierFlags = [],
        hint: String? = nil
    ) -> some View {
        Button {
            onKey(keyCode, modifiers)
            refocus()
        } label: {
            Text(title)
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .foregroundStyle(PR.fg)
                .frame(minWidth: 44)
                .frame(minHeight: AppHostMetrics.iconControlTarget)
                .background(
                    PR.bg2,
                    in: RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppHostMetrics.chipRadius, style: .continuous)
                        .strokeBorder(PR.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hint ?? title)
    }

    private func submit() {
        guard !command.isEmpty else { return }
        onText(command)
        onKey(36, [])
        command = ""
        refocus()
    }

    private func refocus() {
        DispatchQueue.main.async { isFocused = true }
    }

    private func pasteIntoCommand() {
#if canImport(UIKit) && !os(macOS)
        if let text = UIPasteboard.general.string { command += text }
#endif
        refocus()
    }
}
