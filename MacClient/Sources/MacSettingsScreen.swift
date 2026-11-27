import SwiftUI
import AppKit
import SharedModels
import Diagnostics

/// App settings window (⌘,): stream quality, behavior toggles, trusted hosts,
/// diagnostics, and Vamp Pro (store) or open-source release information (website).
/// Each tab is a grouped glass list over the Vamp backdrop.
struct MacSettingsScreen: View {
    @ObservedObject var environment: ClientAppEnvironment
    @StateObject private var trustedHostsVM: ClientTrustedHostsViewModel

    // Diagnostics tab: connection log + on-device "explain this log".
    @State private var logItems: [EventLogItem] = []
    @State private var explainAvailable = false
    @State private var explaining = false
    @State private var explanation: String?
    @State private var explainEngine: LogExplainer.Engine?

    // Feature toggles share the same keys the iOS client uses, so a user's
    // preference is consistent across both apps' shared logic.
    @AppStorage(ClientFileTransferPreference.storageKey) private var fileTransferEnabled = true
    @AppStorage("client.clipboard.enabled") private var clipboardEnabled = true
    /// Vamp Assistant pairing is an experimental option for a future app, off by default.
    @AppStorage(MacExperiments.assistantKey) private var assistantEnabled = false

    // Vamp Pro tab (store builds only).
    @StateObject private var unlock = StreamingUnlockStore()
    @StateObject private var usage = DailyStreamingUsage()
    @State private var showsPaywall = false

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        _trustedHostsVM = StateObject(wrappedValue: ClientTrustedHostsViewModel(
            peerStore: environment.trustedPeerStore
        ))
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            trustedHostsTab
                .tabItem { Label("Trusted Hosts", systemImage: "checkmark.shield") }
            diagnosticsTab
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            if StreamingUnlockStore.isEnforced {
                proTab
                    .tabItem { Label("Vamp Pro", systemImage: "sparkles") }
            } else {
                openSourceTab
                    .tabItem { Label("Open Source", systemImage: "checkmark.seal") }
            }
        }
        // Sized to the tallest tab; each tab scrolls rather than clipping.
        .frame(width: 560, height: 600)
    }

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content() }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MacBrand.pageBackdrop)
    }

    // MARK: - General

    private var generalTab: some View {
        page {
            MacSettingsGroup(title: "Streaming") {
                MacSettingsRow(title: "Stream quality", detail: "Used when a session starts", systemImage: "dial.high") {
                    Picker("Stream quality", selection: $environment.preferredQualityPreset) {
                        Text("Performance · 30 fps").tag(StreamQualityPreset.performance)
                        Text("Balanced · 30 fps").tag(StreamQualityPreset.balanced)
                        Text("Quality · 4K, 60 fps").tag(StreamQualityPreset.quality)
                        if environment.isUltraQualityEntitled {
                            Text("Ultra · native, 60 fps").tag(StreamQualityPreset.ultra)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if let message = environment.ultraQualityAvailabilityMessage {
                    MacSettingsDivider()
                    MacSettingsNote(text: message)
                }
            }

            MacSettingsGroup(title: "During sessions",
                             footer: "The session toolbar is always available in the window. The menu bar item adds connection status and a quick Disconnect.") {
                toggleRow("Show connection stats", systemImage: "waveform.path.ecg", isOn: $environment.showsStatsOverlay)
                if MacDistributionPolicy.allowsRemoteChanges {
                    MacSettingsDivider()
                    toggleRow("View only", detail: "Don’t send mouse or keyboard", systemImage: "eye", isOn: $environment.prefersViewOnly)
                }
                MacSettingsDivider()
                toggleRow("Low power mode", detail: "Reduce the refresh rate", systemImage: "leaf", isOn: $environment.lowPowerModeEnabled)
                MacSettingsDivider()
                toggleRow("Menu bar item", detail: "Connection status and a quick Disconnect",
                          systemImage: "menubar.arrow.up.rectangle", isOn: menuBarItemEnabled)
            }

            // App Store edition is View Only: file transfer and clipboard sync are website-edition features.
            if MacDistributionPolicy.allowsRemoteChanges {
                MacSettingsGroup(title: "Features",
                                 footer: "File transfer sends files to and receives files from the connected Mac. Clipboard sharing is manual: use Send Clipboard or Fetch Clipboard in the session tools.") {
                    toggleRow("File transfer", systemImage: "arrow.up.arrow.down.circle", isOn: $fileTransferEnabled)
                    MacSettingsDivider()
                    toggleRow("Clipboard sync", systemImage: "doc.on.clipboard", isOn: $clipboardEnabled)
                }
            }

            MacSettingsGroup(title: "Experimental",
                             footer: "Early features for a future app. Off by default.") {
                toggleRow("Vamp Assistant", detail: "Pair a Mac running Vamp Assistant from its own tab",
                          systemImage: "flask", isOn: $assistantEnabled)
            }

            MacSettingsGroup(title: "This Mac",
                             footer: "Your private key stays on this Mac. Your public identity and fingerprint are shared with hosts so they can verify a connection.") {
                MacSettingsRow(title: "Appears to hosts as", systemImage: "desktopcomputer") {
                    Text(environment.clientIdentity.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                MacSettingsDivider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Key fingerprint", systemImage: "key")
                            .font(.system(size: 13))
                            .labelStyle(MacSettingsLabelStyle())
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(environment.clientIdentity.publicKeyFingerprint, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(MacCapsuleButtonStyle(kind: .quiet))
                        .accessibilityLabel("Copy key fingerprint")
                    }
                    MacFingerprintChunks(fingerprint: environment.clientIdentity.publicKeyFingerprint)
                        .accessibilityLabel("Key fingerprint")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private func toggleRow(_ title: String, detail: String? = nil, systemImage: String, isOn: Binding<Bool>) -> some View {
        MacSettingsRow(title: title, detail: detail, systemImage: systemImage) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var menuBarItemEnabled: Binding<Bool> {
        Binding(
            get: {
                MacMenuBarPreference.isEnabled(
                    UserDefaults.standard.string(forKey: MacMenuBarPreference.storageKey) ?? ""
                )
            },
            set: {
                UserDefaults.standard.set(
                    MacMenuBarPreference.storedValue(enabled: $0),
                    forKey: MacMenuBarPreference.storageKey
                )
            }
        )
    }

    // MARK: - Trusted hosts

    private var trustedHostsTab: some View {
        page {
            MacTrustedMacsList(model: trustedHostsVM)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsTab: some View {
        page {
            if explainAvailable {
                MacSettingsGroup(title: "AI help",
                                 footer: explainEngine.map { "Answered by \($0.label) · your log isn’t stored or shared." }
                                    ?? "Runs privately — on-device or via Apple Private Cloud Compute; your log isn’t stored or shared.") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let explanation {
                            Text(explanation)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Analyze again") { Task { await explain() } }
                                .buttonStyle(MacCapsuleButtonStyle(kind: .glass))
                                .disabled(explaining)
                        } else {
                            Button {
                                Task { await explain() }
                            } label: {
                                Label(explaining ? "Analyzing…" : "Explain this log", systemImage: "sparkles")
                            }
                            .buttonStyle(MacCapsuleButtonStyle(kind: .glass))
                            .disabled(explaining || logItems.isEmpty)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            MacSettingsGroup(title: "Connection log") {
                VStack(alignment: .leading, spacing: 4) {
                    if logItems.isEmpty {
                        Text("No events yet — connect to a Mac, then reopen this.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(logItems.reversed()) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text(item.severity.rawValue.uppercased())
                                    .font(MacBrand.mono(9, weight: .bold))
                                    .foregroundStyle(logColor(item.severity))
                                    .frame(width: 44, alignment: .leading)
                                Text("\(item.category): \(item.message)")
                                    .font(MacBrand.mono(11, weight: .regular))
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await reloadLog() }
    }

    private func reloadLog() async {
        logItems = await environment.eventLogStore.recentItems(limit: 500)
        explainAvailable = LogExplainer.availability.isAvailable
    }

    private func explain() async {
        explaining = true
        explanation = nil
        let result = await LogExplainer.explain(logItems)
        explanation = result?.text ?? "Couldn’t analyze the log right now — try again in a moment."
        explainEngine = result?.engine
        explaining = false
    }

    private func logColor(_ s: EventSeverity) -> Color {
        switch s {
        case .error: return MacBrand.crimsonText
        case .warning: return .orange
        case .info, .debug: return .secondary
        }
    }

    // MARK: - Vamp Pro (store distribution)

    private var proTab: some View {
        page {
            VStack(spacing: 14) {
                MacMarkTile(size: 64, arc: .control, badge: unlock.isEffectivelyUnlocked ? "checkmark" : "sparkles")
                    .padding(.bottom, 4)
                MacMetaLabel(text: "Vamp Pro")
                Text(unlock.isEffectivelyUnlocked ? "Vamp Pro is unlocked" : "Stream without the daily limit")
                    .font(.system(size: 20, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(unlock.isEffectivelyUnlocked
                     ? "Vamp Control streams without a daily limit on this Mac."
                     : "Vamp Control streams for 15 minutes a day for free. Vamp Pro is a one-time purchase that removes the limit. No subscription.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                if !unlock.isEffectivelyUnlocked {
                    MacUsageMeter(usage: usage)
                        .frame(maxWidth: 340)
                    Button("View Vamp Pro…") { showsPaywall = true }
                        .buttonStyle(MacCapsuleButtonStyle(kind: .primary, large: true))
                }
                Button("Restore Purchase") { Task { await unlock.restore() } }
                    .buttonStyle(MacCapsuleButtonStyle(kind: .glass))
                    .disabled(unlock.isLoading)
                // The result used to be shown only inside the paywall sheet, which this button
                // never opens, so restoring looked like it did nothing.
                if let result = unlock.purchaseNotice ?? unlock.purchaseError {
                    Text(result)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 4) {
                    Link("Privacy Policy", destination: VampProductLinks.privacy)
                    Link("Help & Feedback", destination: VampProductLinks.support)
                }
                .buttonStyle(MacCapsuleButtonStyle(kind: .quiet))
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .macCard(radius: 20)
        }
        .task {
            if unlock.product == nil { await unlock.refresh() }
        }
        .sheet(isPresented: $showsPaywall) {
            MacStreamingPaywallView(unlock: unlock, usage: usage, onDismiss: { showsPaywall = false })
        }
    }

    // MARK: - Open-source distribution

    private var openSourceTab: some View {
        page {
            VStack(spacing: 14) {
                MacMarkTile(size: 64, arc: .control, badge: "checkmark")
                    .padding(.bottom, 4)
                MacMetaLabel(text: "Open source")
                Text("All features included.")
                    .font(.system(size: 20, weight: .bold))
                Text("Vamp Control includes unlimited streaming and every quality preset supported by this Mac. There are no subscriptions or in-app purchases.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                VStack(spacing: 2) {
                    Link("Source, licenses, and release integrity",
                         destination: URL(string: "https://github.com/Mesutcydev/vamp-suite")!)
                    Link("Privacy Policy", destination: VampProductLinks.privacy)
                    Link("Help & Feedback", destination: VampProductLinks.support)
                }
                .buttonStyle(MacCapsuleButtonStyle(kind: .quiet))
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .macCard(radius: 20)
        }
    }
}

// MARK: - Shared settings pieces

/// `MONO TITLE` over one glass panel of rows, with optional fine print beneath.
struct MacSettingsGroup<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacMetaLabel(text: title)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .macCard(radius: 14)
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Title and optional detail on the left, one control on the right, 44 pt minimum.
struct MacSettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var systemImage: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

struct MacSettingsDivider: View {
    var body: some View {
        Divider().opacity(0.6).padding(.leading, 14)
    }
}

struct MacSettingsNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MacSettingsLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon.foregroundStyle(.secondary).frame(width: 18)
            configuration.title
        }
    }
}

/// Free minutes left today, as a glass meter.
struct MacUsageMeter: View {
    @ObservedObject var usage: DailyStreamingUsage

    var body: some View {
        let limit = DailyStreamingUsage.dailyLimitSeconds
        let minutesUsed = Int(usage.secondsUsedToday / 60)
        let minutesLeft = max(0, Int(limit / 60) - minutesUsed)
        let fraction = min(usage.secondsUsedToday / limit, 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                MacMetaLabel(text: "Today")
                Spacer()
                Text("\(min(minutesUsed, Int(limit / 60))) / \(Int(limit / 60)) min")
                    .font(MacBrand.mono(11.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.primary.opacity(0.55))
                        .frame(width: max(6, proxy.size.width * fraction))
                }
            }
            .frame(height: 6)
            HStack(spacing: 6) {
                MacStatusDot(tone: minutesLeft == 0 ? .attention : .live)
                Text(minutesLeft == 0 ? "Daily limit reached. Resets at midnight." : "\(minutesLeft) free minutes left today")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .macCard(radius: 12)
        .accessibilityElement(children: .combine)
    }
}

/// Trusted Macs, shared by Settings and the Home "Trusted" tab.
struct MacTrustedMacsList: View {
    @ObservedObject var model: ClientTrustedHostsViewModel
    @State private var peerPendingForget: TrustedPeer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.trustedHosts.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: 56)
                        .macCard(radius: 16)
                    Text("No trusted Macs yet")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Macs you connect to and approve will appear here. You can forget any of them at any time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .macCard(radius: 16)
            } else {
                MacSettingsGroup(title: "Trusted Macs · \(model.trustedHosts.count)") {
                    ForEach(Array(model.trustedHosts.enumerated()), id: \.element.id) { index, peer in
                        if index > 0 { MacSettingsDivider() }
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.displayName).font(.system(size: 13, weight: .semibold))
                                Text(String(peer.fingerprint.prefix(24)) + "…")
                                    .font(MacBrand.mono(11))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Forget…") { peerPendingForget = peer }
                                .buttonStyle(MacCapsuleButtonStyle(kind: .quiet))
                                .accessibilityLabel("Forget \(peer.displayName)")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                }
            }
            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    MacStatusDot(tone: .attention)
                    Text(error).font(.callout)
                }
            }
        }
        .task { await model.refresh() }
        .confirmationDialog(
            "Forget \(peerPendingForget?.displayName ?? "this Mac")?",
            isPresented: Binding(get: { peerPendingForget != nil }, set: { if !$0 { peerPendingForget = nil } }),
            presenting: peerPendingForget
        ) { peer in
            Button("Forget", role: .destructive) { Task { await model.forget(peer) } }
        } message: { _ in
            Text("This Mac will ask for approval again the next time you connect.")
        }
    }
}
