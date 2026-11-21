import SwiftUI
import SharedModels
import Diagnostics

/// App settings window (⌘,): stream quality, behavior toggles, trusted hosts,
/// diagnostics, and open-source release information.
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

    // Vamp Pro tab (store builds only).
    @StateObject private var unlock = StreamingUnlockStore()
    @StateObject private var usage = DailyStreamingUsage()
    @State private var showsPaywall = false
    @State private var peerPendingForget: TrustedPeer?

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
        // Sized to the tallest tab. At 440 the General tab overflowed into a
        // scroller and clipped the last row mid-toggle, which a macOS settings
        // pane should never do.
        .frame(width: 540, height: 580)
    }

    // MARK: - Diagnostics

    private var diagnosticsTab: some View {
        Form {
            if explainAvailable {
                Section {
                    if let explanation {
                        Text(explanation).font(.callout).textSelection(.enabled)
                        Button("Analyze again") { Task { await explain() } }.disabled(explaining)
                    } else {
                        Button {
                            Task { await explain() }
                        } label: {
                            Label(explaining ? "Analyzing…" : "Explain this log", systemImage: "sparkles")
                        }
                        .disabled(explaining || logItems.isEmpty)
                    }
                    Text(explainEngine.map { "Answered by \($0.label) · your log isn’t stored or shared." }
                         ?? "Runs privately — on-device or via Apple Private Cloud Compute; your log isn’t stored or shared.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("AI help") }
            }
            Section {
                if logItems.isEmpty {
                    Text("No events yet — connect to a Mac, then reopen this.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Group {
                            ForEach(logItems.reversed()) { item in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(item.severity.rawValue.uppercased())
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(logColor(item.severity))
                                    Text("\(item.category): \(item.message)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            } header: { Text("Connection log") }
        }
        .formStyle(.grouped)
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
        case .error: return .red
        case .warning: return .orange
        case .info, .debug: return .secondary
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Picker(selection: $environment.preferredQualityPreset) {
                    Text("Performance — lighter, 30 fps").tag(StreamQualityPreset.performance)
                    Text("Balanced — smooth everyday use, 30 fps").tag(StreamQualityPreset.balanced)
                    Text("Quality — sharp 4K, 60 fps").tag(StreamQualityPreset.quality)
                    if environment.isUltraQualityEntitled {
                        Text("Ultra — native resolution, 60 fps").tag(StreamQualityPreset.ultra)
                    }
                } label: {
                    Label("Stream quality", systemImage: "dial.high")
                }
                if let message = environment.ultraQualityAvailabilityMessage {
                    Label(message, systemImage: "sparkles")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Streaming")
            }

            Section {
                Toggle(isOn: $environment.showsStatsOverlay) {
                    Label("Show connection stats during sessions", systemImage: "waveform.path.ecg")
                }
                if MacDistributionPolicy.allowsRemoteChanges {
                    Toggle(isOn: $environment.prefersViewOnly) {
                        Label("View only (don't send mouse or keyboard)", systemImage: "eye")
                    }
                }
                Toggle(isOn: $environment.lowPowerModeEnabled) {
                    Label("Low power mode (reduce refresh rate)", systemImage: "leaf")
                }
                Toggle(isOn: menuBarItemEnabled) {
                    Label("Show a menu bar status item", systemImage: "menubar.arrow.up.rectangle")
                }
            } header: {
                Text("During Sessions")
            } footer: {
                Text("The session toolbar is always available in the window. The menu bar item adds connection status and a quick Disconnect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // App Store edition is View Only: file transfer and clipboard sync are website-edition features.
            if MacDistributionPolicy.allowsRemoteChanges {
                Section {
                    Toggle(isOn: $fileTransferEnabled) {
                        Label("File transfer", systemImage: "arrow.up.arrow.down.circle")
                    }
                    Toggle(isOn: $clipboardEnabled) {
                        Label("Clipboard sync", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("Features")
                } footer: {
                    Text("File transfer sends files to and receives files from the connected Mac. Clipboard sharing is manual: use Send Clipboard or Fetch Clipboard in the session tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent {
                    Text(environment.clientIdentity.displayName)
                } label: {
                    Label("Appears to hosts as", systemImage: "desktopcomputer")
                }
                LabeledContent {
                    Text(String(environment.clientIdentity.publicKeyFingerprint.prefix(16)) + "…")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                } label: {
                    Label("Key fingerprint", systemImage: "key")
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text("Your private key stays on this Mac. Your public identity and fingerprint are shared with hosts so they can verify a connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
        Group {
            if trustedHostsVM.trustedHosts.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("No trusted Macs yet")
                        .font(.headline)
                    Text("Macs you connect to and approve will appear here. You can forget any of them at any time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                Form {
                    Section {
                        ForEach(trustedHostsVM.trustedHosts, id: \.id) { peer in
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.displayName).font(.headline)
                                    Text(String(peer.fingerprint.prefix(24)) + "…")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button("Forget…") { peerPendingForget = peer }
                            }
                            .padding(.vertical, 3)
                        }
                    } header: {
                        Text("Trusted Macs")
                    }
                    if let error = trustedHostsVM.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .task { await trustedHostsVM.refresh() }
        .confirmationDialog(
            "Forget \(peerPendingForget?.displayName ?? "this Mac")?",
            isPresented: Binding(get: { peerPendingForget != nil }, set: { if !$0 { peerPendingForget = nil } }),
            presenting: peerPendingForget
        ) { peer in
            Button("Forget", role: .destructive) { Task { await trustedHostsVM.forget(peer) } }
        } message: { _ in
            Text("This Mac will ask for approval again the next time you connect.")
        }
    }

    // MARK: - Vamp Pro (store distribution)

    private var proTab: some View {
        VStack(spacing: 18) {
            Image(systemName: unlock.isEffectivelyUnlocked ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(unlock.isEffectivelyUnlocked ? Color.green : Color.secondary)
            Text(unlock.isEffectivelyUnlocked ? "Vamp Pro is unlocked" : "Stream without the daily limit")
                .font(.title3.weight(.semibold))
            Text(unlock.isEffectivelyUnlocked
                 ? "Vamp Control streams without a daily limit on this Mac."
                 : "Vamp Control streams for 15 minutes a day for free. Vamp Pro is a one-time purchase that removes the limit. No subscription.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if !unlock.isEffectivelyUnlocked {
                Button("View Vamp Pro…") { showsPaywall = true }
                    .controlSize(.large)
            }
            Button("Restore Purchase") { Task { await unlock.restore() } }
                .buttonStyle(.link)
            // The result used to be shown only inside the paywall sheet, which this button
            // never opens, so restoring looked like it did nothing.
            if let result = unlock.purchaseNotice ?? unlock.purchaseError {
                Text(result)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Link("Privacy Policy", destination: VampProductLinks.privacy)
                .buttonStyle(.link)
            Link("Help & Feedback", destination: VampProductLinks.support)
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .task {
            if unlock.product == nil { await unlock.refresh() }
        }
        .sheet(isPresented: $showsPaywall) {
            MacStreamingPaywallView(unlock: unlock, usage: usage, onDismiss: { showsPaywall = false })
        }
    }

    // MARK: - Open-source distribution

    private var openSourceTab: some View {
        VStack(spacing: 18) {
            proBadge(symbol: "checkmark.seal.fill", tint: .green)
            Text("Open source. All features included.")
                .font(.title3.weight(.semibold))
            Text("Vamp Control includes unlimited streaming and every quality preset supported by this Mac. There are no subscriptions or in-app purchases.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Link("Source, licenses, and release integrity",
                 destination: URL(string: "https://github.com/Mesutcydev/vamp-suite")!)
                .buttonStyle(.link)
            Link("Privacy Policy", destination: VampProductLinks.privacy)
                .buttonStyle(.link)
            Link("Help & Feedback", destination: VampProductLinks.support)
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private func proBadge(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 84, height: 84)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: MacBrand.cardCornerRadius, style: .continuous))
    }
}
