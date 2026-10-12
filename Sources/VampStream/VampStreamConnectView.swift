import SwiftUI

private var anonymizeStreamPreview: Bool {
    #if DEBUG
    ProcessInfo.processInfo.environment["VAMP_SCREENSHOT_PREVIEW"] == "1"
    #else
    false
    #endif
}

/// The first screen in Vamp Stream. Onboarding picks Vamp Sync, Vamp Assistant,
/// or both; the connect home then shows only that host. Remote Control remains
/// Assistant-only and is not the default destination in this build.
struct VampStreamConnectView: View {
    enum ConnectionDestination: String, CaseIterable, Identifiable {
        case remoteControl
        case appStream

        var id: String { rawValue }

        var title: String {
            switch self {
            case .remoteControl: return "Remote Control"
            case .appStream: return "App Stream"
            }
        }

        var icon: String {
            switch self {
            case .remoteControl: return "display"
            case .appStream: return "macwindow"
            }
        }
    }

    let environment: ClientAppEnvironment
    let onConnect: (DiscoveredHostRow) -> Void
    let onPairVampAssistant: () -> Void
    let onScanVampHost: () -> Void
    let pairedVampAssistants: [BeetCodeRemoteSessionViewModel.SavedAssistant]
    let vampAssistantAvailability: [String: BeetCodeRemoteSessionViewModel.Availability]
    let vampAssistantError: String?
    let onRemoteControl: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    let onAppStream: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    let onForgetVampAssistant: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    @ObservedObject private var hostsVM: HostsListViewModel
    @AppStorage(VampStreamHostSourceStore.key) private var hostSourceRaw = ""
    @AppStorage(VampStreamHomeCardStyleStore.key) private var homeCardStyleRaw = VampStreamHomeCardStyle.list.rawValue
    @State private var showHostSourcePicker = false

    private var homeCardStyle: VampStreamHomeCardStyle {
        VampStreamHomeCardStyle(rawValue: homeCardStyleRaw) ?? .list
    }

    private var hostSource: VampStreamHostSource? {
        if anonymizeStreamPreview { return .both }
        return VampStreamHostSource(rawValue: hostSourceRaw)
    }

    private var legacyHostsForAppStream: [DiscoveredHostRow] {
        hostsVM.displayHosts.filter { !$0.isTerminalOnlyHost }
    }

