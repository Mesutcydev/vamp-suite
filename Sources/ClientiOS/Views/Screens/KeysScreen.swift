import SwiftUI
import SharedModels

struct KeysScreen: View {
    let environment: ClientAppEnvironment

    @ObservedObject private var sessionCoordinator: ClientSessionCoordinator
    @StateObject private var interactionVM: RemoteInteractionViewModel
    @State private var typed = ""
    @State private var previousTyped = ""
    @State private var blink = false
    @FocusState private var typeFocused: Bool

    private let edit: [(String, String)] = [("⌘C", "copy"), ("⌘V", "paste"), ("⌘Z", "undo"), ("⌘⇧Z", "redo")]
    private let system: [(String, String)] = [("⌘␣", "spotlight"), ("⌘⇥", "switch"), ("F11", "desktop"), ("⌃⌘Q", "lock")]
    private let capture: [(String, String)] = [("⌘⇧3", "screenshot"), ("⌘⇧4", "area shot"), ("⌘⇧5", "capture ui"), ("⌘⇧4␣", "window shot")]
    private let media: [(String, String)] = [("◀◀", "prev"), ("⏯", "play"), ("▶▶", "next"), ("🔇", "mute")]

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        self.sessionCoordinator = environment.sessionCoordinator
        _interactionVM = StateObject(
            wrappedValue: RemoteInteractionViewModel(
                webRTCSessionManager: environment.webRTCSessionManager,
                displayLayoutViewModel: environment.displayLayoutViewModel
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            PRScreenHeader(
                title: "keys",
                host: sessionCoordinator.connectedHostName ?? "no-host",
                latency: latencyText,
                state: sessionCoordinator.phase == .receiving ? .live : .idle
            )

            ScrollView {
                VStack(spacing: 12) {
                    PRCard("type-through") {
                        HStack(spacing: 10) {
                            Text(typed.isEmpty ? "type to send keystrokes" : typed)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(typed.isEmpty ? PR.dim : PR.fg)
                            Rectangle()
                                .fill(PR.accent)
                                .frame(width: 2, height: 14)
                                .opacity(blink ? 0 : 1)
                            Spacer()
                            Button {
                                typeFocused = true
                            } label: {
                                Image(systemName: "keyboard")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(PR.accent)
                                    .padding(8)
                                    .overlay(RoundedRectangle(cornerRadius: PR.r6).strokeBorder(PR.accent.opacity(0.5)))
                            }
                            .buttonStyle(.plain)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { typeFocused = true }

                        TextField("", text: $typed)
                            .focused($typeFocused)
                            .opacity(0.001)
                            .frame(height: 0)
                            .onChangeCompat(of: typed) { newValue in
                                handleTypedChange(newValue)
                            }
                    }

                    shortcutCard(title: "edit", items: edit)
                    shortcutCard(title: "system", items: system)
                    shortcutCard(title: "capture", items: capture)
                    shortcutCard(title: "media", items: media)

                    Button {} label: {
                        Text("+ bind new shortcut")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(PR.dim)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .overlay(
                                RoundedRectangle(cornerRadius: PR.r8)
                                    .strokeBorder(PR.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(PR.bg)
        .task {
            interactionVM.sessionID = sessionCoordinator.activeSessionID
            interactionVM.sessionMode = environment.prefersViewOnly ? .viewOnly : sessionCoordinator.sessionMode
            interactionVM.updateForConnectionState(environment.webRTCSessionManager.connectionState)
            withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: true)) {
                blink.toggle()
            }
        }
        .onChangeCompat(of: sessionCoordinator.activeSessionID) { id in
            interactionVM.sessionID = id
        }
        .onChangeCompat(of: sessionCoordinator.phase) { _ in
            interactionVM.updateForConnectionState(environment.webRTCSessionManager.connectionState)
        }
    }

    private func shortcutCard(title: LocalizedStringKey, items: [(String, String)]) -> some View {
        PRCard(title) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(items, id: \.0) { combo, name in
                    Button {
                        send(combo: combo)
                    } label: {
                        HStack(spacing: 8) {
                            PRKeycap(combo: combo)
                            Text(name)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(PR.fg2)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func handleTypedChange(_ newValue: String) {
        if newValue.count > previousTyped.count {
            let suffix = String(newValue.dropFirst(previousTyped.count))
            interactionVM.sendText(suffix)
        } else if newValue.count < previousTyped.count {
            tap(keyCode: 51)
        }
        previousTyped = newValue
    }

    private func send(combo: String) {
        switch combo {
        case "⌘C": tap(keyCode: 8, modifiers: [.command])
        case "⌘V": tap(keyCode: 9, modifiers: [.command])
        case "⌘Z": tap(keyCode: 6, modifiers: [.command])
        case "⌘⇧Z": tap(keyCode: 6, modifiers: [.command, .shift])
        case "⌘␣": tap(keyCode: 49, modifiers: [.command])
        case "⌘⇥": tap(keyCode: 48, modifiers: [.command])
        case "F11": tap(keyCode: 103)
        case "⌃⌘Q": tap(keyCode: 12, modifiers: [.control, .command])
        case "⌘⇧3": tap(keyCode: 20, modifiers: [.command, .shift])
        case "⌘⇧4": tap(keyCode: 21, modifiers: [.command, .shift])
        case "⌘⇧5": tap(keyCode: 23, modifiers: [.command, .shift])
        case "⌘⇧4␣":
            // ⌘⇧4 then space = capture a whole window
            tap(keyCode: 21, modifiers: [.command, .shift])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                tap(keyCode: 49)
            }
        case "◀◀": tap(keyCode: 98)
        case "⏯": tap(keyCode: 100)
        case "▶▶": tap(keyCode: 101)
        case "🔇": tap(keyCode: 109)
        default: break
        }
    }

    private func tap(keyCode: UInt16, modifiers: KeyboardModifierFlags = []) {
        interactionVM.sendKey(keyCode: keyCode, action: .down, modifiers: modifiers)
        interactionVM.sendKey(keyCode: keyCode, action: .up, modifiers: modifiers)
    }

    private var latencyText: String {
        guard let latency = sessionCoordinator.lastRoundTripLatencyMs else { return "--" }
        return String(format: "%.1fms", latency)
    }
}

#Preview("KeysScreen") {
    KeysScreen(environment: ClientAppEnvironment.makeDefault(clientName: "Vamp Control"))
}
