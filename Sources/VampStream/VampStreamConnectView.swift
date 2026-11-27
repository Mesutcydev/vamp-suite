import SwiftUI
import SharedModels
#if canImport(UIKit)
import UIKit
#endif

private var anonymizeStreamPreview: Bool {
    #if DEBUG
    ProcessInfo.processInfo.environment["VAMP_SCREENSHOT_PREVIEW"] == "1"
    #else
    false
    #endif
}

/// Macs are the home destination. Setup is a sheet, so returning users never navigate a form.
struct VampStreamConnectView: View {
    let environment: ClientAppEnvironment
    let onConnect: (DiscoveredHostRow) -> Void
    let onPairVampAssistant: () -> Void
    let onScanVampHost: () -> Void
    let pairedVampAssistants: [BeetCodeRemoteSessionViewModel.SavedAssistant]
    let vampAssistantAvailability: [String: BeetCodeRemoteSessionViewModel.Availability]
    let vampAssistantError: String?
    let vampSyncError: String?
    let busyHostName: String?
    let onAppStream: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    let onForgetVampAssistant: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    let onRetrySync: (() -> Void)?
    let onRetryAssistant: (() -> Void)?
    @ObservedObject private var hostsVM: HostsListViewModel
    @AppStorage(VampStreamHostSourceStore.key) private var hostSourceRaw = ""
    @AppStorage(VampStreamHomeCardStyleStore.key) private var cardStyleRaw = VampStreamHomeCardStyle.list.rawValue
    @AppStorage(VampStreamForgottenHosts.key) private var forgottenHostsRaw = ""
    @State private var showSettings = false
    @State private var showAddMac = false
    @State private var syncHostToForget: DiscoveredHostRow?
    @State private var pendingDestination: AddDestination?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass

    private enum AddDestination {
        case scan, assistant, address(DiscoveredHostRow)
    }
    private var source: VampStreamHostSource {
        VampStreamHostSource(rawValue: hostSourceRaw) ?? (pairedVampAssistants.isEmpty ? .sync : .both)
    }
    private var cardStyle: VampStreamHomeCardStyle { VampStreamHomeCardStyle(rawValue: cardStyleRaw) ?? .list }
    private var hosts: [DiscoveredHostRow] {
        guard source.showsSync else { return [] }
        let forgotten = VampStreamForgottenHosts.decode(forgottenHostsRaw)
        return hostsVM.displayHosts.filter {
            !$0.isTerminalOnlyHost && forgotten.isDisjoint(with: $0.forgetIdentities)
        }
    }
    private var assistants: [BeetCodeRemoteSessionViewModel.SavedAssistant] {
        source.showsAssistant ? pairedVampAssistants : []
    }
    private var hasMacs: Bool { !hosts.isEmpty || !assistants.isEmpty }

