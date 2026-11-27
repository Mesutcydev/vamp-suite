import SwiftUI
import SharedModels

/// Settings read like `vamp config`: one shell prompt per group over a clear glass
/// panel, `on`/`off` pills instead of switches, and `# comments` for the fine print.
/// Same grid as Home: every label starts on the 16 pt text column.
struct ControlSettingsView: View {
    @ObservedObject var environment: ClientAppEnvironment
    @ObservedObject var appLock: AppLockService
    @ObservedObject var companion: BeetCodeRemoteSessionViewModel
    @ObservedObject var unlock: StreamingUnlockStore
    @ObservedObject var usage: DailyStreamingUsage
    @State private var showsPaywall = false
    @StateObject private var trusted: ClientTrustedHostsViewModel
    @AppStorage(ControlAppearance.storageKey) private var appearance = ControlAppearance.system
    @AppStorage("client.liveActivity.enabled") private var liveActivityEnabled = true
    @AppStorage("client.clipboard.enabled") private var clipboardEnabled = true
    @AppStorage(ClientFileTransferPreference.storageKey) private var fileTransferEnabled = true
    @AppStorage(ControlExperiments.companionKey) private var companionEnabled = false

    init(environment: ClientAppEnvironment, appLock: AppLockService, companion: BeetCodeRemoteSessionViewModel,
         unlock: StreamingUnlockStore, usage: DailyStreamingUsage) {
        self.environment = environment
        self.appLock = appLock
        self.companion = companion
        self.unlock = unlock
        self.usage = usage
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
                    ControlChoiceRow(key: "Theme", selection: $appearance,
                                     options: [(.system, "Auto"), (.light, "Light"), (.dark, "Dark")])
                        .accessibilityIdentifier("control.appearance")
                }

                ControlConfigSection(command: "config stream", label: "Sync streaming",
                                     note: "Balanced is a good start on most networks.") {
                    ControlChoiceRow(key: "Quality", selection: $environment.preferredQualityPreset,
                                     options: [(.performance, "Eco"), (.balanced, "Balanced"),
                                               (.quality, "Sharp"), (.ultra, "Full")])
                    ControlRule()
                    Toggle("Low power", isOn: $environment.lowPowerModeEnabled)
                    ControlRule()
                    Toggle("Stats overlay", isOn: $environment.showsStatsOverlay)
                }

                ControlConfigSection(command: "config sharing", label: "Sync controls",
                                     note: "Sharing happens only when you ask. View Only Macs never take input.") {
                    Toggle("View only", isOn: $environment.prefersViewOnly)
                    ControlRule()
                    Toggle("Clipboard", isOn: $clipboardEnabled)
                    ControlRule()
                    Toggle("File transfer", isOn: $fileTransferEnabled)
                    ControlRule()
                    Toggle("Live Activity", isOn: $liveActivityEnabled)
                }

                ControlConfigSection(command: "config privacy", label: "Privacy and trust",
                                     note: "App Lock asks for Face ID or your passcode. Pairing stays on this device.") {
                    Toggle("App Lock", isOn: $appLock.isEnabled)
                    ControlRule()
                    NavigationLink {
                        ControlTrustedMacsView(trusted: trusted, companion: companion)
                    } label: {
                        ControlValueRow(key: "Paired Macs",
                                        value: "\(trusted.trustedHosts.count + companion.savedAssistants.count) →")
                    }
                    .buttonStyle(ControlRowPressStyle())
                }

                if StreamingUnlockStore.isEnforced {
                    ControlConfigSection(command: "config pro", label: "Vamp Pro",
                                         note: "15 minutes a day are free. Vamp Pro is one payment, with no subscription.") {
                        Button { showsPaywall = true } label: {
                            ControlValueRow(key: "Vamp Pro", value: proStatus)
                        }
                        .buttonStyle(ControlRowPressStyle())
                        .accessibilityIdentifier("control.pro")
                        ControlRule()
                        Button { Task { await unlock.restore() } } label: {
                            ControlValueRow(key: "Restore Purchase", value: unlock.isLoading ? "…" : "↻")
                        }
                        .buttonStyle(ControlRowPressStyle())
                        .disabled(unlock.isLoading)
                        if let message = unlock.purchaseError ?? unlock.purchaseNotice {
                            ControlRule()
                            Text(message).font(.footnote).foregroundStyle(ControlDesign.secondary)
                                .frame(maxWidth: .infinity, minHeight: ControlDesign.lineHeight, alignment: .leading)
                        }
                    }
                }