    init(
        environment: ClientAppEnvironment,
        onConnect: @escaping (DiscoveredHostRow) -> Void,
        onPairVampAssistant: @escaping () -> Void,
        onScanVampHost: @escaping () -> Void,
        pairedVampAssistants: [BeetCodeRemoteSessionViewModel.SavedAssistant],
        vampAssistantAvailability: [String: BeetCodeRemoteSessionViewModel.Availability],
        vampAssistantError: String?,
        onRemoteControl: @escaping (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void,
        onAppStream: @escaping (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void,
        onForgetVampAssistant: @escaping (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    ) {
        self.environment = environment
        self.onConnect = onConnect
        self.onPairVampAssistant = onPairVampAssistant
        self.onScanVampHost = onScanVampHost
        self.pairedVampAssistants = pairedVampAssistants
        self.vampAssistantAvailability = vampAssistantAvailability
        self.vampAssistantError = vampAssistantError
        self.onRemoteControl = onRemoteControl
        self.onAppStream = onAppStream
        self.onForgetVampAssistant = onForgetVampAssistant
        self.hostsVM = environment.sharedHostsViewModel
    }

    var body: some View {
        Group {
            if let hostSource {
                VStack(alignment: .leading, spacing: 0) {
                    VampStreamConnectHeader(
                        source: hostSource,
                        cardStyle: homeCardStyle,
                        onToggleCardStyle: {
                            homeCardStyleRaw = homeCardStyle.toggled.rawValue
                        }
                    ) {
                        showHostSourcePicker = true
                    }
                    VampAppStreamSection(
                        source: hostSource,
                        cardStyle: homeCardStyle,
                        pairedAssistants: pairedVampAssistants,
                        availability: vampAssistantAvailability,
                        errorMessage: vampAssistantError,
                        legacyHosts: legacyHostsForAppStream,
                        hostsVM: hostsVM,
                        onPair: onPairVampAssistant,
                        onAppStream: onAppStream,
                        onForget: onForgetVampAssistant,
                        onScan: onScanVampHost,
                        onConnect: onConnect)
                }
            } else {
                VampStreamHostSourceOnboarding { source in
                    hostSourceRaw = source.rawValue
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { VampStreamHomeAtmosphere() }
        .task(id: hostSource) {
            if hostSource?.showsSync == true {
                await hostsVM.start()
            }
        }
        .sheet(isPresented: $showHostSourcePicker) {
            if let hostSource {
                VampStreamHostSourcePickerSheet(current: hostSource) { source in
                    hostSourceRaw = source.rawValue
                }
            }
        }
    }
}

private struct VampStreamConnectHeader: View {
    let source: VampStreamHostSource
    let cardStyle: VampStreamHomeCardStyle
    let onToggleCardStyle: () -> Void
    let onChangeHost: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(VampStreamHomeCopy.headerTitleLead)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(PR.fg)
                    Text(VampStreamHomeCopy.headerTitleTrail)
                        .font(.title3.weight(.regular))
                        .foregroundStyle(PR.fg2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(VampStreamHomeCopy.headerTitle)

                Text(VampStreamHomeCopy.headerDetail(for: source))
                    .font(.footnote)
                    .foregroundStyle(PR.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: onToggleCardStyle) {
                        Image(systemName: cardStyle.toggleSystemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PR.fg)
                            .frame(width: 28, height: 28)
                            .prGlassSurface(in: Circle(), isInteractive: true)
                    }
                    .buttonStyle(PRGlassPressButtonStyle())
                    .accessibilityLabel(
                        Text(cardStyle == .grid ? VampStreamHomeCopy.showList : VampStreamHomeCopy.showGrid)
                    )
                    Button(action: onChangeHost) {
                        Text(VampStreamHomeCopy.changeHost)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PR.fg)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .prGlassSurface(in: Capsule(style: .continuous), isInteractive: true)
                    }
                    .buttonStyle(PRGlassPressButtonStyle())
                    .accessibilityHint("Choose Sync, Assistant or Companion, or both host groups")
                }
                VampStreamVersionBadge()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

private struct VampStreamVersionBadge: View {
    private let version: String
    private let build: String

    init(bundle: Bundle = .main) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        Text(verbatim: "Version \(version) (\(build))")
            .font(.caption2.monospaced())
            .foregroundStyle(PR.dim)
            .accessibilityLabel("Version \(version), build \(build)")
    }
}

private struct VampStreamConnectionDestinationPicker: View {
    @Binding var selection: VampStreamConnectView.ConnectionDestination

    var body: some View {
        Picker("Experience", selection: $selection) {
            ForEach(VampStreamConnectView.ConnectionDestination.allCases) { destination in
                Label(destination.title, systemImage: destination.icon)
                    .tag(destination)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Connection experience")
    }
}

private struct VampAssistantRemoteControlSection: View {
    let pairedAssistants: [BeetCodeRemoteSessionViewModel.SavedAssistant]
    let availability: [String: BeetCodeRemoteSessionViewModel.Availability]
    let errorMessage: String?
    let onPair: () -> Void
    let onRemoteControl: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    let onForget: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                VampAssistantSourceIntro(
                    title: "Remote Control",
                    detail: "Vamp Assistant is the only source for full Mac control. Vamp Sync entries stay out of this flow.",
                    onPair: onPair,
                    hasSavedAssistants: !pairedAssistants.isEmpty)

                if let errorMessage {
                    VampStreamConnectionError(message: errorMessage)
                }

                if pairedAssistants.isEmpty {
                    VampStreamEmptyState(
                        icon: "macwindow.badge.plus",
                        title: "No Assistant Macs yet",
                        message: "Pair Vamp Assistant to control a Mac. App Stream is a separate experience and never adds a host control button here.")
                } else {
                    Text("SAVED ASSISTANT MACS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PR.dim)
                        .padding(.top, 4)
                    ForEach(pairedAssistants) { assistant in
                        VampAssistantMacCard(
                            assistant: assistant,
                            availability: availability[assistant.address] ?? .checking,
                            onRemoteControl: { onRemoteControl(assistant) },
                            onAppStream: {},
                            showsRemoteControl: true,
                            showsAppStream: false,
                            onForget: { onForget(assistant) })
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
    }
}

private struct VampAppStreamSection: View {
    let source: VampStreamHostSource
    let cardStyle: VampStreamHomeCardStyle
    let pairedAssistants: [BeetCodeRemoteSessionViewModel.SavedAssistant]
    let availability: [String: BeetCodeRemoteSessionViewModel.Availability]
    let errorMessage: String?
    let legacyHosts: [DiscoveredHostRow]
    @ObservedObject var hostsVM: HostsListViewModel
    let onPair: () -> Void
    let onAppStream: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    let onForget: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    let onScan: () -> Void
    let onConnect: (DiscoveredHostRow) -> Void


    @State private var manualAddress = ""
    @State private var manualError: String?
    @AppStorage(VampStreamSyncPromoStore.installedKey) private var syncInstalled = false
    @State private var promoDismissedThisSession = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(
                    VampStreamHomeLayout.sections(
                        source: source,
                        hasSyncHosts: !legacyHosts.isEmpty,
                        hasAssistants: !pairedAssistants.isEmpty,
                        hasAssistantError: errorMessage != nil,
                        showsSyncPromo: !syncInstalled && !promoDismissedThisSession
                    )
                ) { section in
                    homeSection(section)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
            .animation(.easeOut(duration: 0.2), value: cardStyle)
        }
        .refreshable {
            if source.showsSync {
                await hostsVM.refresh()
            }
        }
    }

    @ViewBuilder
    private func homeSection(_ section: VampStreamHomeLayout.Section) -> some View {
        switch section {
        case .syncHostCard:
            VampSyncConnectCard(
                isPaired: legacyHosts.contains(where: \.isSaved),
                manualAddress: $manualAddress,
                manualError: $manualError,
                onScan: onScan,
                onConnectByAddress: connectByAddress)
        case .syncMacs:
            VStack(alignment: .leading, spacing: 12) {
                VampStreamSectionLabel(title: VampStreamHomeCopy.syncMacsHeading)
                if cardStyle == .grid {
                    LazyVGrid(columns: homeGridColumns, spacing: 12) {
                        ForEach(visibleSyncHosts) { host in
                            VampHostMacTile(host: host, onConnect: { onConnect(host) })
                        }
                    }
                } else {
                    ForEach(visibleSyncHosts) { host in
                        VampHostMacCard(host: host, onConnect: { onConnect(host) })
                    }
                }
            }
        case .syncEmptyHint:
            VampSyncEmptyHint(hostsVM: hostsVM)
        case .syncPromo:
            VampStreamSyncPromoCard(
                onConfirmInstalled: { syncInstalled = true },
                onDismissUntilRelaunch: { promoDismissedThisSession = true }
            )
        case .assistantError:
            if let errorMessage {
                VampStreamConnectionError(message: errorMessage)
            }
        case .assistantHostCard:
            VampAssistantFollowOnCard(
                onPair: onPair,
                hasSavedAssistants: !pairedAssistants.isEmpty)
        case .assistantMacs:
            VStack(alignment: .leading, spacing: 12) {
                VampStreamSectionLabel(title: VampStreamHomeCopy.assistantMacsHeading)
                if cardStyle == .grid {
                    LazyVGrid(columns: homeGridColumns, spacing: 12) {
                        ForEach(pairedAssistants) { assistant in
                            VampAssistantMacTile(
                                assistant: assistant,
                                availability: availability[assistant.address] ?? .checking,
                                onAppStream: { onAppStream(assistant) },
                                onForget: { onForget(assistant) })
                        }
                    }
                } else {
                    ForEach(pairedAssistants) { assistant in
                        VampAssistantMacCard(
                            assistant: assistant,
                            availability: availability[assistant.address] ?? .checking,
                            onRemoteControl: {},
                            onAppStream: { onAppStream(assistant) },
                            showsRemoteControl: false,
                            showsAppStream: true,
                            onForget: { onForget(assistant) })
                    }
                }
            }
        }
    }

    private var visibleSyncHosts: [DiscoveredHostRow] {
        anonymizeStreamPreview ? Array(legacyHosts.prefix(1)) : legacyHosts
    }

    private var homeGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 146, maximum: 220), spacing: 12)]
    }

    private func connectByAddress() {
        guard let host = hostsVM.addManualHost(address: manualAddress) else {
            manualError = VampStreamHomeCopy.addressError
            return
        }
        manualError = nil
        onConnect(host)
    }
}

private struct VampStreamSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PR.dim)
            .padding(.top, 4)
    }
}

private struct VampSyncConnectCard: View {
    let isPaired: Bool
    @Binding var manualAddress: String
    @Binding var manualError: String?
    let onScan: () -> Void
    let onConnectByAddress: () -> Void