    init(
        environment: ClientAppEnvironment,
        onConnect: @escaping (DiscoveredHostRow) -> Void,
        onPairVampAssistant: @escaping () -> Void,
        onScanVampHost: @escaping () -> Void,
        pairedVampAssistants: [BeetCodeRemoteSessionViewModel.SavedAssistant],
        vampAssistantAvailability: [String: BeetCodeRemoteSessionViewModel.Availability],
        vampAssistantError: String?,
        vampSyncError: String? = nil,
        busyHostName: String? = nil,
        onAppStream: @escaping (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void,
        onForgetVampAssistant: @escaping (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void,
        onRetrySync: (() -> Void)? = nil,
        onRetryAssistant: (() -> Void)? = nil
    ) {
        self.environment = environment
        self.onConnect = onConnect
        self.onPairVampAssistant = onPairVampAssistant
        self.onScanVampHost = onScanVampHost
        self.pairedVampAssistants = pairedVampAssistants
        self.vampAssistantAvailability = vampAssistantAvailability
        self.vampAssistantError = vampAssistantError
        self.vampSyncError = vampSyncError
        self.busyHostName = busyHostName
        self.onAppStream = onAppStream
        self.onForgetVampAssistant = onForgetVampAssistant
        self.onRetrySync = onRetrySync
        self.onRetryAssistant = onRetryAssistant
        self.hostsVM = environment.sharedHostsViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            StreamHomeMasthead(onSettings: { showSettings = true })
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    StreamHomeIntroduction(hasMacs: hasMacs)
                    if hasMacs {
                        macList
                    } else {
                        StreamWorkspaceIllustration()
                        StreamFirstConnectionGuide()
                    }
                    if source.showsSync, let error = vampSyncError {
                        StreamConnectionNotice(message: error, retry: onRetrySync)
                    }
                    if source.showsAssistant, let error = vampAssistantError {
                        StreamConnectionNotice(message: error, retry: onRetryAssistant)
                    }
                    if source.showsSync {
                        StreamDiscoveryStatus(state: hostsVM.state, hasMacs: hasMacs) {
                            Task { await hostsVM.refresh() }
                        }
                    }
                }
                .frame(maxWidth: StreamDesign.maxWidth, alignment: .leading)
                .padding(.horizontal, StreamDesign.inset)
                .padding(.top, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .refreshable { if source.showsSync { await hostsVM.refresh() } }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StreamHomeFooter(hasMacs: hasMacs) { showAddMac = true }
        }
        .task(id: source) { if source.showsSync { await hostsVM.start() } }
        .sheet(isPresented: $showSettings) {
            VampStreamSettingsSheet(hostSource: Binding(get: { source }, set: { hostSourceRaw = $0.rawValue }))
        }
        .sheet(isPresented: $showAddMac, onDismiss: completeAddFlow) {
            StreamAddMacSheet(hostsVM: hostsVM, onScan: { queue(.scan) }, onAssistant: { queue(.assistant) },
                              onConnect: { queue(.address($0)) })
        }
        .confirmationDialog("Forget \(syncHostToForget?.title ?? "this Mac")?", isPresented: Binding(
            get: { syncHostToForget != nil }, set: { if !$0 { syncHostToForget = nil } }), titleVisibility: .visible) {
                Button("Forget Mac", role: .destructive) {
                    if let host = syncHostToForget { forget(host) }
                    syncHostToForget = nil
                }
                Button("Cancel", role: .cancel) { syncHostToForget = nil }
            } message: {
                Text("It disappears from this list, even while it is on your network. Scan its QR code or enter its address to add it again.")
            }
    }

    private var macList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                StreamEyebrow(title: "AVAILABLE WORKSPACES")
                Spacer()
                if sizeClass == .regular {
                    StreamIconButton(symbol: cardStyle.toggleSystemImage,
                                 label: cardStyle == .list ? "Show grid view" : "Show list view") {
                        cardStyleRaw = cardStyle.toggled.rawValue
                    }
                }
            }
            LazyVGrid(columns: cardStyle == .grid && !typeSize.isAccessibilitySize
                      ? [GridItem(.adaptive(minimum: 280), spacing: 14)] : [GridItem(.flexible())], spacing: 14) {
                ForEach(hosts) { host in
                    StreamMacCard(name: anonymizeStreamPreview ? "Your Mac" : host.title,
                                  detail: anonymizeStreamPreview ? "Private network" : host.subtitle, provider: VampProductIdentity.syncName,
                                  availability: isBusy(host) ? .busy : (host.isAvailable ? .online : .offline),
                                  address: anonymizeStreamPreview ? "Private network" : host.subtitle,
                                  onOpen: { onConnect(host) }, onForget: { syncHostToForget = host })
                }
                ForEach(assistants) { assistant in
                    StreamMacCard(name: anonymizeStreamPreview ? "Your Mac" : assistant.displayName,
                                  detail: assistant.connectionKind == .tailscale ? "Tailscale" : "Private network",
                                  provider: "Assistant / Companion", availability: availability(of: assistant),
                                  address: anonymizeStreamPreview ? "Private network" : assistant.address, onOpen: { onAppStream(assistant) },
                                  onForget: { onForgetVampAssistant(assistant) })
                }
            }
        }
    }

    private func availability(of assistant: BeetCodeRemoteSessionViewModel.SavedAssistant) -> VampHostAvailability {
        switch vampAssistantAvailability[assistant.address] ?? .checking {
        case .reachable: .online
        case .unavailable: .offline
        case .checking: .checking
        }
    }
    private func isBusy(_ host: DiscoveredHostRow) -> Bool {
        guard let busyHostName, !busyHostName.isEmpty else { return false }
        return host.title.localizedCaseInsensitiveCompare(busyHostName) == .orderedSame
    }
    private func queue(_ destination: AddDestination) {
        pendingDestination = destination
        showAddMac = false
    }
    private func completeAddFlow() {
        guard let destination = pendingDestination else { return }
        pendingDestination = nil
        switch destination {
        case .scan: onScanVampHost()
        case .assistant:
            if source == .sync { hostSourceRaw = VampStreamHostSource.both.rawValue }
            onPairVampAssistant()
        case .address(let host):
            if source == .assistant { hostSourceRaw = VampStreamHostSource.both.rawValue }
            onConnect(host)
        }
    }
    private func forget(_ host: DiscoveredHostRow) {
        let rows = hostsVM.hosts.filter { HostsListViewModel.dedupePhysicalHosts([$0, host]).count == 1 }
        var ids = host.forgetIdentities
        for row in rows + [host] {
            ids.formUnion(row.forgetIdentities)
            hostsVM.removeSavedHost(row.id)
        }
        forgottenHostsRaw = VampStreamForgottenHosts.forgetting(ids, in: forgottenHostsRaw)
    }
}

