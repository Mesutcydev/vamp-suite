import SwiftUI
import SharedModels

struct MacKeyboardFocusHint: View {
    let readiness: MacInputReadiness
    let keyboardFocused: Bool

    var body: some View {
        if readiness == .viewOnly || (readiness == .ready && !keyboardFocused) {
            Label(readiness.message, systemImage: readiness == .viewOnly ? "eye" : "keyboard")
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .allowsHitTesting(false)
        }
    }
}

struct MacSessionAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var enabled = true
    var shortcut: KeyEquivalent? = nil
    let perform: () -> Void
}

/// Both transports supply only the actions they implement, in the same order.
struct MacSessionToolsMenu: View {
    let actions: [MacSessionAction]
    let canSendInput: Bool
    let sendKey: (MacRemoteShortcut) -> Void
    let showKeyboardHelp: () -> Void
    @Binding var showsStats: Bool
    @Binding var quickActionID: String

    var body: some View {
        Menu {
            ForEach(actions) { action in
                Button(action: action.perform) { Label(action.title, systemImage: action.symbol) }
                    .disabled(!action.enabled)
                    .keyboardShortcut(action.shortcut.map { KeyboardShortcut($0, modifiers: [.control, .option]) })
            }
            Divider()
            Menu("Send Key") {
                ForEach(MacRemoteShortcut.allCases) { key in
                    Button(key.title) { sendKey(key) }
                        .disabled(!canSendInput)
                        .keyboardShortcut(key == .commandTab ? KeyboardShortcut(.tab, modifiers: [.control, .option]) : nil)
                }
            }
            Button("Keyboard shortcuts…", action: showKeyboardHelp)
            Divider()
            Toggle("Show live stats", isOn: $showsStats)
            Picker("Quick action in wide windows", selection: Binding(
                get: { actions.contains(where: { $0.id == quickActionID }) ? quickActionID : "none" },
                set: { quickActionID = $0 })) {
                Text("None").tag("none")
                ForEach(actions) { action in Text(action.title).tag(action.id) }
            }
        } label: {
            Label("Tools", systemImage: "ellipsis.circle").labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 12))
        .help("Session tools and remote keyboard shortcuts")
    }
}

struct MacSessionAccessButton: View {
    @Binding var viewOnly: Bool
    let readiness: MacInputReadiness
    let keyboardFocused: Bool

    var body: some View {
        Button { viewOnly.toggle() } label: {
            Label(viewOnly ? "View only" : "Control", systemImage: viewOnly ? "eye" : "cursorarrow.motionlines").labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .help(viewOnly ? "Enable remote mouse and keyboard" : "Switch to view only")
        .accessibilityLabel("Access mode")
        .accessibilityValue(readiness.canSendInput
            ? (keyboardFocused ? "Control, keyboard on remote Mac" : "Control, keyboard on this Mac")
            : readiness.message)
    }
}

struct MacConnectionDetails: View {
    let hostName: String
    let transportConnected: Bool
    let receivingVideo: Bool
    let readiness: MacInputReadiness
    let keyboardFocused: Bool
    let unavailable: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(hostName).font(.headline)
            Label(transportConnected ? "Connected" : "Reconnecting", systemImage: "network")
            Label(receivingVideo ? "Receiving video" : "Waiting for video", systemImage: "display")
            Label(readiness.canSendInput ? "Control available" : readiness.message, systemImage: "cursorarrow")
            Text(keyboardFocused ? "Keyboard: remote Mac" : "Keyboard: this Mac")
                .foregroundStyle(.secondary)
            if !unavailable.isEmpty {
                Divider()
                Text("Unavailable for this connection").font(.subheadline.weight(.semibold))
                Text(unavailable.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(20)
        .frame(width: 300, alignment: .leading)
    }
}

struct MacKeyboardHelp: View {
    @Binding var keepsDisplayShortcutsLocal: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard shortcuts").font(.title2.weight(.semibold))
            Text("Click the stream to send typing and arrows to the remote Mac. Click a local field or open a sheet to type on this Mac.")
            Text("Kept on this Mac").font(.headline)
            Text("⌘Q Quit · ⌘M Minimize · ⌘H Hide · ⌘, Settings\n⇧⌘D Disconnect\n⌘R Refresh hosts (outside a session)")
            Toggle("Use ⌘0 / ⌘1 / ⌘2 for local display sizing", isOn: $keepsDisplayShortcutsLocal)
            Text(keepsDisplayShortcutsLocal
                ? "⌘0 Fit · ⌘1 Fill · ⌘2 Actual Size. Saved for this connection."
                : "⌘0 / ⌘1 / ⌘2 go to the remote app while the stream is focused. Saved for this connection.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Sent to the remote Mac").font(.headline)
            Text("Typing, arrows, and other app shortcuts such as ⌘C, ⌘V and ⌘W while the stream has focus. Shift and Option modify arrows as usual.")
            Text("macOS reserves some shortcuts before Vamp receives them. Use Tools → Send Key for Command-Tab, Command-Space and Control-arrows.")
                .foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 480)
    }
}

struct MacSessionQuickAction: View {
    let action: MacSessionAction
    var body: some View {
        Button(action: action.perform) { Label(action.title, systemImage: action.symbol) }
            .labelStyle(.iconOnly)
            .disabled(!action.enabled)
            .help(action.title)
    }
}

struct MacSessionQualitySettings: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: SharedModels.StreamQualityPreset
    let supportsUltra: Bool
    let isConnected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stream quality").font(.title2.weight(.semibold))
            Picker("Quality", selection: $selection) {
                Text("Performance — lower bandwidth").tag(SharedModels.StreamQualityPreset.performance)
                Text("Balanced — everyday use").tag(SharedModels.StreamQualityPreset.balanced)
                Text("Quality — sharper detail").tag(SharedModels.StreamQualityPreset.quality)
                if supportsUltra { Text("Ultra — native resolution").tag(SharedModels.StreamQualityPreset.ultra) }
            }.disabled(!isConnected)
            Text(isConnected ? "Applies to this stream now. The host may adapt quality to network conditions."
                 : "Reconnect to change stream quality.")
                .font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 420)
    }
}

/// Preserve primary controls in narrow windows. Secondary actions remain in Tools.
struct MacSessionWidthReader: ViewModifier {
    @Binding var isCompact: Bool
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { isCompact = proxy.size.width < 900 }
                    .onChange(of: proxy.size.width) { isCompact = $0 < 900 }
            }
        }
    }
}

// The session uses one quiet native toolbar. Avoid layering the system glass
// capsules over custom button surfaces on macOS 26 and later.
extension ToolbarContent {
    @ToolbarContentBuilder
    func compactSessionChrome() -> some ToolbarContent {
        if #available(macOS 26, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