    @AppStorage(VampStreamSyncConnectCardStore.collapsedKey) private var collapsePreference = false

    private var isCollapsed: Bool {
        VampStreamSyncConnectCardStore.showsCollapsed(isPaired: isPaired, preference: collapsePreference)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCollapsed ? 0 : 14) {
            HStack(alignment: .top, spacing: 12) {
                syncMark
                VStack(alignment: .leading, spacing: 4) {
                    Text(VampStreamHomeCopy.syncTitle)
                        .font(.headline)
                        .foregroundStyle(PR.fg)
                    Text(isCollapsed ? VampStreamHomeCopy.syncConnectCollapsedDetail : VampStreamHomeCopy.syncDetail)
                        .font(.footnote)
                        .foregroundStyle(PR.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(isCollapsed ? 1 : nil)
                }
                Spacer(minLength: 8)
                scanChip
                if isPaired {
                    collapseButton
                }
            }

            if !isCollapsed {
                addressFields
            }
        }
        .padding(isCollapsed ? 12 : 16)
        .vampHomeLiveGlass(
            in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous),
            phaseOffset: 0.2
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(VampStreamHomeCopy.syncTitle))
        .animation(.easeOut(duration: 0.2), value: isCollapsed)
    }

    private var syncMark: some View {
        VampStreamWindowFangsMark()
            .fill(PR.fg, style: FillStyle(eoFill: true))
            .frame(width: 22, height: 24)
            .frame(width: 38, height: 38)
            .prGlassSurface(in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityHidden(true)
    }

    private var scanChip: some View {
        Button(action: onScan) {
            Label("Scan QR", systemImage: "qrcode.viewfinder")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .foregroundStyle(PR.fg)
        .vampHomeLiveGlass(in: Capsule(style: .continuous), phaseOffset: 0.6)
        .vampHomeLivePulse(isActive: !isCollapsed, period: 2.6)
        .accessibilityLabel(Text(VampStreamHomeCopy.scanSync))
        .accessibilityHint(Text(VampStreamHomeCopy.scanSyncHint))
    }

    private var collapseButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                collapsePreference.toggle()
            }
        } label: {
            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PR.dim)
                .frame(width: 28, height: 28)
                .prGlassSurface(in: Circle(), isInteractive: true)
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .accessibilityLabel(
            Text(isCollapsed ? VampStreamHomeCopy.syncConnectExpand : VampStreamHomeCopy.syncConnectCollapse)
        )
    }

    private var addressFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(VampStreamHomeCopy.orConnectByAddress)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PR.fg2)
            TextField(
                "",
                text: $manualAddress,
                prompt: Text(VampStreamHomeCopy.addressPlaceholder)
                    .foregroundStyle(PR.fg.opacity(0.82))
            )
                .font(.subheadline)
                .foregroundStyle(PR.fg)
                .tint(PR.fg)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .vampHomeLiveGlass(
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                    phaseOffset: 1.1
                )
                .accessibilityLabel(Text(VampStreamHomeCopy.addressPlaceholder))
            VampGlassActionButton(
                title: LocalizedStringKey(VampStreamHomeCopy.connectByAddress),
                systemImage: "link",
                isDisabled: manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                action: onConnectByAddress
            )
            if let manualError {
                Text(manualError)
                    .font(.footnote)
                    .foregroundStyle(PR.fg)
            }
        }
    }
}