struct StreamHomeMasthead: View {
    let onSettings: () -> Void
    var body: some View {
        HStack {
            StreamWordmark()
            Spacer()
            StreamIconButton(symbol: "slider.horizontal.3", label: "Settings", action: onSettings)
        }
        .frame(maxWidth: StreamDesign.maxWidth)
        .padding(.horizontal, StreamDesign.inset)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }
}

struct StreamHomeIntroduction: View {
    let hasMacs: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var displaySize = 48
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StreamEyebrow(title: hasMacs ? "PICK UP WHERE YOU LEFT OFF" : "A SMALLER DISTANCE TO YOUR MAC")
            Text(hasMacs ? "Hello again.\nYour Mac awaits." : "Your Mac.\nWithin reach.")
                .font(typeSize.isAccessibilitySize ? .largeTitle.weight(.medium) : .system(size: displaySize, weight: .medium))
                .tracking(-2.1)
                .lineSpacing(-3)
                .foregroundStyle(StreamDesign.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(hasMacs ? "Choose a workspace. Open something great." : "The apps you love on your Mac,\nright here on your iPhone or iPad.")
                .font(.body)
                .foregroundStyle(StreamDesign.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StreamFirstConnectionGuide: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(StreamDesign.accent)
                .frame(width: 40, height: 44)
            VStack(alignment: .leading, spacing: 7) {
                Text("One Mac. A new point of view.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StreamDesign.text)
                Text("Open Vamp Sync on your Mac. Then scan its pairing code to bring your apps here.")
                    .font(.footnote)
                    .foregroundStyle(StreamDesign.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .streamGlass()
    }
}

struct StreamHomeFooter: View {
    let hasMacs: Bool
    let onAdd: () -> Void
    var body: some View {
        VStack(spacing: 15) {
            StreamPrimaryButton(title: hasMacs ? "Add a Mac" : "Connect a Mac", symbol: hasMacs ? "plus" : "arrow.up.right", action: onAdd)
            Label("Your Mac. Your private connection.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(StreamDesign.secondary)
        }
        .frame(maxWidth: 540)
        .padding(.horizontal, StreamDesign.inset)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [StreamDesign.ink.opacity(0), Color.dynamic(light: 0xF7F0EB, dark: 0x101116).opacity(0.92)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .bottom)
        }
    }
}

struct StreamMacCard: View {
    let name: String
    let detail: String
    let provider: String
    let availability: VampHostAvailability
    let address: String
    let onOpen: () -> Void
    let onForget: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 30, weight: .ultraLight))
                    .foregroundStyle(StreamDesign.text)
                    .frame(width: 60, height: 54)
                    .background(StreamDesign.text.opacity(0.045), in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityHidden(true)
                Spacer()
                VampHostStatusLabel(availability: availability).padding(.top, 10)
                Menu {
                    Button("Copy address", systemImage: "doc.on.doc") { UIPasteboard.general.string = address }
                    Button("Forget this Mac", systemImage: "trash", role: .destructive, action: onForget)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.medium))
                        .foregroundStyle(StreamDesign.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More actions for \(name)")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.title3.weight(.medium)).tracking(-0.5).foregroundStyle(StreamDesign.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(provider).font(.caption).foregroundStyle(StreamDesign.accent)
                Text(detail).font(.caption).foregroundStyle(StreamDesign.secondary).lineLimit(2)
            }
            Button(action: onOpen) {
                HStack {
                    Text("Browse apps").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(StreamDesign.text)
                .padding(.horizontal, 17)
                .frame(minHeight: 48)
                .background(StreamDesign.text.opacity(0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(StreamDesign.line, lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(StreamPressStyle())
            .accessibilityHint("Open applications on \(name)")
        }
        .padding(22)
        .streamGlass(elevated: true)
        .accessibilityElement(children: .contain)
    }
}

private struct StreamDiscoveryStatus: View {
    let state: HostsListViewState
    let hasMacs: Bool
    let onRefresh: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.footnote).padding(.top, 2).accessibilityHidden(true)
            Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise").font(.footnote.weight(.medium)).frame(width: 44, height: 44)
            }
            .buttonStyle(StreamPressStyle())
            .accessibilityLabel("Look for Macs again")
        }
        .foregroundStyle(StreamDesign.secondary)
        .padding(.horizontal, 4)
    }
    private var symbol: String {
        if case .localNetworkIssue = state { return "wifi.exclamationmark" }
        return "dot.radiowaves.left.and.right"
    }
    private var message: String {
        switch state {
        case .loading: "Looking for Macs on your network…"
        case .localNetworkIssue(let message): message
        case .unavailable: "Check that your Mac is awake and Sync is running."
        case .empty, .available: hasMacs ? "Pull down to refresh your Macs." : "Macs on the same network appear here. You can also pair over private Tailscale."
        }
    }
}

struct StreamConnectionNotice: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(VampStreamHostBusy.isHostBusy(message) ? "Mac is in use" : "Connection needs attention", systemImage: "exclamationmark.circle")
                .font(.subheadline.weight(.semibold)).foregroundStyle(StreamDesign.text)
            Text(VampStreamHostBusy.isHostBusy(message) ? VampStreamHostBusy.detail : message)
                .font(.footnote).foregroundStyle(StreamDesign.secondary).fixedSize(horizontal: false, vertical: true)
            if let retry { Button("Try again", action: retry).font(.subheadline.weight(.semibold)).frame(minHeight: 44) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(22).streamGlass()
    }
}

