import SwiftUI
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
    /// A Vamp Sync connection failure. Kept separate from the Assistant error so a Sync problem
    /// is scoped to the Sync hosts instead of being labelled as an Assistant one.
    let vampSyncError: String?
    /// The one Mac that refused because another device holds its session, or nil. Scoping "In use"
    /// to a named host keeps every other Mac usable instead of implying a page-wide outage.
    let busyHostName: String?
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
        vampSyncError: String? = nil,
        busyHostName: String? = nil,
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
        self.vampSyncError = vampSyncError
        self.busyHostName = busyHostName
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
                        source: hostSource
                    ) {
                        showHostSourcePicker = true
                    }
                    VampAppStreamSection(
                        source: hostSource,
                        cardStyle: homeCardStyle,
                        pairedAssistants: pairedVampAssistants,
                        availability: vampAssistantAvailability,
                        errorMessage: vampAssistantError,
                        syncErrorMessage: vampSyncError,
                        busyHostName: busyHostName,
                        legacyHosts: legacyHostsForAppStream,
                        hostsVM: hostsVM,
                        onPair: onPairVampAssistant,
                        onAppStream: onAppStream,
                        onForget: onForgetVampAssistant,
                        onScan: onScanVampHost,
                        onConnect: onConnect,
                        onToggleCardStyle: {
                            homeCardStyleRaw = homeCardStyle.toggled.rawValue
                        })
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