private struct VampSyncEmptyHint: View {
    @ObservedObject var hostsVM: HostsListViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(PR.fg)
                .frame(width: 38, height: 38)
                .prGlassSurface(in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .vampHomeLivePulse(isActive: isLoading, period: 1.25, trough: 0.55)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PR.fg)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(PR.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                if !isLoading {
                    Button {
                        Task { await hostsVM.refresh() }
                    } label: {
                        Text(VampStreamHomeCopy.retryDiscovery)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vampHomeLiveGlass(
            in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous),
            phaseOffset: 0.9
        )
        .accessibilityElement(children: .combine)
    }

    private var isLoading: Bool {
        if case .loading = hostsVM.state { return true }
        return false
    }

    private var icon: String {
        if isLoading { return "hourglass" }
        return hostsVM.hasLocalNetworkIssue ? "wifi.exclamationmark" : "macbook.and.iphone"
    }

    private var title: String {
        isLoading ? VampStreamHomeCopy.lookingForSync : VampStreamHomeCopy.noSyncFound
    }

    private var message: String {
        switch hostsVM.state {
        case .loading:
            return VampStreamHomeCopy.syncNetworkHint
        case .localNetworkIssue(let message):
            return message
        case .unavailable:
            return VampStreamHomeCopy.unavailableSync
        case .empty, .available:
            return VampStreamHomeCopy.syncNetworkHint
        }
    }
}

private struct VampAssistantFollowOnCard: View {
    let onPair: () -> Void
    let hasSavedAssistants: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles.tv")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(PR.fg)
                    .frame(width: 38, height: 38)
                    .prGlassSurface(in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(VampStreamHomeCopy.assistantTitle)
                        .font(.headline)
                        .foregroundStyle(PR.fg)
                    Text(VampStreamHomeCopy.assistantDetail)
                        .font(.footnote)
                        .foregroundStyle(PR.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VampAssistantActionButton(
                title: LocalizedStringKey(
                    VampStreamHomeCopy.pairAssistantTitle(hasSavedAssistants: hasSavedAssistants)
                ),
                systemImage: "plus",
                action: onPair
            )
            .accessibilityHint(Text(VampStreamHomeCopy.pairAssistantHint))
        }
        .padding(16)
        .vampHomeLiveGlass(
            in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous),
            phaseOffset: 1.7
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(VampStreamHomeCopy.assistantTitle))
    }
}