private struct StreamAddMacSheet: View {
    @ObservedObject var hostsVM: HostsListViewModel
    let onScan: () -> Void
    let onAssistant: () -> Void
    let onConnect: (DiscoveredHostRow) -> Void
    @State private var address = ""
    @State private var manualError: String?
    @State private var showsAddress = false
    @FocusState private var addressFocused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 12) {
                        StreamEyebrow(title: "A NEW CONNECTION")
                        Text("Bring your\nMac along.")
                            .font(.largeTitle.weight(.medium)).tracking(-1.5).foregroundStyle(StreamDesign.text)
                        Text("Pair once. Your Mac apps are always close.")
                            .font(.body).foregroundStyle(StreamDesign.secondary)
                    }
                    StreamPairingSteps()
                    StreamPrimaryButton(title: "Scan pairing code", symbol: "qrcode.viewfinder", action: onScan)
                        .accessibilityHint("Scan the code shown by Sync, Assistant, or Companion on your Mac")
                    DisclosureGroup("Enter an address instead", isExpanded: $showsAddress) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Use the private address shown by Sync on your Mac, including its port.")
                                .font(.footnote).foregroundStyle(StreamDesign.secondary)
                            TextField("Mac address", text: $address, prompt: Text("192.168.1.10:9473"))
                                .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .keyboardType(.URL).textContentType(.URL).submitLabel(.go)
                                .focused($addressFocused)
                                .padding(16).streamGlass(radius: 16)
                                .onSubmit(connectByAddress)
                            if let manualError {
                                Label(manualError, systemImage: "exclamationmark.circle")
                                    .font(.footnote).foregroundStyle(StreamDesign.accent).fixedSize(horizontal: false, vertical: true)
                            }
                            StreamPrimaryButton(title: "Connect to Mac", symbol: "arrow.right", isDisabled: address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                                action: connectByAddress)
                        }
                        .padding(.top, 16)
                    }
                    .font(.subheadline.weight(.medium)).tint(StreamDesign.secondary)
                    Rectangle().fill(StreamDesign.line).frame(height: 0.5)
                    StreamPairingOtherOptions(onAssistant: onAssistant)
                }
                .frame(maxWidth: 540, alignment: .leading)
                .padding(24).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { VampStreamEnvironmentBackdrop() }
            .navigationTitle("Add a Mac").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(StreamDesign.text) }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { addressFocused = false }
                }
            }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
    }
    private func connectByAddress() {
        guard let host = hostsVM.addManualHost(address: address) else {
            manualError = VampStreamHomeCopy.addressError
            return
        }
        addressFocused = false
        manualError = nil
        onConnect(host)
    }
}