/// The page title is the product action, not a sentence about the product. Provider choice is a
/// quiet toolbar action, and the list/grid toggle belongs beside the Macs heading it controls
/// rather than crowding the title.
private struct VampStreamConnectHeader: View {
    let source: VampStreamHostSource
    let onChangeHost: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(VampStreamHomeCopy.headerTitle)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(PR.fg)
                Text(VampStreamHomeCopy.headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(PR.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button(action: onChangeHost) {
                Label(VampStreamHomeCopy.changeHost, systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(PR.fg2)
                    .padding(.horizontal, AppSpacing.sm)
                    .frame(minHeight: AppHostMetrics.iconControlTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(VampStreamHomeCopy.changeHost))
            .accessibilityHint("Choose Vamp Sync, Vamp Assistant, or both")
        }
        .padding(.horizontal, AppHostMetrics.screenInset)
        .padding(.top, AppSpacing.lg)
        .padding(.bottom, AppSpacing.md)
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
    /// The Sync failure, scoped to the Sync hosts. A host-busy rejection is compacted to
    /// "Mac is in use" so one busy Mac does not read as a page-wide outage.
    let syncErrorMessage: String?
    /// The one Mac that refused because another device holds its session, or nil.
    let busyHostName: String?
    let legacyHosts: [DiscoveredHostRow]
    @ObservedObject var hostsVM: HostsListViewModel
    let onPair: () -> Void
    let onAppStream: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    let onForget: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    let onScan: () -> Void
    let onConnect: (DiscoveredHostRow) -> Void
    /// Flips list/grid. Owned by the parent, which persists it, and surfaced next to the Macs
    /// heading rather than in the page title.
    let onToggleCardStyle: () -> Void


    // Text drafts and validation live here, on the always-mounted parent — never inside the
    // conditionally rendered card body. Collapsing must not clear an address, cancel pairing, or
    // destroy a scanner coordinator.
    @State private var manualAddress = ""
    @State private var manualError: String?
    @AppStorage(VampStreamSyncPromoStore.installedKey) private var syncInstalled = false
    @State private var promoDismissedThisSession = false

    // Independent, provider-specific expansion state. Two separate keys, never one shared
    // Boolean and never derived from discovery results.
    @AppStorage(VampStreamPairingCardStore.Provider.key(for: .sync)) private var syncExpanded = false
    @AppStorage(VampStreamPairingCardStore.Provider.key(for: .assistant)) private var assistantExpanded = false
    /// Whether the first-run default has already been resolved, so it is computed exactly once
    /// and never recomputed from a discovery list that flickers.
    @State private var didResolveDefaults = false

    private var hasConfiguredHost: Bool {
        !legacyHosts.isEmpty || !pairedAssistants.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppHostMetrics.cardGap) {
                ForEach(
                    VampStreamHomeLayout.sections(
                        source: source,
                        hasSyncHosts: !legacyHosts.isEmpty,
                        hasAssistants: !pairedAssistants.isEmpty,
                        hasAssistantError: errorMessage != nil,
                        hasSyncError: syncErrorMessage != nil,
                        showsSyncPromo: !syncInstalled && !promoDismissedThisSession
                    )
                ) { section in
                    homeSection(section)
                }
            }
            .padding(.horizontal, AppHostMetrics.screenInset)
            .padding(.bottom, AppSpacing.xxl)
            // Scoped to the toggle's value: an availability update elsewhere on the page must not
            // animate the whole screen.
            .animation(.easeOut(duration: 0.2), value: cardStyle)
        }
        .refreshable {
            if source.showsSync {
                await hostsVM.refresh()
            }
        }
        .task(id: hasConfiguredHost) { resolveDefaultsOnce() }
    }

    /// Resolve the first-run default once stored host configuration is known: a returning user
    /// with configured hosts sees both cards collapsed; a first-time user sees the provider they
    /// are setting up expanded and the other collapsed.
    private func resolveDefaultsOnce() {
        guard !didResolveDefaults else { return }
        didResolveDefaults = true
        let configured = hasConfiguredHost
        VampStreamPairingCardStore.latchDefaultIfNeeded(
            provider: .sync,
            hasConfiguredHost: configured,
            isSetupProvider: source == .sync)
        VampStreamPairingCardStore.latchDefaultIfNeeded(
            provider: .assistant,
            hasConfiguredHost: configured,
            isSetupProvider: source == .assistant)
    }

    private func toggle(_ provider: VampStreamPairingCardStore.Provider) {
        let isExpanded = provider == .sync ? syncExpanded : assistantExpanded
        // Dismiss the keyboard cleanly when collapsing a focused form; the draft survives
        // because it is owned by this view, not the card body.
        if isExpanded {
            #if canImport(UIKit)
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
        }
        let next = !isExpanded
        if provider == .sync { syncExpanded = next } else { assistantExpanded = next }
    }

    @ViewBuilder
    private func homeSection(_ section: VampStreamHomeLayout.Section) -> some View {
        switch section {
        case .pairHeading:
            VampStreamSectionLabel(title: VampStreamHomeCopy.pairHeading)
                .padding(.top, AppSpacing.sm)
        case .versionFooter:
            // Subdued and centered, out of the way of the hosts it used to compete with.
            VampStreamVersionBadge()
                .frame(maxWidth: .infinity)
                .padding(.top, AppSpacing.sm)
        case .syncHostCard:
            VampSyncConnectCard(
                isExpanded: syncExpanded,
                onToggle: { toggle(.sync) },
                manualAddress: $manualAddress,
                manualError: $manualError,
                onScan: onScan,
                onConnectByAddress: connectByAddress)
        case .syncMacs:
            VStack(alignment: .leading, spacing: AppHostMetrics.cardGap) {
                // The list/grid control belongs beside the heading it controls, not up by the
                // page title where it competes with the product name.
                VampStreamSectionLabel(
                    title: VampStreamHomeCopy.syncMacsHeading,
                    trailing: { AnyView(cardStyleToggle) })
                if cardStyle == .grid {
                    LazyVGrid(columns: homeGridColumns, spacing: AppHostMetrics.cardGap) {
                        ForEach(visibleSyncHosts) { host in
                            VampHostMacTile(
                                host: host,
                                isBusy: isBusyHost(host),
                                onConnect: { onConnect(host) })
                        }
                    }
                } else {
                    ForEach(visibleSyncHosts) { host in
                        VampHostMacCard(
                            host: host,
                            isBusy: isBusyHost(host),
                            onConnect: { onConnect(host) })
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
        case .syncError:
            if let syncErrorMessage {
                VampStreamConnectionError(message: syncErrorMessage) {
                    Task { await hostsVM.refresh() }
                }
            }
        case .assistantHostCard:
            VampAssistantFollowOnCard(
                isExpanded: assistantExpanded,
                onToggle: { toggle(.assistant) },
                onPair: onPair,
                hasSavedAssistants: !pairedAssistants.isEmpty)
        case .assistantMacs:
            VStack(alignment: .leading, spacing: AppHostMetrics.cardGap) {
                VampStreamSectionLabel(
                    title: VampStreamHomeCopy.assistantMacsHeading,
                    trailing: { AnyView(cardStyleToggle) })
                if cardStyle == .grid {
                    LazyVGrid(columns: homeGridColumns, spacing: AppHostMetrics.cardGap) {
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

    private var cardStyleToggle: some View {
        Button {
            onToggleCardStyle()
        } label: {
            Image(systemName: cardStyle.toggleSystemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PR.fg2)
                .frame(
                    width: AppHostMetrics.iconControlTarget,
                    height: AppHostMetrics.iconControlTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            Text(cardStyle == .grid ? VampStreamHomeCopy.showList : VampStreamHomeCopy.showGrid))
    }

    private var visibleSyncHosts: [DiscoveredHostRow] {
        anonymizeStreamPreview ? Array(legacyHosts.prefix(1)) : legacyHosts
    }

    /// True only for the specific Mac that refused because another device holds its session.
    /// The coordinator reports the advertised display name; comparing case-insensitively tolerates
    /// casing differences between Bonjour discovery and the session offer. Every other host stays
    /// fully usable — one busy Mac must not read as a page-wide outage.
    private func isBusyHost(_ host: DiscoveredHostRow) -> Bool {
        guard let busyHostName, !busyHostName.isEmpty else { return false }
        return host.title.localizedCaseInsensitiveCompare(busyHostName) == .orderedSame
    }

    /// Columns are computed from the available width with a ~160-point minimum tile and a
    /// 12-point gap, falling back to one column on narrow layouts and at large text sizes so a
    /// single host spans the full width instead of sitting in a half-empty grid row.
    private var homeGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 160), spacing: AppHostMetrics.cardGap)]
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

/// A quiet sentence-case section heading on the shared outer grid, with an optional trailing
/// control (the list/grid toggle) aligned to the same baseline.
private struct VampStreamSectionLabel: View {
    let title: String
    var trailing: (() -> AnyView)?

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.xs) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PR.fg2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing { trailing() }
        }
        .padding(.top, AppSpacing.xxs)
        .accessibilityElement(children: .contain)
    }
}

/// Vamp Sync pairing, on the shared collapsible shell. Collapsed is header only: the Scan QR
/// button, the address field, and Connect all live in the expanded body so their gestures cannot
/// accidentally collapse the card.
private struct VampSyncConnectCard: View {
    let isExpanded: Bool
    let onToggle: () -> Void
    @Binding var manualAddress: String
    @Binding var manualError: String?
    let onScan: () -> Void
    let onConnectByAddress: () -> Void

    var body: some View {
        VampPairingCard(
            icon: AnyView(syncMark),
            title: VampStreamHomeCopy.syncTitle,
            detail: VampStreamHomeCopy.syncDetail,
            collapsedDetail: VampStreamHomeCopy.syncConnectCollapsedDetail,
            isExpanded: isExpanded,
            onToggle: onToggle,
            headerStatus: manualError == nil ? nil : "Needs attention",
            accessibilityCollapseLabel: VampStreamHomeCopy.syncConnectCollapse,
            accessibilityExpandLabel: VampStreamHomeCopy.syncConnectExpand
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Button(action: onScan) {
                    Label(VampStreamHomeCopy.scanSync, systemImage: "qrcode.viewfinder")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: AppHostMetrics.controlHeight)
                }
                .buttonStyle(PRGlassPressButtonStyle())
                .foregroundStyle(PR.fg)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(PR.fg.opacity(0.10)))
                .accessibilityLabel(Text(VampStreamHomeCopy.scanSync))
                .accessibilityHint(Text(VampStreamHomeCopy.scanSyncHint))

                Text(VampStreamHomeCopy.orConnectByAddress)
                    .font(.footnote)
                    .foregroundStyle(PR.fg2)
                    .padding(.top, AppSpacing.xxs)

                TextField(
                    "",
                    text: $manualAddress,
                    prompt: Text(VampStreamHomeCopy.addressPlaceholder)
                        .foregroundStyle(PR.fg2)
                )
                    .font(.subheadline)
                    .foregroundStyle(PR.fg)
                    .tint(PR.fg)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .padding(.horizontal, AppSpacing.sm)
                    .frame(minHeight: AppHostMetrics.controlHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(PR.bg.opacity(0.55)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(PR.border, lineWidth: 1)
                    }
                    .accessibilityLabel(Text(VampStreamHomeCopy.addressPlaceholder))

                // Validation sits beside the field it refers to, not detached at the bottom.
                if let manualError {
                    Label {
                        Text(manualError)
                            .font(.footnote)
                            .foregroundStyle(PR.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(PR.fg2)
                    }
                    .accessibilityLabel("Address problem: \(manualError)")
                }

                VampGlassActionButton(
                    title: LocalizedStringKey(VampStreamHomeCopy.connectByAddress),
                    systemImage: "link",
                    isDisabled: manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: onConnectByAddress
                )
            }
        }
    }

    private var syncMark: some View {
        VampStreamWindowFangsMark()
            .fill(PR.fg, style: FillStyle(eoFill: true))
            .frame(width: 20, height: 22)
            .frame(
                width: AppHostMetrics.providerIcon,
                height: AppHostMetrics.providerIcon)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PR.fg.opacity(0.10)))
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

/// Vamp Assistant pairing, on the same shell so both cards share padding, typography, and corner
/// radius instead of looking like separate mini-apps. Assistant pairs through its own workspace
/// sheet — it has no QR code or private-address form, so none is invented here.
private struct VampAssistantFollowOnCard: View {
    let isExpanded: Bool
    let onToggle: () -> Void
    let onPair: () -> Void
    let hasSavedAssistants: Bool

    var body: some View {
        VampPairingCard(
            icon: AnyView(assistantMark),
            title: VampStreamHomeCopy.assistantTitle,
            detail: VampStreamHomeCopy.assistantDetail,
            collapsedDetail: VampStreamHomeCopy.assistantConnectCollapsedDetail,
            isExpanded: isExpanded,
            onToggle: onToggle,
            accessibilityCollapseLabel: VampStreamHomeCopy.assistantConnectCollapse,
            accessibilityExpandLabel: VampStreamHomeCopy.assistantConnectExpand
        ) {
            Button(action: onPair) {
                Label(
                    VampStreamHomeCopy.pairAssistantTitle(hasSavedAssistants: hasSavedAssistants),
                    systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: AppHostMetrics.controlHeight)
            }
            .buttonStyle(PRGlassPressButtonStyle())
            .foregroundStyle(PR.fg)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(PR.fg.opacity(0.10)))
            .accessibilityLabel(
                Text(VampStreamHomeCopy.pairAssistantTitle(hasSavedAssistants: hasSavedAssistants)))
            .accessibilityHint(Text(VampStreamHomeCopy.pairAssistantHint))
        }
    }

    private var assistantMark: some View {
        Image(systemName: "sparkles.tv")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(PR.fg)
            .frame(
                width: AppHostMetrics.providerIcon,
                height: AppHostMetrics.providerIcon)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PR.fg.opacity(0.10)))
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

    private var mappedAvailability: VampHostAvailability {
        switch availability {
        case .reachable: return .online
        case .unavailable: return .offline
        case .checking: return .checking
        }
    }

    /// The provider name is already carried by the section heading and the grouping, so it is not
    /// repeated as a badge on every row. The connection kind is the useful secondary line.
    private var connectionDetail: String {
        switch assistant.connectionKind {
        case .localNetwork: return "Local network"
        case .tailscale: return "Tailscale"
        case .privateNetwork: return "Private network"
        }
    }

    private var name: String {
        guard assistant.hasGenericDisplayName else { return assistant.displayName }
        switch assistant.connectionKind {
        case .localNetwork: return "Local Mac"
        case .tailscale: return "Tailscale Mac"
        case .privateNetwork: return "Private Mac"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: VampHostDeviceSymbol.symbol(isTerminalOnly: false))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PR.fg)
                    .frame(
                        width: AppHostMetrics.deviceIcon,
                        height: AppHostMetrics.deviceIcon)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(PR.fg.opacity(0.08)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PR.fg)
                        .lineLimit(1)
                    // The full endpoint stays available through the overflow copy action; the
                    // long address is no longer the most prominent content in the row.
                    Text(connectionDetail)
                        .font(.caption)
                        .foregroundStyle(PR.fg2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VampHostStatusLabel(availability: mappedAvailability)

                // Overflow sits outside the primary action, so its taps are never swallowed by a
                // row-wide gesture and it is not nested inside a Button.
                Menu {
                    Button(assistant.address) {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = assistant.address
                        #endif
                    }
                    Button("Forget this Mac", role: .destructive, action: onForget)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PR.fg2)
                        .frame(
                            width: AppHostMetrics.iconControlTarget,
                            height: AppHostMetrics.iconControlTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More actions for \(name)")
            }

            if showsRemoteControl || showsAppStream {
                HStack(spacing: AppSpacing.sm) {
                    if showsRemoteControl {
                        VampAssistantActionButton(
                            title: "Control Mac",
                            systemImage: "display",
                            action: onRemoteControl)
                    }
                    if showsAppStream {
                        VampAssistantActionButton(
                            title: "Browse apps",
                            systemImage: "macwindow.badge.plus",
                            action: onAppStream)
                    }
                }
            }
        }
        .padding(AppHostMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appQuietSurface(isInteractive: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(assistant.address)")
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
    /// True when this specific Mac refused because another device holds its session.
    var isBusy: Bool = false
    let onConnect: () -> Void

    var body: some View {
        Button(action: onConnect) {
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: VampHostDeviceSymbol.symbol(isTerminalOnly: host.isTerminalOnlyHost))
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(availability == .online ? PR.fg : PR.fg2)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                VStack(spacing: 2) {
                    Text(anonymizeStreamPreview ? "Your Mac" : host.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PR.fg)
                        // Wraps rather than clips, so a long Mac name stays readable.
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(anonymizeStreamPreview ? "Private network" : host.endpoint.hostname)
                        .font(.caption2.monospaced())
                        .foregroundStyle(PR.dim)
                        .lineLimit(1)
                }
                VampHostStatusLabel(availability: availability)
            }
            // Compact: no oversized laptop illustration and no forced square. Height follows
            // content so large text grows the tile instead of clipping.
            .frame(maxWidth: .infinity)
            .padding(AppHostMetrics.cardPadding)
            .appQuietSurface(isInteractive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .disabled(host.isTerminalOnlyHost)
        .opacity(host.isTerminalOnlyHost ? 0.62 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(anonymizeStreamPreview ? "Your Mac" : host.title)
        .accessibilityValue(
            host.isTerminalOnlyHost
                ? "Terminal-only host, unavailable"
                : "\(availability.label). \(host.endpoint.hostname)")
    }

    private var availability: VampHostAvailability {
        if host.isTerminalOnlyHost { return .offline }
        if isBusy { return .busy }
        return host.isAvailable ? .online : .offline
    }
}

private struct VampAssistantMacTile: View {
    let assistant: BeetCodeRemoteSessionViewModel.SavedAssistant
    let availability: BeetCodeRemoteSessionViewModel.Availability
    let onAppStream: () -> Void
    let onForget: () -> Void

    var body: some View {
        Button(action: onAppStream) {
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: VampHostDeviceSymbol.symbol(isTerminalOnly: false))
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(availability == .reachable ? PR.fg : PR.fg2)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                VStack(spacing: 2) {
                    Text(tileTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PR.fg)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(assistant.address)
                        .font(.caption2.monospaced())
                        .foregroundStyle(PR.dim)
                        .lineLimit(1)
                }
                VampHostStatusLabel(availability: mappedAvailability)
            }
            .frame(maxWidth: .infinity)
            .padding(AppHostMetrics.cardPadding)
            .appQuietSurface(isInteractive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .contextMenu {
            Button("Forget this Mac", role: .destructive, action: onForget)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tileTitle), \(assistant.address)")
        .accessibilityValue("\(mappedAvailability.label). Browse apps")
    }

    private var mappedAvailability: VampHostAvailability {
        switch availability {
        case .reachable: return .online
        case .unavailable: return .offline
        case .checking: return .checking
        }
    }

    private var tileTitle: String {
        guard assistant.hasGenericDisplayName else { return assistant.displayName }
        switch assistant.connectionKind {
        case .localNetwork: return "Local Mac"
        case .tailscale: return "Tailscale Mac"
        case .privateNetwork: return "Private Mac"
        }
    }

}

/// A compact host row: device icon, name, one concise connection line, real status, and one
/// primary action. Quiet content surface rather than per-row glass, so the list does not read as
/// a wall of equally important floating controls.
private struct VampHostMacCard: View {
    let host: DiscoveredHostRow
    /// True when this specific Mac refused because another device holds its session.
    var isBusy: Bool = false
    let onConnect: () -> Void

    private var availability: VampHostAvailability {
        if host.isTerminalOnlyHost { return .offline }
        if isBusy { return .busy }
        return host.isAvailable ? .online : .offline
    }

    private var detail: String {
        if host.isTerminalOnlyHost { return "Terminal-only host" }
        if anonymizeStreamPreview { return "App windows · Private network" }
        return "App windows · \(host.subtitle)"
    }

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: VampHostDeviceSymbol.symbol(isTerminalOnly: host.isTerminalOnlyHost))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PR.fg)
                    .frame(
                        width: AppHostMetrics.deviceIcon,
                        height: AppHostMetrics.deviceIcon)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(PR.fg.opacity(0.08)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(anonymizeStreamPreview ? "Your Mac" : host.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PR.fg)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(PR.fg2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                    VampHostStatusLabel(availability: availability)
                    // "Browse apps" opens the picker; it is not labelled "Stream" because it does
                    // not start streaming by itself.
                    if !host.isTerminalOnlyHost {
                        Text("Browse apps")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PR.dim)
                    }
                }
            }
            .padding(AppHostMetrics.cardPadding)
            .frame(maxWidth: .infinity, minHeight: AppHostMetrics.rowMinHeight, alignment: .leading)
            .appQuietSurface(isInteractive: true)
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .disabled(host.isTerminalOnlyHost)
        .opacity(host.isTerminalOnlyHost ? 0.62 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(anonymizeStreamPreview ? "Your Mac" : host.title)
        .accessibilityValue(
            host.isTerminalOnlyHost
                ? "Terminal-only host, unavailable"
                : "\(availability.label). \(detail)")
        .accessibilityHint(
            Text(host.isTerminalOnlyHost
                ? "Vamp Terminal Host serves terminal tabs only and cannot stream applications."
                : "Opens this Mac's applications"))
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

/// A connection failure, scoped to the provider that produced it.
///
/// The host-busy rejection is compacted to "Mac is in use" with an actionable second line. It is
/// a per-host condition, so the copy must not read as a page-wide outage that would make the user
/// think the other Macs are unusable too.
private struct VampStreamConnectionError: View {
    let message: String
    var onRetry: (() -> Void)?

    private var isHostBusy: Bool { VampStreamHostBusy.isHostBusy(message) }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: isHostBusy ? "person.2.fill" : "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PR.fg2)
                .frame(
                    width: AppHostMetrics.iconControlTarget,
                    height: AppHostMetrics.iconControlTarget,
                    alignment: .topLeading)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(isHostBusy ? VampStreamHostBusy.title : "Could not connect")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PR.fg)
                Text(isHostBusy ? VampStreamHostBusy.detail : message)
                    .font(.footnote)
                    .foregroundStyle(PR.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                if let onRetry {
                    Button("Try again", action: onRetry)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PR.fg)
                        .padding(.top, AppSpacing.xxs)
                        .accessibilityLabel("Retry connecting")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppHostMetrics.cardPadding)
        // A quiet, opaque content surface. Errors are content, not floating controls, so they do
        // not carry the conspicuous glass treatment.
        .background {
            RoundedRectangle(cornerRadius: AppHostMetrics.cardRadius, style: .continuous)
                .fill(PR.card.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: AppHostMetrics.cardRadius, style: .continuous)
                        .strokeBorder(PR.border, lineWidth: 1)
                }
        }
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
