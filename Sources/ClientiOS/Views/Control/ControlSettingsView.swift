import SwiftUI
import SharedModels

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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        ControlSymbol().fill(ControlDesign.accent).frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Vamp Control").font(.title2.weight(.semibold)).tracking(-0.6)
                            Text("A little closer to your Mac.").font(.subheadline).foregroundStyle(ControlDesign.secondary)
                        }
                    }.padding(.vertical, 12)
                        .listRowBackground(Color.clear)
                }

                Section("Make it yours") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(ControlAppearance.allCases) { appearance in Text(appearance.title).tag(appearance) }
                    }
                    .accessibilityIdentifier("control.appearance")
                }

                Section {
                    Picker("Picture quality", selection: $environment.preferredQualityPreset) {
                        Text("Efficient").tag(StreamQualityPreset.performance)
                        Text("Balanced").tag(StreamQualityPreset.balanced)
                        Text("Sharp").tag(StreamQualityPreset.quality)
                        Text("Full resolution").tag(StreamQualityPreset.ultra)
                    }
                    Toggle("Low power mode", isOn: $environment.lowPowerModeEnabled)
                    Toggle("Connection stats", isOn: $environment.showsStatsOverlay)
                } header: { Text("Sync streaming") }
                footer: { Text("Balanced is a good place to start. Companion has picture controls inside its desktop session.") }

                Section {
                    Toggle("View only", isOn: $environment.prefersViewOnly)
                    Toggle("Clipboard sharing", isOn: $clipboardEnabled)
                    Toggle("File transfer", isOn: $fileTransferEnabled)
                    Toggle("Live Activity", isOn: $liveActivityEnabled)
                } header: { Text("Sync controls") }
                footer: { Text("Sharing happens when you ask. View Only hosts always keep input disabled.") }

                Section {
                    Toggle("App Lock", isOn: $appLock.isEnabled)
                    Text("Use biometrics or your device passcode to open Control.")
                        .font(.footnote).foregroundStyle(ControlDesign.secondary)
                    NavigationLink {
                        ControlTrustedMacsView(trusted: trusted, companion: companion)
                    } label: {
                        Label("Paired Macs", systemImage: "checkmark.shield")
                    }
                } header: { Text("Privacy & trust") }
                footer: { Text("Pairing belongs to you. Review or remove a Mac at any time.") }

                Section("On your Mac") {
                    Link(destination: VampProductLinks.syncDownload) { Label("Get Vamp Sync", systemImage: "arrow.down.circle") }
                    Link(destination: VampProductLinks.support) { Label("Help & feedback", systemImage: "bubble.left") }
                    Link(destination: VampProductLinks.privacy) { Label("Privacy", systemImage: "hand.raised") }
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                            .foregroundStyle(ControlDesign.secondary)
                    }
                } footer: {
                    VStack(spacing: 12) {
                        ControlWordmark()
                        Text("Made for the way you Mac.").font(.caption).foregroundStyle(ControlDesign.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
            .scrollContentBackground(.hidden)
            .background { ControlBackground() }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(appearance.colorScheme)
        .tint(ControlDesign.accent)
        .presentationDragIndicator(.visible)
    }
}

private struct ControlTrustedMacsView: View {
    @ObservedObject var trusted: ClientTrustedHostsViewModel
    @ObservedObject var companion: BeetCodeRemoteSessionViewModel
    @State private var forgetAction: (() -> Void)?
    @State private var showsForget = false

    var body: some View {
        List {
            if trusted.trustedHosts.isEmpty && companion.savedAssistants.isEmpty {
                ContentUnavailableView("No paired Macs yet", systemImage: "laptopcomputer",
                                       description: Text("Your Macs will appear here after you pair."))
                    .listRowBackground(Color.clear)
            }
            if !trusted.trustedHosts.isEmpty {
                Section("Vamp Sync") {
                    ForEach(trusted.trustedHosts) { host in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(host.displayName).font(.headline)
                            Text(host.fingerprint).font(.caption.monospaced())
                                .foregroundStyle(ControlDesign.secondary).textSelection(.enabled)
                            Button("Revoke trust", role: .destructive) {
                                forgetAction = { Task { await trusted.forget(host) } }
                                showsForget = true
                            }.frame(minHeight: 44)
                        }.padding(.vertical, 4)
                    }
                }
            }
            if !companion.savedAssistants.isEmpty {
                Section("Vamp Companion") {
                    ForEach(companion.savedAssistants) { saved in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(saved.displayName).font(.headline)
                            Text(saved.address).font(.footnote).foregroundStyle(ControlDesign.secondary)
                            Button("Forget Mac", role: .destructive) {
                                forgetAction = { companion.forget(saved) }
                                showsForget = true
                            }.frame(minHeight: 44)
                        }
                    }
                }
            }
            if let error = trusted.errorMessage { Text(error).foregroundStyle(ControlDesign.accent) }
        }
        .scrollContentBackground(.hidden).background { ControlBackground() }
        .navigationTitle("Paired Macs")
        .task { await trusted.refresh() }
        .confirmationDialog("Remove this Mac’s pairing?", isPresented: $showsForget, titleVisibility: .visible) {
            Button("Remove pairing", role: .destructive) { forgetAction?(); forgetAction = nil }
            Button("Cancel", role: .cancel) { forgetAction = nil }
        } message: { Text("You’ll need to pair again before reconnecting.") }
    }
}
