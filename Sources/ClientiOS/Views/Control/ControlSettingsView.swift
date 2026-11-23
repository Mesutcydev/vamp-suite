import SwiftUI
import SharedModels

/// Settings read like `vamp config`: one shell prompt per group over a clear glass
/// panel, `on`/`off` pills instead of switches, and `# comments` for the fine print.
/// Same grid as Home: every label starts on the 16 pt text column.
struct ControlSettingsView: View {
    @ObservedObject var environment: ClientAppEnvironment
    @ObservedObject var appLock: AppLockService
    @ObservedObject var companion: BeetCodeRemoteSessionViewModel
    @StateObject private var trusted: ClientTrustedHostsViewModel
    @AppStorage(ControlAppearance.storageKey) private var appearance = ControlAppearance.system
    @AppStorage("client.liveActivity.enabled") private var liveActivityEnabled = true
    @AppStorage("client.clipboard.enabled") private var clipboardEnabled = true
    @AppStorage(ClientFileTransferPreference.storageKey) private var fileTransferEnabled = true
    @Environment(\.dismiss) private var dismiss

    init(environment: ClientAppEnvironment, appLock: AppLockService, companion: BeetCodeRemoteSessionViewModel) {
        self.environment = environment
        self.appLock = appLock
        self.companion = companion
        _trusted = StateObject(wrappedValue: ClientTrustedHostsViewModel(peerStore: environment.trustedPeerStore))
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ControlPage {
                header

                ControlConfigSection(command: "config look", label: "Appearance") {
                    ControlChoiceRow(key: "theme", selection: $appearance,
                                     options: [(.system, "auto"), (.light, "light"), (.dark, "dark")])
                        .accessibilityIdentifier("control.appearance")
                }

                ControlConfigSection(command: "config stream", label: "Sync streaming",
                                     note: "# balanced is a good start · companion sets its own picture") {
                    ControlChoiceRow(key: "quality", selection: $environment.preferredQualityPreset,
                                     options: [(.performance, "eco"), (.balanced, "balanced"),
                                               (.quality, "sharp"), (.ultra, "full")])
                    ControlRule()
                    Toggle("low power", isOn: $environment.lowPowerModeEnabled)
                    ControlRule()
                    Toggle("stats overlay", isOn: $environment.showsStatsOverlay)
                }

                ControlConfigSection(command: "config sharing", label: "Sync controls",
                                     note: "# sharing happens when you ask · view only hosts never take input") {
                    Toggle("view only", isOn: $environment.prefersViewOnly)
                    ControlRule()
                    Toggle("clipboard", isOn: $clipboardEnabled)
                    ControlRule()
                    Toggle("file transfer", isOn: $fileTransferEnabled)
                    ControlRule()
                    Toggle("live activity", isOn: $liveActivityEnabled)
                }

                ControlConfigSection(command: "config privacy", label: "Privacy and trust",
                                     note: "# app lock asks for face id or your passcode · pairing belongs to you") {
                    Toggle("app lock", isOn: $appLock.isEnabled)
                    ControlRule()
                    NavigationLink {
                        ControlTrustedMacsView(trusted: trusted, companion: companion)
                    } label: {
                        ControlValueRow(key: "paired macs",
                                        value: "\(trusted.trustedHosts.count + companion.savedAssistants.count) →")
                    }
                    .buttonStyle(ControlRowPressStyle())
                }

                ControlConfigSection(command: "open", label: "On your Mac") {
                    link("get vamp sync", VampProductLinks.syncDownload)
                    ControlRule()
                    link("help & feedback", VampProductLinks.support)
                    ControlRule()
                    link("privacy policy", VampProductLinks.privacy)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "# vamp control \(version)")
                    Text("# made for the way you mac")
                }
                .font(.footnote).foregroundStyle(ControlDesign.secondary)
                .padding(.leading, ControlDesign.inset)
            }
            .toggleStyle(ControlToggleStyle())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await trusted.refresh() }
        }
        .preferredColorScheme(appearance.colorScheme)
        .tint(ControlDesign.accent)
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: ControlDesign.stack) {
            ControlGlassLogo()
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Text(verbatim: "vamp").fontWeight(.bold).foregroundStyle(ControlDesign.ink)) \(Text(verbatim: "~/settings").foregroundStyle(ControlDesign.secondary))")
                    .font(.title3)
                    .accessibilityLabel("Settings")
                    .accessibilityAddTraits(.isHeader)
                Text("# a little closer to your mac").font(.footnote).foregroundStyle(ControlDesign.secondary)
            }
        }
    }

    private func link(_ title: LocalizedStringKey, _ url: URL) -> some View {
        Link(destination: url) { ControlValueRow(key: title, value: "↗") }
            .buttonStyle(ControlRowPressStyle())
    }
}