private struct VampAssistantSourceIntro: View {
    let title: String
    let detail: String
    let onPair: () -> Void
    let hasSavedAssistants: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles.tv")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(PR.fg)
                    .frame(width: 38, height: 38)
                    .prGlassSurface(in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(PR.fg)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(PR.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VampGlassActionButton(
                title: LocalizedStringKey(
                    VampStreamHomeCopy.pairAssistantTitle(hasSavedAssistants: hasSavedAssistants)
                ),
                systemImage: "plus",
                isProminent: true,
                action: onPair
            )
            .accessibilityHint(Text(VampStreamHomeCopy.pairAssistantHint))
        }
        .padding(16)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
    }
}

private struct VampAssistantMacCard: View {
    let assistant: BeetCodeRemoteSessionViewModel.SavedAssistant
    let availability: BeetCodeRemoteSessionViewModel.Availability
    let onRemoteControl: () -> Void
    let onAppStream: () -> Void
    let showsRemoteControl: Bool
    let showsAppStream: Bool
    let onForget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: "macbook")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PR.fg)
                    .frame(width: 38, height: 38)
                    .prGlassSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        if assistant.hasGenericDisplayName {
                            switch assistant.connectionKind {
                            case .localNetwork:
                                Text("Local Mac")
                            case .tailscale:
                                Text("Tailscale Mac")
                            case .privateNetwork:
                                Text("Private Mac")
                            }
                        } else {
                            Text(assistant.displayName)
                        }
                        Text("Vamp Assistant")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PR.dim)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(PR.fg.opacity(0.08), in: Capsule())
                    }
                    .font(.headline)
                    .foregroundStyle(PR.fg)
                    .lineLimit(1)
                    Text(assistant.address)
                        .font(.caption.monospaced())
                        .foregroundStyle(PR.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VampAssistantAvailabilityBadge(availability: availability)
                Menu {
                    Button("Forget this Mac", role: .destructive, action: onForget)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(PR.dim)
                }
                .accessibilityLabel("More actions for \(assistant.displayName)")
            }

            HStack(spacing: 10) {
                if showsRemoteControl {
                    VampAssistantActionButton(
                        title: "Control Mac",
                        systemImage: "display",
                        action: onRemoteControl)
                }
                if showsAppStream {
                    VampAssistantActionButton(
                        title: "Stream an app",
                        systemImage: "macwindow.badge.plus",
                        action: onAppStream)
                }
            }
        }
        .padding(14)
        .vampHomeLiveGlass(
            in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous),
            phaseOffset: 2.1
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(assistant.displayName), \(assistant.address)")
    }
}

struct VampAssistantActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .foregroundStyle(PR.fg)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous), isInteractive: true)
    }
}

private struct VampAssistantAvailabilityBadge: View {
    let availability: BeetCodeRemoteSessionViewModel.Availability

    private var color: Color {
        switch availability {
        case .reachable: return .green
        case .unavailable: return .red
        case .checking: return .gray
        }
    }

