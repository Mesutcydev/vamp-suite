import SwiftUI
import SharedModels
import SharedUtilities

/// The two source protocols remain separate; this screen only brings their destinations together.
struct ControlHomeView: View {
    let environment: ClientAppEnvironment
    @ObservedObject var appLock: AppLockService
    @ObservedObject private var hosts: HostsListViewModel
    @ObservedObject private var coordinator: ClientSessionCoordinator
    @StateObject private var companion = BeetCodeRemoteSessionViewModel()
    @StateObject private var renderer: VideoRendererViewModel
    @StateObject private var stats: SessionStatsViewModel
    @StateObject private var appStream: AppStreamViewModel
    /// Free 15-minute daily allowance and the Pro unlock that removes it.
    @StateObject private var usage = DailyStreamingUsage()
    @StateObject private var unlock = StreamingUnlockStore()
    @State private var showsPaywall = false
    @Environment(\.scenePhase) private var scenePhase
    /// Set when leaving the app browser for the desktop, so the desktop view asks the host for its display back.
    @State private var restoresDesktop = false
    @State private var showsAddMac = false
    @State private var showsSettings = false
    @State private var destination: SessionDestination?
    @State private var connectingHost: DiscoveredHostRow?
    @State private var isRefreshing = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var notice: String?
    @State private var pendingForget: BeetCodeRemoteSessionViewModel.SavedAssistant?
    /// Unfolded iPhone Duo (951 pt), iPad, and wide landscape get two panes; the
    /// cover screen and regular iPhones keep one column. Short panels (the Duo's
    /// 678 pt cover, its 669 pt inner panel) drop the card illustration.
    @State private var layoutSize = CGSize.zero
    @State private var appeared = false
    /// Where an open foldable's crease crosses the content, in content points (iPhone Duo inner panel).
    @State private var hingeX: CGFloat?
    /// Duo panels keep the status bar in a side column, so they have no top inset.
    @State private var windowTopInset: CGFloat = 59
    /// The fold leaves this much clear space on each side of the crease.
    private let hingeGutter: CGFloat = 22
    private var isWide: Bool { layoutSize.width >= ControlDesign.wideMinWidth }
    private var isTall: Bool { layoutSize.height >= 700 }
    /// The side-by-side hero needs the unfolded Duo's width (951 pt); narrower two-pane widths stack it.
    private var isRoomyWide: Bool { layoutSize.width >= 900 }
    /// iPad and the unfolded Duo have height to spare; the hero grows into it instead of leaving it empty.
    private var wideArtHeight: CGFloat { min(max(layoutSize.height * 0.56, 168), 470) }
    /// Stacked hero art: grows with height on two-pane screens (the unfolded Duo is ~890 × 669 pt usable).
    private var stackedArtHeight: CGFloat {
        if isWide { return min(max(layoutSize.height * 0.5, 176), 400) }
        return isTall ? 176 : 124
    }

    private enum SessionDestination: String, Identifiable {
        case sync, companion, apps
        var id: String { rawValue }
    }

    init(environment: ClientAppEnvironment, appLock: AppLockService) {
        self.environment = environment
        self.appLock = appLock
        hosts = environment.sharedHostsViewModel
        coordinator = environment.sessionCoordinator
        _renderer = StateObject(wrappedValue: VideoRendererViewModel(webRTCSessionManager: environment.webRTCSessionManager))
        _stats = StateObject(wrappedValue: SessionStatsViewModel(webRTCSessionManager: environment.webRTCSessionManager,
                                                               sessionCoordinator: environment.sessionCoordinator))
        _appStream = StateObject(wrappedValue: AppStreamViewModel(environment: environment))
    }