/// A scrolling Control page on the ambient backdrop, laid out on the shared grid.
struct ControlPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ControlDesign.section) { content }
                .frame(maxWidth: ControlDesign.maxWidth, alignment: .leading)
                .padding(.horizontal, ControlDesign.gutter)
                .padding(.top, ControlDesign.gap)
                .padding(.bottom, ControlDesign.section)
                .frame(maxWidth: .infinity)
        }
        .background { ControlBackground() }
    }
}

/// `$ command` over one glass panel of lines, with an optional `# note` beneath.
struct ControlConfigSection<Content: View>: View {
    let command: String
    let label: LocalizedStringKey
    var note: LocalizedStringKey?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: ControlDesign.gap) {
            ControlPrompt(command: command, label: label)
            VStack(spacing: 0) { content }
                .font(.body)
                .padding(.horizontal, ControlDesign.inset)
                .controlGlass()
            if let note {
                Text(note).font(.footnote).foregroundStyle(ControlDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ControlDesign.inset)
            }
        }
    }
}

/// `key ··· value`, one line. Used for navigation and links.
struct ControlValueRow: View {
    let key: LocalizedStringKey
    let value: String
    var body: some View {
        HStack(spacing: ControlDesign.stack) {
            Text(key).foregroundStyle(ControlDesign.ink)
            Spacer(minLength: ControlDesign.gap)
            Text(verbatim: value).foregroundStyle(ControlDesign.secondary)
        }
        .font(.body)
        .frame(minHeight: ControlDesign.lineHeight)
        .contentShape(Rectangle())
    }
}