private struct StreamPairingSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StreamSetupStep(number: "01", title: "Open Sync on your Mac", detail: "Use Vamp Sync from the Mac App Store or the website.")
            StreamSetupStep(number: "02", title: "Find your pairing code", detail: "In Sync, open pairing. Keep your Mac awake and on your LAN or private Tailscale network.")
            StreamSetupStep(number: "03", title: "Scan. Approve. You're home.", detail: "Compare the device fingerprint and approve this device on your Mac.")
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading).streamGlass()
    }
}

private struct StreamSetupStep: View {
    let number: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(.caption.monospaced()).foregroundStyle(StreamDesign.accent).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(StreamDesign.text)
                Text(detail).font(.footnote).foregroundStyle(StreamDesign.secondary).lineSpacing(2)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StreamPairingOtherOptions: View {
    let onAssistant: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Link(destination: VampProductLinks.syncDownload) {
                Label("Get Sync for your Mac", systemImage: "arrow.down.to.line")
                    .frame(minHeight: 44)
            }
            Button(action: onAssistant) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Using Assistant or Companion?").foregroundStyle(StreamDesign.text)
                        Text("Connect with a private address and code.").font(.footnote).foregroundStyle(StreamDesign.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                .frame(minHeight: 48).contentShape(Rectangle())
            }
            .buttonStyle(StreamPressStyle())
        }
        .font(.subheadline.weight(.medium)).tint(StreamDesign.accent)
    }
}

// Compatibility action used by the Assistant's locked-Mac surface.
struct VampAssistantActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    var body: some View { StreamPrimaryButton(title: title, symbol: systemImage, action: action) }
}

/// Full-screen connecting state.
struct VampStreamConnectingView: View {
    let name: String
    var detail: String = "Contacting your Mac over the private network."
    /// This device's fingerprint, shown while the Mac may be asking for approval. Vamp Sync's
    /// approval card tells the user to compare against "the one shown on the device" — without
    /// this there was nothing on the device to compare with.
    var fingerprint: String? = nil
    /// Pairing is paused for the user to verify the Mac (or accept an older Vamp Sync).
    var hostConfirmation: PendingHostConfirmation? = nil
    var usesOlderSync = false
    var onConfirmHost: () -> Void = {}
    var onCancel: () -> Void