    private var syncHosts: [DiscoveredHostRow] { hosts.displayHosts.filter { !$0.isTerminalOnlyHost } }
    private var isEmpty: Bool { syncHosts.isEmpty && companion.savedAssistants.isEmpty }
    private var availableCount: Int {
        syncHosts.filter(\.isAvailable).count
            + companion.savedAssistants.filter { companion.availabilityByAddress[$0.address] == .reachable }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if let hingeX, isWide {
                        twoPageLayout(hingeX: hingeX)
                    } else if isWide {
                        HStack(alignment: .top, spacing: 32) {
                            VStack(alignment: .leading, spacing: 20) {
                                header
                                if !isEmpty { statStrip.controlAppear(appeared, delay: 0.08) }
                                notices
                                if !isEmpty { ControlAddMacTile { showsAddMac = true }.controlAppear(appeared, delay: 0.2) }
                                ControlPrivacyFootnote().controlAppear(appeared, delay: 0.26)
                            }
                            .frame(width: isRoomyWide ? 300 : 250, alignment: .leading)
                            library.frame(maxWidth: .infinity, alignment: .top)
                                .controlAppear(appeared, delay: 0.12)
                        }
                        .frame(maxWidth: ControlDesign.wideMaxWidth, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            header
                            if !isEmpty { statStrip.controlAppear(appeared, delay: 0.08) }
                            notices
                            library.controlAppear(appeared, delay: 0.14)
                            if !isEmpty { ControlAddMacTile { showsAddMac = true }.controlAppear(appeared, delay: 0.2) }
                            ControlPrivacyFootnote().controlAppear(appeared, delay: 0.26)
                        }
                        .frame(maxWidth: ControlDesign.maxWidth, alignment: .leading)
                    }
                }
                .background { ControlHingeReader(hingeX: $hingeX) }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { layoutSize = $0 }
            .animation(.smooth, value: hingeX)
            .animation(.smooth, value: isWide)
            .animation(.smooth, value: notice)
            .background { ControlBackground() }
            .refreshable { await refresh() }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { windowTopInset = $0 }
            .onAppear { appeared = true }
            .safeAreaInset(edge: .bottom) {
                // A pending host confirmation always gets its card, whichever path started the
                // connection: a prompt nobody can see would stall pairing until it times out.
                if connectingHost != nil || companion.isPairing || coordinator.pendingHostConfirmation != nil {
                    ControlConnectionProgress(name: connectingHost?.title ?? coordinator.pendingHostConfirmation?.hostName,
                                              fingerprint: connectingHost == nil ? nil : environment.clientIdentity.publicKeyFingerprint,
                                              isApproved: coordinator.phase == .waitingForMedia,
                                              hostConfirmation: coordinator.pendingHostConfirmation,
                                              usesOlderSync: connectingHost != nil && coordinator.hostUsesLegacyHandshake,
                                              onConfirmHost: coordinator.confirmPendingHost,
                                              onCancel: cancelConnection)
                        .padding(.horizontal, 20).padding(.bottom, 12)
                }
            }
        }
        .sheet(isPresented: $showsAddMac, onDismiss: presentPairedCompanion) {
            ControlAddMacView(hosts: hosts, companion: companion, onConnectSync: { host in
                showsAddMac = false
                connect(host)
            })
            .presentationSizing(.form)
        }
        .sheet(isPresented: $showsPaywall) {
            StreamingPaywallView(unlockStore: unlock, usage: usage, onDismiss: { showsPaywall = false })
        }
        .sheet(isPresented: $showsSettings) {
            ControlSettingsView(environment: environment, appLock: appLock, companion: companion)
                .presentationSizing(.form)
        }
        .fullScreenCover(item: $destination) { destination in
            switch destination {
            case .sync:
                MirrorFullscreenStreamView(environment: environment, rendererVM: renderer, statsVM: stats,
                                           onClose: closeSession, onOpenApps: openApps,
                                           restoresDesktop: restoresDesktop)
                    .ignoresSafeArea()
                    .preferredColorScheme(.dark)
            case .apps:
                AppStreamBrowserView(environment: environment, vm: appStream, chrome: .control, onClose: leaveApps)
            case .companion:
                if let session = companion.session {
                    BeetCodeRemoteView(session: session, clientName: "Vamp Control", hostProductName: "Vamp Companion",
                                       presentationBackground: ControlDesign.canvas, onClose: closeSession,
                                       onRefresh: { await companion.refreshStatus() })
                        .preferredColorScheme(.dark)
                }
            }
        }
        .confirmationDialog("Forget this Mac?", isPresented: Binding(
            get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } }
        ), titleVisibility: .visible) {
            Button("Forget Mac", role: .destructive) {
                if let pendingForget { companion.forget(pendingForget) }
                pendingForget = nil
            }
        } message: { Text("You’ll need its pairing code to connect again.") }
        .task {
            renderer.onNeedsKeyframe = { [weak coordinator = coordinator] in
                coordinator?.requestKeyframeRefresh(reason: "decode error")
            }
            renderer.startReceiving()
            stats.start(refreshInterval: 1)
            await hosts.start()
            await companion.refreshAvailability()
        }
        .onDisappear {
            if destination == nil {
                stats.stop()
                renderer.stopReceiving()
                connectionTask?.cancel()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await hosts.handleSceneBecameActive(); await companion.refreshAvailability() }
        }
        .onChange(of: usage.secondsUsedToday) { _, _ in
            // The cap ends a live session and presents Pro in its place.
            guard StreamingUnlockStore.isEnforced, !unlock.isEffectivelyUnlocked, !usage.hasTimeRemaining,
                  destination != nil else { return }
            closeSession()
            showsPaywall = true
        }
        .onChange(of: coordinator.activeSessionID) { _, id in
            if id != nil { renderer.startReceiving() }
        }
        .onChange(of: coordinator.phase) { _, phase in
            switch phase {
            case .receiving:
                connectingHost = nil
                notice = nil
                usage.startSession()
                if coordinator.appStreamingOnlySession {
                    destination = .apps
                } else {
                    restoresDesktop = false
                    destination = .sync
                }
                AppHaptics.selection()
            case .error:
                connectingHost = nil
                let message = coordinator.blockedState?.message ?? coordinator.errorMessage
                    ?? String(localized: "Couldn’t reach your Mac. Check that Vamp Sync is open and try again.")
                notice = message.replacingOccurrences(of: "Vamp Host", with: "Vamp Sync")
                usage.stopSession()
                destination = nil
            case .waitingForMedia where coordinator.appStreamingOnlySession:
                // An app-only host starts no capture until a window is named, so the app browser is the session.
                connectingHost = nil
                notice = nil
                usage.startSession()
                destination = .apps
                AppHaptics.selection()
            case .idle:
                connectingHost = nil
                // Backgrounding disconnects to idle. Without stopping the meter here the
                // free allowance kept counting the whole time the app was away, and the
                // session was cut for "time used" moments after returning.
                usage.stopSession()
                if destination == .sync { destination = nil }
            default: break
            }
        }
        .onChange(of: companion.session?.address) { _, address in
            guard address != nil else { return }
            Task { await coordinator.endSession() }
            if showsAddMac { showsAddMac = false }
            else { destination = .companion }
        }
        .onChange(of: companion.lastError) { _, error in
            if !showsAddMac { notice = error.map(ControlDesign.companionMessage) }
        }
    }

    /// Unfolded iPhone Duo: two pages split exactly at the crease, like two cover screens
    /// side by side. Nothing straddles the fold, and each page fills its height.
    private func twoPageLayout(hingeX: CGFloat) -> some View {
        let pageHeight = max(layoutSize.height - 34, 360)
        let others = syncHosts.count + companion.savedAssistants.count - 1
        return HStack(alignment: .top, spacing: hingeGutter * 2) {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !isEmpty { statStrip.controlAppear(appeared, delay: 0.08) }
                ControlDeviceCard(name: environment.clientIdentity.displayName,
                                  fingerprint: environment.clientIdentity.publicKeyFingerprint)
                    .controlAppear(appeared, delay: 0.14)
                Spacer(minLength: 12)
                if !isEmpty { ControlAddMacTile { showsAddMac = true }.controlAppear(appeared, delay: 0.2) }
                ControlPrivacyFootnote().controlAppear(appeared, delay: 0.26)
            }
            .frame(width: max(hingeX - hingeGutter, 240), height: pageHeight, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 12) {
                notices
                if isEmpty {
                    ControlFirstMacView(isSearching: isRefreshing, onAdd: { showsAddMac = true },
                                        onRefresh: { Task { await refresh() } })
                } else {
                    if coordinator.phase == .receiving {
                        ControlLiveSessionPill { destination = .sync }
                    }
                    pageLibrary(fills: others == 0 && notice == nil && coordinator.phase != .receiving,
                                pageHeight: pageHeight)
                }
            }
            .frame(maxWidth: .infinity, minHeight: pageHeight, alignment: .top)
            .controlAppear(appeared, delay: 0.12)
        }
    }

    /// The right page: one Mac fills the page; several Macs list below the first.
    private func pageLibrary(fills: Bool, pageHeight: CGFloat) -> some View {
        // Card chrome around the art: 10 pt padding twice, 14 pt spacing, ~58 pt title row.
        let art = fills ? min(pageHeight - 92, 520) : stackedArtHeight
        let companionHero = syncHosts.isEmpty ? 1 : 0
        let others = syncHosts.count + companion.savedAssistants.count - 1
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(syncHosts.prefix(1)) { syncCard($0, featured: true, artHeight: art) }
            ForEach(companion.savedAssistants.prefix(companionHero)) { companionCard($0, featured: true, artHeight: art) }
            if others > 0 {
                ControlSectionLabel(title: "More Macs").padding(.top, 8)
                ForEach(syncHosts.dropFirst()) { syncCard($0, featured: false) }
                ForEach(companion.savedAssistants.dropFirst(companionHero)) { companionCard($0, featured: false) }
            }
        }
        .disabled(connectingHost != nil || companion.isPairing)
    }

    private var header: some View {
        ControlHomeHeader(isEmpty: isEmpty, availableCount: availableCount, appeared: appeared)
    }

    private var statStrip: some View {
        HStack(spacing: 10) {
            ControlStat(label: "Online", value: "\(availableCount)/\(syncHosts.count + companion.savedAssistants.count)",
                        tint: availableCount > 0 ? ControlDesign.available : nil)
            ControlStat(label: "Network", value: networkLabel)
            ControlStat(label: "Relay", value: "None")
        }
    }

    private var networkLabel: LocalizedStringKey {
        if let host = syncHosts.first(where: \.isAvailable) ?? syncHosts.first {
            return isTailscale(host) ? "Tailscale" : "Local"
        }
        if let saved = companion.savedAssistants.first {
            return saved.connectionKind == .tailscale ? "Tailscale" : "Private"
        }
        return "—"
    }

    private var topBar: some View {
        HStack(spacing: 11) {
            ControlGlassLogo(size: 38)
            VStack(alignment: .leading, spacing: 0) {
                Text("vamp").font(.system(size: 19, weight: .bold)).tracking(-0.7)
                    .foregroundStyle(ControlDesign.ink)
                ControlMono(text: "Control", size: 8.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Vamp Control")
            Spacer()
            Group {
                ControlGlassIconButton(symbol: "plus", label: "Add Mac") { showsAddMac = true }
                    .accessibilityIdentifier("control.addMac")
                ControlGlassIconButton(symbol: "gearshape", label: "Settings") { showsSettings = true }
                    .accessibilityIdentifier("control.settings")
            }
            .disabled(connectingHost != nil || companion.isPairing)
        }
        .padding(.horizontal, 20).padding(.top, windowTopInset < 20 ? 14 : 4).padding(.bottom, 12)
        .frame(maxWidth: isWide ? ControlDesign.wideMaxWidth + 40 : .infinity)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(stops: [.init(color: ControlDesign.canvas, location: 0),
                                   .init(color: ControlDesign.canvas.opacity(0.88), location: 0.6),
                                   .init(color: ControlDesign.canvas.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        }
    }

    @ViewBuilder private var notices: some View {
        if let notice {
            ControlNotice(message: notice) { self.notice = nil }
        }
        if case .localNetworkIssue(let message) = hosts.state {
            ControlNotice(message: message, onDismiss: nil)
        }
    }

    @ViewBuilder private var library: some View {
        if isEmpty {
            ControlFirstMacView(isSearching: isRefreshing, onAdd: { showsAddMac = true },
                                onRefresh: { Task { await refresh() } })
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if coordinator.phase == .receiving {
                    ControlLiveSessionPill { destination = .sync }
                }
                macLibrary
            }
        }
    }

    /// The first Mac is the hero; the rest are compact rows that flow into columns when unfolded.
    private var macLibrary: some View {
        let companionHero = syncHosts.isEmpty ? 1 : 0
        let others = syncHosts.count + companion.savedAssistants.count - 1
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(syncHosts.prefix(1)) { syncCard($0, featured: true) }
            ForEach(companion.savedAssistants.prefix(companionHero)) { companionCard($0, featured: true) }
            if others > 0 {
                ControlSectionLabel(title: "More Macs").padding(.top, 12)
                LazyVGrid(columns: [isWide ? GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)
                                           : GridItem(.flexible(), alignment: .top)], spacing: 12) {
                    ForEach(syncHosts.dropFirst()) { syncCard($0, featured: false) }
                    ForEach(companion.savedAssistants.dropFirst(companionHero)) { companionCard($0, featured: false) }
                }
            }
        }
        .disabled(connectingHost != nil || companion.isPairing)
    }

    private func syncCard(_ host: DiscoveredHostRow, featured: Bool, artHeight: CGFloat? = nil) -> some View {
        ControlMacCard(name: host.title, source: "Vamp Sync", route: route(for: host),
                       status: host.endpoint.metadata.appVersion == "unknown" && !host.isSaved
                           ? .unverified : (host.isAvailable ? .online : .offline),
                       isFeatured: featured, stackedArtHeight: artHeight ?? stackedArtHeight,
                       isWide: artHeight == nil && isRoomyWide,
                       wideArtHeight: wideArtHeight, onConnect: { connect(host) })
            .contextMenu {
                if host.isSaved {
                    Button("Remove from Macs", systemImage: "minus.circle", role: .destructive) {
                        hosts.removeSavedHost(host.id)
                    }
                }
                if !host.isAvailable && !isTailscale(host) {
                    Button("Wake Mac", systemImage: "sun.max") { wake(host) }
                }
            }
    }

    private func companionCard(_ saved: BeetCodeRemoteSessionViewModel.SavedAssistant, featured: Bool,
                               artHeight: CGFloat? = nil) -> some View {
        ControlMacCard(name: companionName(saved), source: "Vamp Companion",
                       route: saved.connectionKind == .tailscale ? "Tailscale" : "Private network",
                       status: companionStatus(saved), isFeatured: featured,
                       stackedArtHeight: artHeight ?? stackedArtHeight, isWide: artHeight == nil && isRoomyWide,
                       wideArtHeight: wideArtHeight) {
            connectionTask?.cancel()
            companion.cancelConnectionAttempt()
            connectionTask = Task {
                await coordinator.endSession()
                guard !Task.isCancelled else { return }
                await companion.reconnect(saved)
            }
        }
        .contextMenu {
            Button("Forget Mac", systemImage: "trash", role: .destructive) { pendingForget = saved }
        }
    }

    private func companionName(_ saved: BeetCodeRemoteSessionViewModel.SavedAssistant) -> String {
        if saved.hasGenericDisplayName || saved.displayName == "Vamp Companion" {
            return URLComponents(string: saved.address)?.host ?? saved.displayName
        }
        return saved.displayName
    }

    private func companionStatus(_ saved: BeetCodeRemoteSessionViewModel.SavedAssistant) -> ControlMacStatus {
        switch companion.availabilityByAddress[saved.address] {
        case .reachable: .online
        case .unavailable: .offline
        default: .checking
        }
    }

    private func isTailscale(_ host: DiscoveredHostRow) -> Bool {
        StorePrivateNetworkConnectionPolicy.isTailscaleHost(host.endpoint.hostname)
    }

    private func route(for host: DiscoveredHostRow) -> LocalizedStringKey {
        isTailscale(host) ? "Tailscale" : "Local network"
    }

    private func connect(_ host: DiscoveredHostRow) {
        guard !host.isTerminalOnlyHost else { return }
        guard !StreamingUnlockStore.isEnforced || unlock.isEffectivelyUnlocked || usage.hasTimeRemaining else {
            showsPaywall = true
            return
        }
        connectionTask?.cancel()
        companion.disconnect()
        notice = nil
        AppHaptics.impact(.light)
        connectionTask = Task {
            if coordinator.phase != .idle { await coordinator.endSession() }
            guard !Task.isCancelled else { return }
            connectingHost = host
            hosts.connect(to: host)
            await coordinator.connect(to: host.endpoint, qualityPreset: environment.effectivePreferredQualityPreset)
        }
    }

    private func cancelConnection() {
        connectionTask?.cancel()
        companion.cancelConnectionAttempt()
        notice = nil
        if connectingHost != nil || coordinator.pendingHostConfirmation != nil {
            connectingHost = nil
            Task { await coordinator.endSession() }
        }
    }

    private func presentPairedCompanion() {
        if companion.session != nil { destination = .companion }
    }

    private func closeSession() {
        usage.stopSession()
        destination = nil
        companion.disconnect()
        Task { await coordinator.endSession() }
    }

    /// Desktop → app windows, from the session's Apps control. The same session carries both.
    private func openApps() {
        restoresDesktop = false
        destination = .apps
    }

    /// App windows → desktop when the Mac also offers its desktop; otherwise leaving ends the session.
    private func leaveApps() {
        guard let capabilities = coordinator.negotiatedCapabilities,
              capabilities.supportsMultiDisplay, !coordinator.appStreamingOnlySession else {
            closeSession()
            return
        }
        restoresDesktop = true
        destination = .sync
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        async let syncRefresh: () = hosts.refresh()
        async let companionRefresh: () = companion.refreshAvailability()
        _ = await (syncRefresh, companionRefresh)
    }

    private func wake(_ host: DiscoveredHostRow) {
        guard !isTailscale(host) else { return }
        if host.endpoint.metadata.magicWakeCapable == false {
            notice = String(localized: "This Mac can’t wake directly over Wi-Fi. Wake it locally, use Ethernet, or enable Keep Mac Awake in Vamp Sync.")
            return
        }
        connectionTask = Task {
            let outcome = await WakeCoordinator().wake(macAddress: host.endpoint.metadata.macAddress,
                bonjourServiceName: host.endpoint.bonjourServiceName, targetHost: host.endpoint.hostname,
                wakeSupported: host.endpoint.metadata.wakeSupported)
            notice = outcome.userMessage.replacingOccurrences(of: "Vamp Host", with: "Vamp Sync")
            await hosts.refresh()
        }
    }
}