    private var text: String {
        switch availability {
        case .reachable: return "Online"
        case .unavailable: return "Offline"
        case .checking: return "Checking"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.65), radius: 3)
                .vampHomeLivePulse(
                    isActive: availability != .unavailable,
                    period: availability == .checking ? 0.9 : 2.1,
                    trough: 0.42
                )
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PR.fg2)
        }
        .accessibilityLabel("\(text) Mac")
    }
}

private struct VampHostConnectionSection: View {
    @ObservedObject var hostsVM: HostsListViewModel
    let onScan: () -> Void
    let onConnect: (DiscoveredHostRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vamp Sync")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(PR.fg)
                    Text("Browse Mac apps over the original host session.")
                        .font(.footnote)
                        .foregroundStyle(PR.fg2)
                }
                Spacer()
                Button(action: onScan) {
                    Label("Scan QR", systemImage: "qrcode.viewfinder")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(PR.fg)
                .accessibilityHint("Scan a Vamp Sync pairing code")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 12) {
                    if hostsVM.displayHosts.isEmpty {
                        VampHostEmptyState(hostsVM: hostsVM)
                    } else {
                        ForEach(hostsVM.displayHosts) { host in
                            VampHostMacCard(host: host, onConnect: { onConnect(host) })
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .refreshable { await hostsVM.refresh() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct VampHostMacTile: View {
    let host: DiscoveredHostRow
    let onConnect: () -> Void

    var body: some View {
        Button(action: onConnect) {
            VStack(spacing: 12) {
                Image(systemName: host.isTerminalOnlyHost ? "terminal" : "laptopcomputer")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(host.isAvailable ? PR.fg : PR.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                VStack(spacing: 3) {
                    Text(anonymizeStreamPreview ? "Your Mac" : host.title)
                        .font(.headline)
                        .foregroundStyle(PR.fg)
                        .lineLimit(1)
                    Text(anonymizeStreamPreview ? "Private network" : host.endpoint.hostname)
                        .font(.caption2.monospaced())
                        .foregroundStyle(PR.dim)
                        .lineLimit(1)
                }
                Text(host.isTerminalOnlyHost ? "unavailable" : (host.isAvailable ? "browse apps" : "offline"))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(host.isTerminalOnlyHost || !host.isAvailable ? PR.dim : PR.fg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((host.isTerminalOnlyHost || !host.isAvailable ? PR.dim : PR.fg).opacity(0.12), in: Capsule())
            }
            .frame(maxWidth: .infinity, minHeight: 148)
            .padding(.vertical, 18)
            .padding(.horizontal, 10)
            .vampHomeLiveGlass(
                in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous),
                phaseOffset: 1.3
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .disabled(host.isTerminalOnlyHost)
        .accessibilityLabel(anonymizeStreamPreview ? "Your Mac" : host.title)
        .accessibilityValue(host.isTerminalOnlyHost ? "Terminal-only host" : "Ready to browse apps")
    }
}

private struct VampAssistantMacTile: View {
    let assistant: BeetCodeRemoteSessionViewModel.SavedAssistant
    let availability: BeetCodeRemoteSessionViewModel.Availability
    let onAppStream: () -> Void
    let onForget: () -> Void

    var body: some View {
        Button(action: onAppStream) {
            VStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(availability == .reachable ? PR.fg : PR.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                VStack(spacing: 3) {
                    Text(tileTitle)
                        .font(.headline)
                        .foregroundStyle(PR.fg)
                        .lineLimit(1)
                    Text(assistant.address)
                        .font(.caption2.monospaced())
                        .foregroundStyle(PR.dim)
                        .lineLimit(1)
                }
                Text(availabilityLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(PR.fg2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(PR.fg.opacity(0.12), in: Capsule())
            }
            .frame(maxWidth: .infinity, minHeight: 148)
            .padding(.vertical, 18)
            .padding(.horizontal, 10)
            .vampHomeLiveGlass(
                in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous),
                phaseOffset: 2.1
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .contextMenu {
            Button("Forget this Mac", role: .destructive, action: onForget)
        }
        .accessibilityLabel("\(assistant.displayName), \(assistant.address)")
    }

    private var tileTitle: String {
        guard assistant.hasGenericDisplayName else { return assistant.displayName }
        switch assistant.connectionKind {
        case .localNetwork: return "Local Mac"
        case .tailscale: return "Tailscale Mac"
        case .privateNetwork: return "Private Mac"
        }
    }

    private var availabilityLabel: String {
        switch availability {
        case .reachable: return "stream"
        case .unavailable: return "offline"
        case .checking: return "checking"
        }
    }
}

private struct VampHostMacCard: View {
    let host: DiscoveredHostRow
    let onConnect: () -> Void

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: 13) {
                Image(systemName: host.isTerminalOnlyHost ? "terminal" : "macbook")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PR.fg)
                    .frame(width: 40, height: 40)
                    .prGlassSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(anonymizeStreamPreview ? "Your Mac" : host.title)
                        .font(.headline)
                        .foregroundStyle(PR.fg)
                        .lineLimit(1)
                    Text(host.isTerminalOnlyHost ? "Terminal-only host" : (anonymizeStreamPreview ? "App windows · Private network" : "App windows · \(host.subtitle)"))
                        .font(.caption)
                        .foregroundStyle(PR.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if host.isTerminalOnlyHost {
                    Text("Unavailable")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PR.dim)
                } else {
                    Label("Browse apps", systemImage: "macwindow")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PR.fg)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vampHomeLiveGlass(
                in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous),
                phaseOffset: 1.3
            )
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .disabled(host.isTerminalOnlyHost)
        .accessibilityLabel(anonymizeStreamPreview ? "Your Mac" : host.title)
        .accessibilityValue(host.isTerminalOnlyHost ? "Terminal-only host" : "Ready to browse apps")
    }
}

private struct VampHostEmptyState: View {
    @ObservedObject var hostsVM: HostsListViewModel
    var onScan: (() -> Void)? = nil

    var body: some View {
        VampStreamEmptyState(
            icon: hostsVM.state == .loading
                ? "hourglass"
                : (hostsVM.hasLocalNetworkIssue ? "wifi.exclamationmark" : "macbook.and.iphone"),
            title: hostsVM.state == .loading ? "Looking for Vamp Sync…" : "No Vamp Sync found",
            message: message,
            actionTitle: hostsVM.state == .loading ? nil : (onScan == nil ? "Retry discovery" : "Scan QR"),
            action: onScan ?? { Task { await hostsVM.refresh() } })
    }

    private var message: String {
        switch hostsVM.state {
        case .loading:
            return "Open Vamp Sync on your Mac and keep both devices on the same LAN or private Tailscale network."
        case .localNetworkIssue(let message):
            return message
        case .unavailable:
            return "A saved host is unavailable. Check that it is running and reachable on a trusted network."
        case .empty, .available:
            return "Open Vamp Sync on your Mac and keep both devices on the same LAN or private Tailscale network."
        }
    }
}

private struct VampStreamConnectionError: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.footnote)
                .foregroundStyle(PR.fg)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PR.warn)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct VampStreamEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    init(
        icon: String,
        title: String,
        message: String,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(PR.fg)
            Text(title)
                .font(.headline)
                .foregroundStyle(PR.fg)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(PR.fg2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
            if let actionTitle, let action {
                VampGlassActionButton(title: actionTitle, action: action)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
    }
}

private extension HostsListViewModel {
    var hasLocalNetworkIssue: Bool {
        if case .localNetworkIssue = state { return true }
        return false
    }
}

/// A small identity adapter used only by the picker. Assistant and Vamp Sync use
/// different transports and ports, so the private host/IP is the useful common key.
private enum VampStreamEndpointIdentity {
    static func host(from address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        if let host = URLComponents(string: candidate)?.host {
            return normalize(host)
        }
        return normalize(trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed)
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .lowercased()
    }
}

/// Full-screen connecting state.
struct VampStreamConnectingView: View {
    let name: String
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(PR.fg)
                .controlSize(.large)
            Text("Connecting to \(name)…")
                .font(.headline)
                .foregroundStyle(PR.fg)
            Text("Approve this iPhone on your Mac the first time.")
                .font(.subheadline)
                .foregroundStyle(PR.fg2)
                .multilineTextAlignment(.center)
            VampGlassActionButton(title: "Cancel", action: onCancel)
        }
        .padding(22)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .foregroundStyle(PR.accent)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(PR.fg)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(PR.fg2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            VampGlassActionButton(
                title: LocalizedStringKey(actionTitle),
                isProminent: true,
                action: action
            )
            .padding(.top, 6)
        }
        .padding(22)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