    private var isOlderSyncPrompt: Bool { hostConfirmation != nil && hostConfirmation?.fingerprint == nil }

    var body: some View {
        VStack(spacing: 16) {
            StreamBrandMark().frame(width: 52, height: 52).padding(.bottom, 12)
            if hostConfirmation == nil {
                ProgressView()
                    .tint(StreamDesign.accent)
                    .controlSize(.large)
                Text("Connecting to \(name)…")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(PR.fg)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(StreamReading.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: isOlderSyncPrompt ? "exclamationmark.shield" : "checkmark.shield")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(isOlderSyncPrompt ? Color.orange : StreamDesign.accent)
                Text(isOlderSyncPrompt ? "Older \(VampProductIdentity.syncName) on \(name)" : "Is this your Mac?")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(PR.fg)
                    .multilineTextAlignment(.center)
                Text(isOlderSyncPrompt
                     ? "It can’t prove its identity before pairing. Update \(VampProductIdentity.syncName) on the Mac, or connect anyway."
                     : "Compare this with the Host fingerprint in \(VampProductIdentity.syncName) on \(name). Continue only if they match.")
                    .font(.subheadline)
                    .foregroundStyle(StreamReading.secondary)
                    .multilineTextAlignment(.center)
            }
            if let hostFingerprint = hostConfirmation?.fingerprint {
                fingerprintBlock(title: "This Mac's fingerprint", value: hostFingerprint)
            } else if hostConfirmation == nil, let fingerprint, !fingerprint.isEmpty {
                fingerprintBlock(title: "This device's fingerprint", value: fingerprint)
            }
            if usesOlderSync, hostConfirmation == nil {
                Text(ClientSessionCoordinator.legacyHostNotice)
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("stream.olderSyncNotice")
            }
            if hostConfirmation != nil {
                VampGlassActionButton(title: isOlderSyncPrompt ? "Connect anyway" : "It matches",
                                      isProminent: true, action: onConfirmHost)
                    .accessibilityIdentifier("stream.confirmHost")
            }
            VampGlassActionButton(title: "Cancel", action: onCancel)
        }
        .padding(28)
        .streamGlass(elevated: true)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fingerprintBlock(title: LocalizedStringKey, value: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StreamReading.secondary)
            Text(VampStreamFingerprint.formatted(value))
                .font(.caption2.monospaced().weight(.medium))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(PR.fg)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// Centered message + single action (unsupported host, errors).
struct VampStreamMessageView: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String
    var action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(StreamDesign.accent)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(PR.fg)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(StreamReading.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            VampGlassActionButton(
                title: LocalizedStringKey(actionTitle),
                isProminent: true,
                action: action
            )
            .padding(.top, 6)
        }
        .padding(28)
        .streamGlass(elevated: true)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Same grouping as Vamp Sync's approval card (8-character groups, four per line), so the two
/// read identically side by side. Visual only: the accessibility value keeps the raw string.
enum VampStreamFingerprint {
    static func formatted(_ fingerprint: String) -> String {
        let characters = Array(fingerprint)
        let groups = stride(from: 0, to: characters.count, by: 8).map {
            String(characters[$0..<min($0 + 8, characters.count)])
        }
        return stride(from: 0, to: groups.count, by: 4).map {
            groups[$0..<min($0 + 4, groups.count)].joined(separator: " ")
        }.joined(separator: "\n")
    }
}

extension DiscoveredHostRow {
    /// The stable identities a forgotten Mac is remembered by.
    var forgetIdentities: Set<String> {
        VampStreamForgottenHosts.identities(
            hostID: endpoint.metadata.hostID,
            fingerprint: endpoint.metadata.publicKeyFingerprint)
    }
}