private struct ControlHomeHeader: View {
    let isEmpty: Bool
    let availableCount: Int
    let appeared: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 34

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 7) {
                ControlMono(text: "\(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))", size: 10)
                    .controlAppear(appeared)
                Text(Self.greeting(at: context.date))
                    .font(.system(size: titleSize, weight: .bold)).tracking(-1.1)
                    .foregroundStyle(ControlDesign.ink)
                    .accessibilityAddTraits(.isHeader)
                    .controlAppear(appeared, delay: 0.03)
                HStack(spacing: 8) {
                    ControlPulseDot(color: availableCount > 0 ? ControlDesign.available : ControlDesign.secondary.opacity(0.5),
                                    isLive: availableCount > 0)
                    Text(isEmpty ? "Add a Mac to get started"
                         : availableCount > 0 ? "^[\(availableCount) Mac](inflect: true) ready to connect"
                                              : "No Macs reachable right now")
                        .font(.subheadline.weight(.medium)).foregroundStyle(ControlDesign.secondary)
                }
                .padding(.top, 2)
                .controlAppear(appeared, delay: 0.06)
            }
        }
    }

    static func greeting(at date: Date) -> LocalizedStringKey {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}

/// This device's identity, as Vamp Sync shows it when asking you to approve a pairing.
private struct ControlDeviceCard: View {
    let name: String
    let fingerprint: String
    private var kind: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: kind == "iPad" ? "ipad" : "iphone.gen3").font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ControlDesign.ink)
                    .frame(width: 40, height: 40)
                    .controlGlass(radius: 12, emphasis: .control)
                VStack(alignment: .leading, spacing: 2) {
                    ControlMono(text: "This \(kind)", size: 8.5)
                    Text(name).font(.headline).foregroundStyle(ControlDesign.ink).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                ControlMono(text: "Fingerprint · match it on your Mac", size: 8.5)
                Text(ControlConnectionProgress.grouped(fingerprint))
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).lineSpacing(3)
                    .foregroundStyle(ControlDesign.ink.opacity(0.85))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(ControlDesign.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(14)
        .controlGlass(radius: 22)
        .accessibilityElement(children: .combine)
    }
}