                ControlConfigSection(command: "config experimental", label: "Experimental",
                                     note: "Early features for a future app. Off by default; Macs you already paired stay listed.") {
                    Toggle("Vamp Companion pairing", isOn: $companionEnabled)
                        .accessibilityIdentifier("control.experimental.companion")
                }

                ControlConfigSection(command: "open", label: "On your Mac") {
                    link("Get Vamp Sync", VampProductLinks.syncDownload)
                    ControlRule()
                    link("Help & Feedback", VampProductLinks.support)
                    ControlRule()
                    link("Privacy Policy", VampProductLinks.privacy)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Vamp Control \(version)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced)).textCase(.uppercase).tracking(1.1)
                    Text("Made for the way you Mac.").font(.footnote)
                }
                .foregroundStyle(ControlDesign.secondary)
                .padding(.leading, ControlDesign.inset)
            }
            .toggleStyle(ControlSwitchStyle())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .task { await trusted.refresh() }
            .sheet(isPresented: $showsPaywall) {
                StreamingPaywallView(unlockStore: unlock, usage: usage, onDismiss: { showsPaywall = false })
            }
        }
        .tint(ControlDesign.accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(ControlDesign.ink)
                .accessibilityAddTraits(.isHeader)
            Text("How Vamp Control looks and connects on this device.").font(.subheadline).foregroundStyle(ControlDesign.secondary)
        }
        .padding(.leading, ControlDesign.inset)
    }

    private var proStatus: String {
        if unlock.isEffectivelyUnlocked { return String(localized: "Unlocked") }
        let left = max(0, Int((DailyStreamingUsage.dailyLimitSeconds - usage.secondsUsedToday) / 60))
        return String(localized: "\(left) min left today")
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

/// Every Mac this device trusts, with its fingerprint and a way to undo it.
struct ControlTrustedMacsView: View {
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
                        Text("No paired Macs yet")
                        Text("Your Macs appear here after you pair.")
                    }
                    .font(.body).foregroundStyle(ControlDesign.secondary)
                    .padding(.horizontal, ControlDesign.inset)
                }
            }
            if !trusted.trustedHosts.isEmpty {
                ControlConfigSection(command: "ls paired --sync", label: "Vamp Sync",
                                     note: "Revoke a Mac and it asks for approval again.") {
                    ForEach(Array(trusted.trustedHosts.enumerated()), id: \.element.id) { index, host in
                        if index > 0 { ControlRule() }
                        pairedRow(name: host.displayName,
                                  detail: ControlConnectionProgress.grouped(host.fingerprint),
                                  action: "Revoke") {
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
                        pairedRow(name: saved.displayName, detail: saved.address, action: "Forget") {
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
                Text(verbatim: detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(ControlDesign.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: ControlDesign.gap)
            Button(action: perform) {
                ControlCapsule(title: action, style: .end)
            }
            .buttonStyle(ControlPressStyle())
        }
        .padding(.vertical, ControlDesign.stack)
    }
}

/// A native switch on a full-height settings row, green when on.
struct ControlSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .tint(ControlDesign.available)
            .foregroundStyle(ControlDesign.ink)
            .frame(minHeight: ControlDesign.lineHeight)
    }
}

/// Paired Macs on their own, for the Trusted tab.
struct ControlTrustedTab: View {
    let environment: ClientAppEnvironment
    @ObservedObject var companion: BeetCodeRemoteSessionViewModel
    @StateObject private var trusted: ClientTrustedHostsViewModel

    init(environment: ClientAppEnvironment, companion: BeetCodeRemoteSessionViewModel) {
        self.environment = environment
        self.companion = companion
        _trusted = StateObject(wrappedValue: ClientTrustedHostsViewModel(peerStore: environment.trustedPeerStore))
    }

    var body: some View {
        NavigationStack {
            ControlTrustedMacsView(trusted: trusted, companion: companion)
                .navigationBarTitleDisplayMode(.inline)
        }
        .tint(ControlDesign.accent)
    }
}