/// A switch as a terminal flag: `● on` / `○ off`. Fixed width, so nothing shifts.
struct ControlToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let tint = configuration.isOn ? ControlDesign.available : ControlDesign.secondary
        Button {
            AppHaptics.selection()
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: ControlDesign.stack) {
                configuration.label.foregroundStyle(ControlDesign.ink)
                Spacer(minLength: ControlDesign.gap)
                HStack(spacing: 6) {
                    Circle().fill(configuration.isOn ? tint : .clear)
                        .overlay { Circle().strokeBorder(tint, lineWidth: 1.2) }
                        .frame(width: 8, height: 8)
                    Text(configuration.isOn ? "on" : "off")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 72, height: ControlDesign.smallButtonHeight)
                .background(tint.opacity(configuration.isOn ? 0.14 : 0.08), in: Capsule())
                .animation(.snappy(duration: 0.18), value: configuration.isOn)
            }
            .frame(minHeight: ControlDesign.lineHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// `key` above a row of capsules, the chosen one filled: a segmented control in mono.
struct ControlChoiceRow<Value: Hashable>: View {
    let key: LocalizedStringKey
    @Binding var selection: Value
    let options: [(Value, LocalizedStringKey)]
    var body: some View {
        VStack(alignment: .leading, spacing: ControlDesign.gap) {
            Text(key).foregroundStyle(ControlDesign.secondary)
            HStack(spacing: 4) {
                ForEach(options.indices, id: \.self) { index in
                    let (value, title) = options[index]
                    let isOn = selection == value
                    Button {
                        AppHaptics.selection()
                        selection = value
                    } label: {
                        Text(title).font(.subheadline.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(isOn ? ControlDesign.buttonInk : ControlDesign.ink)
                            .frame(maxWidth: .infinity, minHeight: ControlDesign.smallButtonHeight)
                            .background(isOn ? ControlDesign.accent : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(4)
            .background(ControlDesign.ink.opacity(0.06), in: Capsule())
            .animation(.snappy(duration: 0.2), value: selection)
        }
        .padding(.vertical, ControlDesign.stack)
    }
}

/// `$ ls paired`: every Mac this device trusts, with its fingerprint and a way to undo it.
private struct ControlTrustedMacsView: View {
    @ObservedObject var trusted: ClientTrustedHostsViewModel
    @ObservedObject var companion: BeetCodeRemoteSessionViewModel
    @State private var forgetAction: (() -> Void)?
    @State private var showsForget = false

    var body: some View {
        ControlPage {
            if trusted.trustedHosts.isEmpty && companion.savedAssistants.isEmpty {
                VStack(alignment: .leading, spacing: ControlDesign.gap) {
                    ControlPrompt(command: "ls paired", label: "Paired Macs")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("# no paired macs yet")
                        Text("# your macs appear here after you pair")
                    }
                    .font(.body).foregroundStyle(ControlDesign.secondary)
                    .padding(.horizontal, ControlDesign.inset)
                }
            }
            if !trusted.trustedHosts.isEmpty {
                ControlConfigSection(command: "ls paired --sync", label: "Vamp Sync",
                                     note: "# revoke, and that mac asks for approval again") {
                    ForEach(Array(trusted.trustedHosts.enumerated()), id: \.element.id) { index, host in
                        if index > 0 { ControlRule() }
                        pairedRow(name: host.displayName,
                                  detail: ControlConnectionProgress.grouped(host.fingerprint),
                                  action: "revoke") {
                            forgetAction = { Task { await trusted.forget(host) } }
                            showsForget = true
                        }
                    }
                }
            }
            if !companion.savedAssistants.isEmpty {
                ControlConfigSection(command: "ls paired --companion", label: "Vamp Companion") {
                    ForEach(Array(companion.savedAssistants.enumerated()), id: \.element.id) { index, saved in
                        if index > 0 { ControlRule() }
                        pairedRow(name: saved.displayName, detail: saved.address, action: "forget") {
                            forgetAction = { companion.forget(saved) }
                            showsForget = true
                        }
                    }
                }
            }
            if let error = trusted.errorMessage {
                ControlNotice(message: error)
            }
        }
        .navigationTitle("Paired Macs")
        .task { await trusted.refresh() }
        .confirmationDialog("Remove this Mac’s pairing?", isPresented: $showsForget, titleVisibility: .visible) {
            Button("Remove pairing", role: .destructive) { forgetAction?(); forgetAction = nil }
            Button("Cancel", role: .cancel) { forgetAction = nil }
        } message: { Text("You’ll need to pair again before reconnecting.") }
    }

    private func pairedRow(name: String, detail: String, action: LocalizedStringKey,
                           perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: ControlDesign.stack) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: name).font(.body.weight(.semibold)).foregroundStyle(ControlDesign.ink)
                Text(verbatim: detail).font(.caption).foregroundStyle(ControlDesign.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: ControlDesign.gap)
            Button(action: perform) {
                Text(action).font(.subheadline.weight(.semibold)).foregroundStyle(ControlDesign.caution)
                    .padding(.horizontal, ControlDesign.stack).frame(height: ControlDesign.smallButtonHeight)
                    .controlGlass(radius: ControlDesign.smallButtonHeight / 2, interactive: true, emphasis: .control)
            }
            .buttonStyle(ControlPressStyle())
        }
        .padding(.vertical, ControlDesign.stack)
    }
}