private struct ControlStat: View {
    let label: LocalizedStringKey
    let value: LocalizedStringKey
    var tint: Color?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ControlMono(text: label, size: 8.5)
            HStack(spacing: 6) {
                if let tint { ControlPulseDot(color: tint, size: 6) }
                Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(ControlDesign.ink)
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlGlass(radius: 18, emphasis: .control)
        .accessibilityElement(children: .combine)
    }
}

private struct ControlFirstMacView: View {
    let isSearching: Bool
    let onAdd: () -> Void
    let onRefresh: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 18) {
                ControlDisplayArt(isOnline: true, height: 168)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bring your Mac to your iPhone.")
                        .font(.title3.weight(.semibold)).tracking(-0.4)
                        .foregroundStyle(ControlDesign.ink)
                    Text("Open Vamp Sync or Vamp Companion on your Mac, then add it here.")
                        .font(.subheadline).foregroundStyle(ControlDesign.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 6)
                HStack(spacing: 10) {
                    ControlPrimaryButton(title: "Add your Mac", symbol: "plus", fillsWidth: false, action: onAdd)
                        .accessibilityIdentifier("control.firstMac")
                    Button(action: onRefresh) {
                        Label(isSearching ? "Looking…" : "Look nearby", systemImage: "dot.radiowaves.left.and.right")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(ControlDesign.ink)
                            .padding(.horizontal, 16).frame(minHeight: 44)
                            .controlGlass(radius: 22, interactive: true, emphasis: .control)
                    }
                    .buttonStyle(ControlPressStyle())
                    .disabled(isSearching)
                }
                .padding(.horizontal, 6).padding(.bottom, 6)
            }
            .padding(10)
            .controlGlass(radius: 26)
            ControlSourceNote()
        }
    }
}

private struct ControlSourceNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ControlMono(text: "Start on your Mac", size: 9)
            Text("Vamp Sync and Vamp Companion show an address and a QR code. Scan it, or enter the address in Add a Mac.")
                .font(.footnote).foregroundStyle(ControlDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .controlGlass(radius: 20)
    }
}

enum ControlMacStatus {
    case online, offline, checking, unverified
    var title: LocalizedStringKey {
        switch self {
        case .online: "Available"
        case .offline: "Offline"
        case .checking: "Checking…"
        case .unverified: "Not verified"
        }
    }
    var tint: Color {
        switch self {
        case .online: ControlDesign.available
        case .unverified: ControlDesign.caution
        case .offline, .checking: ControlDesign.secondary.opacity(0.55)
        }
    }
}

/// One Mac. The featured Mac gets the display artwork and a compact Connect capsule;
/// the rest are slim rows. The whole tile is the button.
struct ControlMacCard: View {
    let name: String
    let source: LocalizedStringKey
    let route: LocalizedStringKey
    let status: ControlMacStatus
    var isFeatured = false
    var stackedArtHeight: CGFloat = 176
    /// Unfolded and iPad: the hero lays out side by side so the artwork keeps a display's proportions.
    var isWide = false
    var wideArtHeight: CGFloat = 168
    let onConnect: () -> Void

    var body: some View {
        Button(action: onConnect) {
            if isFeatured { hero } else { row }
        }
        .buttonStyle(ControlPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(status.title))
        .accessibilityHint(status == .offline ? "Tries to connect again" : "Connects to this Mac")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var hero: some View {
        if isWide {
            HStack(spacing: 20) {
                art(height: wideArtHeight).frame(maxWidth: wideArtHeight * 1.6)
                VStack(alignment: .leading, spacing: 6) {
                    title
                    ControlStatusLine(status: status, route: route)
                    Spacer(minLength: 14)
                    connectCapsule
                }
                .padding(.vertical, 8)
                .frame(height: wideArtHeight)
                Spacer(minLength: 0)
            }
            .padding(10)
            .controlGlass(radius: 26, interactive: true)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                art(height: stackedArtHeight)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        title
                        ControlStatusLine(status: status, route: route)
                    }
                    Spacer(minLength: 8)
                    connectCapsule
                }
                .padding(.horizontal, 6).padding(.bottom, 6)
            }
            .padding(10)
            .controlGlass(radius: 26, interactive: true)
        }
    }

    private func art(height: CGFloat) -> some View {
        ControlDisplayArt(isOnline: status == .online, height: height,
                          statusLabel: status == .online ? "Ready" : status.title)
            .overlay(alignment: .topLeading) {
                ControlSourceTag(source: source).padding(.leading, 12).padding(.top, 22)
            }
    }

    private var title: some View {
        Text(name).font(.title2.weight(.semibold)).tracking(-0.6).lineLimit(1)
            .foregroundStyle(ControlDesign.ink)
    }

    private var connectCapsule: some View {
        HStack(spacing: 6) {
            Text(status == .offline ? "Retry" : "Connect")
            Image(systemName: "arrow.right").font(.footnote.weight(.bold))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(ControlDesign.buttonInk)
        .padding(.horizontal, 16).frame(height: 38)
        .background(ControlDesign.accent, in: Capsule())
    }

    private var row: some View {
        HStack(spacing: 14) {
            ControlSymbol().fill(ControlDesign.ink.opacity(status == .online ? 0.9 : 0.4))
                .frame(width: 19, height: 19)
                .frame(width: 44, height: 44)
                .controlGlass(radius: 13, emphasis: .control)
            VStack(alignment: .leading, spacing: 3) {
                ControlMono(text: source, size: 9)
                Text(name).font(.headline).lineLimit(1).foregroundStyle(ControlDesign.ink)
                ControlStatusLine(status: status, route: route)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.right").font(.footnote.weight(.bold))
                .foregroundStyle(ControlDesign.buttonInk)
                .frame(width: 34, height: 34)
                .background(ControlDesign.accent.opacity(status == .offline ? 0.35 : 1), in: Circle())
        }
        .padding(12).padding(.trailing, 2)
        .controlGlass(radius: 22, interactive: true)
    }
}

private struct ControlStatusLine: View {
    let status: ControlMacStatus
    let route: LocalizedStringKey
    var body: some View {
        // Narrow panels (the Duo cover) keep the status and drop the route rather than truncate it.
        ViewThatFits(in: .horizontal) {
            line(showsRoute: true)
            line(showsRoute: false)
        }
        .font(.footnote).foregroundStyle(ControlDesign.secondary)
    }

    private func line(showsRoute: Bool) -> some View {
        HStack(spacing: 6) {
            ControlPulseDot(color: status.tint, isLive: status == .online)
            Text(status.title).foregroundStyle(status == .online ? ControlDesign.ink : ControlDesign.secondary)
            if showsRoute {
                Text(verbatim: "·")
                Text(route)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

private struct ControlSourceTag: View {
    let source: LocalizedStringKey
    var body: some View {
        ControlMono(text: source, size: 9, color: ControlDesign.ink.opacity(0.75))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(ControlDesign.line, lineWidth: 0.5) }
    }
}

private struct ControlSectionLabel: View {
    let title: LocalizedStringKey
    var body: some View {
        ControlMono(text: title)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ControlLiveSessionPill: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(ControlDesign.available).frame(width: 8, height: 8)
                Text("Session live").font(.subheadline.weight(.semibold)).foregroundStyle(ControlDesign.ink)
                Spacer()
                Label("Return", systemImage: "arrow.up.forward").font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon).foregroundStyle(ControlDesign.ink)
            }
            .padding(.horizontal, 16).frame(minHeight: 48)
            .controlGlass(radius: 24)
        }
        .buttonStyle(ControlPressStyle())
    }
}

private struct ControlAddMacTile: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Add a Mac", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ControlDesign.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .controlGlass(radius: 20, interactive: true)
        }
        .buttonStyle(ControlPressStyle())
        .accessibilityHint("Add a Mac running Vamp Sync or Vamp Companion")
        .accessibilityIdentifier("control.addAnotherMac")
    }
}

struct ControlPrivacyFootnote: View {
    var body: some View {
        Label { ControlMono(text: "Private · Peer approved · No relay", size: 9) } icon: {
            Image(systemName: "lock.shield").font(.caption2).foregroundStyle(ControlDesign.secondary)
        }
            .frame(maxWidth: .infinity).padding(.top, 4)
    }
}

struct ControlNotice: View {
    let message: String
    var onDismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(ControlDesign.caution)
            Text(message).font(.subheadline).foregroundStyle(ControlDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button("Dismiss", systemImage: "xmark", action: onDismiss).labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold)).foregroundStyle(ControlDesign.secondary)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlGlass(radius: 20)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private struct ControlConnectionProgress: View {
    let name: String?
    let fingerprint: String?
    var isApproved = false
    /// Pairing is paused for the user to verify the Mac (or accept an older Vamp Sync).
    var hostConfirmation: PendingHostConfirmation? = nil
    var usesOlderSync = false
    var onConfirmHost: () -> Void = {}
    let onCancel: () -> Void

    private var title: String {
        if let hostConfirmation {
            return hostConfirmation.fingerprint == nil
                ? String(localized: "Older Vamp Sync on this Mac")
                : String(localized: "Is this your Mac?")
        }
        if isApproved { return String(localized: "Approved · starting the stream") }
        return name.map { String(localized: "Connecting to \($0)") } ?? String(localized: "Connecting to your Mac…")
    }

    private var detail: String {
        if let hostConfirmation {
            return hostConfirmation.fingerprint == nil
                ? String(localized: "It can’t prove its identity before pairing. Update Vamp Sync on the Mac, or connect anyway.")
                : String(localized: "Compare this with the Host fingerprint in Vamp Sync on your Mac.")
        }
        if isApproved { return String(localized: "Your Mac accepted this device.") }
        return name == nil ? String(localized: "Checking your private connection.")
                           : String(localized: "First time? Approve this device on your Mac.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if hostConfirmation == nil {
                    ProgressView().tint(ControlDesign.accent)
                } else {
                    Image(systemName: hostConfirmation?.fingerprint == nil ? "exclamationmark.shield" : "checkmark.shield")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(hostConfirmation?.fingerprint == nil ? ControlDesign.caution : ControlDesign.ink)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(detail).font(.footnote).foregroundStyle(ControlDesign.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(ControlDesign.ink)
                    .padding(.horizontal, 14).frame(minHeight: 36)
                    .controlGlass(radius: 18, interactive: true, emphasis: .control)
            }
            if let hostConfirmation {
                if let hostFingerprint = hostConfirmation.fingerprint {
                    fingerprintBox(label: "This Mac’s fingerprint", value: hostFingerprint, accessibilityLabel: "Mac fingerprint")
                }
                ControlPrimaryButton(title: hostConfirmation.fingerprint == nil ? "Connect anyway" : "It matches",
                                     symbol: hostConfirmation.fingerprint == nil ? "arrow.right" : "checkmark",
                                     fillsWidth: false, action: onConfirmHost)
                    .accessibilityIdentifier("control.confirmHost")
            } else if let fingerprint, !isApproved {
                fingerprintBox(label: "Match on your Mac before approving", value: fingerprint, accessibilityLabel: "Device fingerprint")
            }
            if usesOlderSync, hostConfirmation == nil {
                Text(ClientSessionCoordinator.legacyHostNotice)
                    .font(.footnote).foregroundStyle(ControlDesign.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("control.olderSyncNotice")
            }
        }
        .foregroundStyle(ControlDesign.ink).padding(16)
        .frame(maxWidth: ControlDesign.maxWidth).controlGlass(radius: 26, emphasis: .control)
        .animation(.smooth, value: isApproved)
        .animation(.smooth, value: hostConfirmation)
    }

    private func fingerprintBox(label: LocalizedStringKey, value: String, accessibilityLabel: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ControlMono(text: label, size: 9)
            Text(Self.grouped(value))
                .font(.system(size: 13, weight: .medium, design: .monospaced)).lineSpacing(3)
                .foregroundStyle(ControlDesign.ink).textSelection(.enabled)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(value)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(ControlDesign.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Same grouping as Vamp Sync's panel: blocks of 8, four per line.
    static func grouped(_ fingerprint: String) -> String {
        let characters = Array(fingerprint)
        let blocks = stride(from: 0, to: characters.count, by: 8).map {
            String(characters[$0..<min($0 + 8, characters.count)])
        }
        return stride(from: 0, to: blocks.count, by: 4).map {
            blocks[$0..<min($0 + 4, blocks.count)].joined(separator: " ")
        }.joined(separator: "\n")
    }
}

#Preview("Control · First Mac · Light") {
    NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ControlHomeHeader(isEmpty: true, availableCount: 0, appeared: true)
                ControlFirstMacView(isSearching: false, onAdd: {}, onRefresh: {})
                ControlPrivacyFootnote()
            }.padding(24)
        }.background { ControlBackground() }
    }.tint(ControlDesign.accent).preferredColorScheme(.light)
}

#Preview("Control · Your Macs · Dark") {
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            ControlHomeHeader(isEmpty: false, availableCount: 1, appeared: true)
            ControlMacCard(name: "Studio Mac", source: "Vamp Sync", route: "Local network", status: .online, isFeatured: true, onConnect: {})
            ControlSectionLabel(title: "More Macs").padding(.top, 12)
            ControlMacCard(name: "MacBook Pro", source: "Vamp Companion", route: "Tailscale", status: .offline, onConnect: {})
            ControlAddMacTile {}
        }.padding(24)
    }.background { ControlBackground() }.preferredColorScheme(.dark)
}
