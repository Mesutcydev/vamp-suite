import SwiftUI
import CoreImage
import SharedModels
import SharedUtilities

/// Home reads like a short terminal session on clear glass: `vamp status`, the live
/// session as a little live preview of the Mac, then `ls macs`. Every row is a button.
/// The two source protocols (Sync, Companion) stay separate; only their rows share a list.
struct ControlHomeView: View {
    let environment: ClientAppEnvironment
    @ObservedObject var appLock: AppLockService
    @ObservedObject private var hosts: HostsListViewModel
    @ObservedObject private var coordinator: ClientSessionCoordinator
    /// Shared with the Trusted and Settings tabs, so they are owned by RootTabView.
    @ObservedObject var companion: BeetCodeRemoteSessionViewModel
    @StateObject private var renderer: VideoRendererViewModel
    @StateObject private var stats: SessionStatsViewModel
    @StateObject private var appStream: AppStreamViewModel
    /// Free 15-minute daily allowance and the Pro unlock that removes it.
    @ObservedObject var usage: DailyStreamingUsage
    @ObservedObject var unlock: StreamingUnlockStore
    @ObservedObject private var thumbnails = ControlHostThumbnails.shared
    @State private var showsPaywall = false
    @Environment(\.scenePhase) private var scenePhase
    /// Set when leaving the app browser for the desktop, so the desktop view asks the host for its display back.
    @State private var restoresDesktop = false
    @State private var showsAddMac = false
    /// Add a Mac as the right page of an open Duo, beside the list, instead of a sheet across the crease.
    @State private var addsMacOnPage = false
    /// Set once a session has used the half-folded deck, so the fold tip stops explaining it.
    @AppStorage("control.duo.deckLearned") private var deckLearned = false
    @State private var destination: SessionDestination?
    @State private var connectingHost: DiscoveredHostRow?
    @State private var isRefreshing = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var notice: String?
    @State private var pendingForget: BeetCodeRemoteSessionViewModel.SavedAssistant?
    @State private var layoutSize = CGSize.zero
    @State private var appeared = false
    /// Where an open foldable's crease crosses the content, in content points (iPhone Duo inner panel).
    @State private var fold: ControlFold?
    /// Duo panels keep the status bar in a side column, so they have no top inset.
    @State private var windowTopInset: CGFloat = 59
    /// The Mac shown on the stage page of a two-page layout. Rows pick it; nil means the first Mac.
    @State private var stagedHostID: UUID?
    /// Unfolded iPhone Duo (951 pt), iPad, and wide landscape get two pages.
    private var isWide: Bool { layoutSize.width >= ControlDesign.wideMinWidth }
    /// Two pages side by side (book): the library on the left, the stage on the right.
    private var hasPages: Bool { fold.map(\.isVertical) ?? isWide }
    /// The Duo held like a laptop: the stage above the crease, the library below it.
    private var isLaptop: Bool { fold.map { !$0.isVertical } ?? false }

    private enum SessionDestination: String, Identifiable {
        case sync, companion, apps
        var id: String { rawValue }
    }

    init(environment: ClientAppEnvironment, appLock: AppLockService, companion: BeetCodeRemoteSessionViewModel,
         usage: DailyStreamingUsage, unlock: StreamingUnlockStore) {
        self.environment = environment
        self.appLock = appLock
        self.companion = companion
        self.usage = usage
        self.unlock = unlock
        hosts = environment.sharedHostsViewModel
        coordinator = environment.sessionCoordinator
        _renderer = StateObject(wrappedValue: VideoRendererViewModel(webRTCSessionManager: environment.webRTCSessionManager))
        _stats = StateObject(wrappedValue: SessionStatsViewModel(webRTCSessionManager: environment.webRTCSessionManager,
                                                               sessionCoordinator: environment.sessionCoordinator))
        _appStream = StateObject(wrappedValue: AppStreamViewModel(environment: environment))
    }

    private var syncHosts: [DiscoveredHostRow] { hosts.displayHosts.filter { !$0.isTerminalOnlyHost } }
    private var macCount: Int { syncHosts.count + companion.savedAssistants.count }
    private var isEmpty: Bool { macCount == 0 }
    private var availableCount: Int {
        syncHosts.filter(\.isAvailable).count
            + companion.savedAssistants.filter { companion.availabilityByAddress[$0.address] == .reachable }.count
    }
    /// A desktop session kept running behind Home (the stream's Macs button minimizes it).
    private var isLive: Bool { coordinator.phase == .receiving && !coordinator.appStreamingOnlySession }
    private var isBusy: Bool { connectingHost != nil || companion.isPairing }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .background { ControlHingeReader(fold: $fold) }
                    .padding(.horizontal, ControlDesign.gutter)
                    .padding(.top, ControlDesign.gap)
                    .padding(.bottom, ControlDesign.section)
                    .frame(maxWidth: .infinity)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { layoutSize = $0 }
            .animation(.smooth, value: fold)
            .animation(.smooth, value: isWide)
            .animation(.smooth, value: notice)
            .animation(.smooth, value: isLive)
            .task(id: isLive) {
                // Keeps each Mac's card close to its screen as the session ends. Desktop sessions
                // only: an app-window session is not a picture of the Mac.
                while isLive, !Task.isCancelled {
                    if let frame = renderer.latestPixelBuffer, let hostID = coordinator.lastEndpoint?.id {
                        thumbnails.record(frame, for: hostID)
                    }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            #if SCREENSHOTS
            .onReceive(hosts.$hosts) { thumbnails.seedSamples(for: $0.map(\.id)) }
            .task {
                // Screenshot builds only: `-VampSampleSession YES` opens the session view on the first
                // fictional desktop, with no Mac connected.
                guard UserDefaults.standard.bool(forKey: "VampSampleSession"),
                      let path = (UserDefaults.standard.string(forKey: "VampSampleThumbnails") ?? "").split(separator: ",").first,
                      let image = UIImage(contentsOfFile: String(path)) else { return }
                try? await Task.sleep(for: .seconds(1.5))
                destination = .sync
                // After the session view has started its renderer, which clears any frame.
                try? await Task.sleep(for: .seconds(1))
                renderer.showSample(image)
            }
            #endif
            .background { ControlBackground() }
            .refreshable { await refresh() }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { windowTopInset = $0 }
            .onAppear { appeared = true }
            .safeAreaInset(edge: .bottom) {
                Group {
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
                    }
                }
                .frame(width: stagePageWidth)
                .frame(maxWidth: .infinity, alignment: hasPages ? .trailing : .center)
                .padding(.horizontal, ControlDesign.gutter).padding(.bottom, ControlDesign.gap)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if addsMacOnPage, let fold, fold.isVertical, layoutSize.width > 0 {
                ControlAddMacView(hosts: hosts, companion: companion, onConnectSync: { host in
                    addsMacOnPage = false
                    connect(host)
                }, onClose: {
                    addsMacOnPage = false
                    presentPairedCompanion()
                })
                // The right page, from just past the crease to the trailing edge.
                .frame(width: max(layoutSize.width - fold.crease - ControlDesign.gutter - ControlFold.gutter, 320))
                .frame(maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: addsMacOnPage)
        .onChange(of: fold) { _, fold in
            // Folding closed or into a laptop mid-flow carries on as the usual sheet.
            if addsMacOnPage, fold?.isVertical != true {
                addsMacOnPage = false
                showsAddMac = true
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
        .fullScreenCover(item: $destination) { destination in
            switch destination {
            case .sync:
                MirrorFullscreenStreamView(environment: environment, rendererVM: renderer, statsVM: stats,
                                           onClose: closeSession, onOpenApps: openApps,
                                           restoresDesktop: restoresDesktop, onMinimize: minimizeSession)
                    .ignoresSafeArea()
                    .preferredColorScheme(.dark)
                    // Session chrome keeps the monospaced voice it was laid out and tested with.
                    .fontDesign(.monospaced)
            case .apps:
                AppStreamBrowserView(environment: environment, vm: appStream, chrome: .control, onClose: leaveApps)
                    .fontDesign(.monospaced)
            case .companion:
                if let session = companion.session {
                    BeetCodeRemoteView(session: session, clientName: "Vamp Control", hostProductName: "Vamp Companion",
                                       presentationBackground: ControlDesign.canvas, onClose: closeSession,
                                       onRefresh: { await companion.refreshStatus() })
                        .preferredColorScheme(.dark)
                        .fontDesign(.monospaced)
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
            // The cap ends a live session, open or minimized, and presents Pro in its place.
            guard StreamingUnlockStore.isEnforced, !unlock.isEffectivelyUnlocked, !usage.hasTimeRemaining,
                  destination != nil || isLive else { return }
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
            // Companion sessions stream the Mac too, so they use the same daily allowance.
            guard address != nil else {
                if coordinator.phase != .receiving { usage.stopSession() }
                return
            }
            guard allowsNewSession else {
                companion.disconnect()
                if showsAddMac { showsAddMac = false }
                addsMacOnPage = false
                showsPaywall = true
                return
            }
            usage.startSession()
            Task { await coordinator.endSession() }
            if showsAddMac { showsAddMac = false }
            else { addsMacOnPage = false; destination = .companion }
        }
        .onChange(of: companion.lastError) { _, error in
            if !showsAddMac && !addsMacOnPage { notice = error.map(ControlDesign.companionMessage) }
        }
    }

    // MARK: Layout

    @ViewBuilder private var content: some View {
        if isLaptop, let fold {
            // Duo held like a laptop: the Mac's screen stands above the crease, the library lies below.
            VStack(alignment: .leading, spacing: ControlFold.gutter * 2) {
                hero(fitting: fold.crease - ControlFold.gutter)
                    .frame(height: max(fold.crease - ControlFold.gutter, 0), alignment: .bottom)
                library
            }
            .frame(maxWidth: ControlDesign.maxWidth, alignment: .leading)
        } else if hasPages {
            // Unfolded Duo held like a book: the pages split exactly at the crease, so nothing
            // straddles the fold. The library is the left page; the chosen Mac's stage the right.
            HStack(alignment: .top, spacing: fold == nil ? ControlDesign.section : ControlFold.gutter * 2) {
                library.frame(width: libraryPageWidth, alignment: .leading)
                stage.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: ControlDesign.wideMaxWidth, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: ControlDesign.section) {
                status
                notices
                hero
                otherMacs
                promo
                footnote
            }
            .frame(maxWidth: ControlDesign.maxWidth, alignment: .leading)
        }
    }

    /// The left page: what is here, every Mac, and the way to add one.
    private var library: some View {
        VStack(alignment: .leading, spacing: ControlDesign.section) {
            status
            notices
            if hasPages { allMacs } else { otherMacs }
            promo
            if fold != nil, !isEmpty, !deckLearned {
                ControlFoldTip().controlAppear(appeared, delay: 0.18)
            }
            footnote
        }
    }

    private var libraryPageWidth: CGFloat {
        fold.map { max($0.crease - ControlFold.gutter, 240) } ?? 340
    }

    /// The right page's width in the scroll view, for overlays that must stay on it.
    private var stagePageWidth: CGFloat? {
        guard hasPages, layoutSize.width > 0 else { return nil }
        let spacing = fold == nil ? ControlDesign.section : ControlFold.gutter * 2
        let content = min(layoutSize.width - ControlDesign.gutter * 2, ControlDesign.wideMaxWidth)
        return max(content - libraryPageWidth - spacing, 280)
    }

    /// The right page: the chosen Mac as its screen, what the next session will use, and,
    /// on a foldable, what folding it does.
    private var stage: some View {
        VStack(alignment: .leading, spacing: ControlDesign.section) {
            hero
            if !isEmpty && !isLive {
                ControlSessionSetup(environment: environment)
                    .controlAppear(appeared, delay: 0.14)
            }
        }
    }

    /// The shared Vamp Sync promo card: idle only, never while a session is live.
    @ViewBuilder private var promo: some View {
        if !isLive {
            ControlPromoCard().controlAppear(appeared, delay: 0.16)
        }
    }

    private var topBar: some View {
        HStack(spacing: ControlDesign.stack) {
            ControlSerifWordmark()
            Spacer()
            ControlGlassIconButton(symbol: "plus", label: "Add a Mac") { addMac() }
                .accessibilityIdentifier("control.addMacTop")
                .disabled(isBusy)
        }
        .padding(.horizontal, ControlDesign.gutter)
        .padding(.top, windowTopInset < 20 ? ControlDesign.inset : ControlDesign.gap / 2)
        .padding(.bottom, ControlDesign.stack)
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

    /// The home's last comment line, on the shared text column.
    private var footnote: some View {
        ControlPrivacyFootnote().padding(.leading, ControlDesign.inset)
    }

    // MARK: $ vamp status

    /// One meta line: how many Macs are ready, and over which kind of network.
    private var status: some View {
        HStack(spacing: ControlDesign.gap) {
            ControlPulseDot(color: availableCount > 0 ? ControlDesign.available : ControlDesign.secondary.opacity(0.55),
                            isLive: false)
            Group {
                if isEmpty {
                    Text("No Macs yet")
                } else {
                    Text("\(Text("\(availableCount) of \(macCount) ready")) · \(Text(networkLabel))")
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .textCase(.uppercase).tracking(1.1)
            .foregroundStyle(ControlDesign.secondary)
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.leading, ControlDesign.inset)
        .accessibilityElement(children: .combine)
        .controlAppear(appeared)
    }

    private var networkLabel: LocalizedStringKey {
        if let host = syncHosts.first(where: \.isAvailable) ?? syncHosts.first {
            return isTailscale(host) ? "tailscale · no relay" : "local · no relay"
        }
        if let saved = companion.savedAssistants.first {
            return saved.connectionKind == .tailscale ? "tailscale · no relay" : "private · no relay"
        }
        return "—"
    }

    @ViewBuilder private var notices: some View {
        if let notice {
            ControlNotice(message: notice) { self.notice = nil }
        }
        if case .localNetworkIssue(let message) = hosts.state {
            ControlNotice(message: message, onDismiss: nil)
        }
    }

    // MARK: The featured Mac

    /// The Mac whose session is running behind Home, when it is in the list.
    private var liveHost: DiscoveredHostRow? {
        guard isLive else { return nil }
        return syncHosts.first { coordinator.connectedHostName == $0.endpoint.metadata.displayName }
    }
    /// Live: the live Mac (or none, when it was added by address and isn't listed). Otherwise the first Mac.
    private var heroSync: DiscoveredHostRow? {
        if isLive { return liveHost }
        if hasPages || isLaptop, let staged = syncHosts.first(where: { $0.id == stagedHostID }) { return staged }
        return syncHosts.first
    }
    private var heroCompanion: BeetCodeRemoteSessionViewModel.SavedAssistant? {
        !isLive && heroSync == nil ? companion.savedAssistants.first : nil
    }
    private var otherSync: [DiscoveredHostRow] { syncHosts.filter { $0.id != heroSync?.id } }
    private var otherCompanions: [BeetCodeRemoteSessionViewModel.SavedAssistant] {
        companion.savedAssistants.filter { $0.id != heroCompanion?.id }
    }

    /// The hero sized so it fits `height`: its screen narrows until card and heading fit above the crease.
    private func hero(fitting height: CGFloat) -> some View {
        // Heading (~26) + card padding and name row (~94) sit around a 16:10 screen.
        let screenHeight = max(height - 120, 120)
        return hero
            .frame(maxWidth: isEmpty && !isLive ? nil : screenHeight * 1.6 + 16)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var hero: some View {
        if isEmpty && !isLive {
            VStack(alignment: .leading, spacing: ControlDesign.gap) {
                ControlPrompt(command: "ls macs", label: "Your Macs")
                ControlFirstMac(isSearching: isRefreshing, onAdd: addMac,
                                onRefresh: { Task { await refresh() } })
            }
            .controlAppear(appeared, delay: 0.08)
        } else {
            VStack(alignment: .leading, spacing: ControlDesign.gap) {
                ControlPrompt(command: "", label: isLive ? "Live now" : "Your Mac")
                heroCard.disabled(isBusy)
            }
            .controlAppear(appeared, delay: 0.08)
        }
    }

    private var heroName: String {
        if let heroSync { return heroSync.title }
        if isLive { return coordinator.connectedHostName ?? String(localized: "Your Mac") }
        return heroCompanion.map(companionName) ?? ""
    }

    @ViewBuilder private var heroCard: some View {
        if let host = heroSync {
            ControlScreenCard(name: host.title, source: "sync", route: isTailscale(host) ? "tailscale" : "local",
                              status: syncStatus(host), isLive: isLive, renderer: renderer,
                              onPrimary: { isLive ? openSession() : connect(host) }, onEnd: closeSession,
                              thumbnail: thumbnails.images[host.id])
                .contextMenu { syncMenu(host) }
        } else if isLive {
            ControlScreenCard(name: heroName, source: "sync", route: "private", status: .online, isLive: true,
                              renderer: renderer, onPrimary: openSession, onEnd: closeSession)
        } else if let saved = heroCompanion {
            ControlScreenCard(name: companionName(saved), source: "companion",
                              route: saved.connectionKind == .tailscale ? "tailscale" : "private",
                              status: companionStatus(saved), isLive: false, renderer: renderer,
                              onPrimary: { connectCompanion(saved) }, onEnd: {})
                .contextMenu { Button("Forget Mac", systemImage: "trash", role: .destructive) { pendingForget = saved } }
        }
    }

    // MARK: $ ls macs

    @ViewBuilder private var otherMacs: some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: ControlDesign.gap) {
                if !otherSync.isEmpty || !otherCompanions.isEmpty {
                    HStack {
                        ControlPrompt(command: "", label: "More Macs · \(otherSync.count + otherCompanions.count)")
                        Spacer()
                        Button(isRefreshing ? "Looking…" : "Look nearby") { Task { await refresh() } }
                            .font(.footnote.weight(.semibold)).foregroundStyle(ControlDesign.secondary)
                            .disabled(isRefreshing)
                            .padding(.trailing, ControlDesign.gap)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(otherSync.enumerated()), id: \.element.id) { index, host in
                            if index > 0 { ControlRule().padding(.leading, ControlMacRow.textLeading) }
                            syncRow(host)
                        }
                        ForEach(Array(otherCompanions.enumerated()), id: \.element.id) { index, saved in
                            if index > 0 || !otherSync.isEmpty { ControlRule().padding(.leading, ControlMacRow.textLeading) }
                            companionRow(saved)
                        }
                    }
                    .controlGlass()
                    .disabled(isBusy)
                }
                ControlAddRow(action: addMac)
                    .disabled(isBusy)
            }
            .controlAppear(appeared, delay: 0.12)
        }
    }

    /// Two-page library: every Mac, the one on the stage marked. A row stages its Mac; the
    /// stage connects. Companion Macs still connect from their row.
    @ViewBuilder private var allMacs: some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: ControlDesign.gap) {
                HStack {
                    ControlPrompt(command: "ls macs", label: "Your Macs · \(macCount)")
                    Spacer()
                    Button(isRefreshing ? "Looking…" : "Look nearby") { Task { await refresh() } }
                        .font(.footnote.weight(.semibold)).foregroundStyle(ControlDesign.secondary)
                        .disabled(isRefreshing)
                        .padding(.trailing, ControlDesign.gap)
                }
                VStack(spacing: 0) {
                    ForEach(Array(syncHosts.enumerated()), id: \.element.id) { index, host in
                        if index > 0 { ControlRule().padding(.leading, ControlMacRow.textLeading) }
                        let isStaged = host.id == heroSync?.id
                        ControlMacRow(name: host.title, source: "sync", route: isTailscale(host) ? "tailscale" : "local",
                                      status: syncStatus(host), thumbnail: thumbnails.images[host.id],
                                      isStaged: isStaged, isLive: isStaged && isLive) {
                            AppHaptics.selection()
                            stagedHostID = host.id
                        }
                        .contextMenu { syncMenu(host) }
                    }
                    ForEach(Array(otherCompanions.enumerated()), id: \.element.id) { index, saved in
                        if index > 0 || !syncHosts.isEmpty { ControlRule().padding(.leading, ControlMacRow.textLeading) }
                        companionRow(saved)
                    }
                }
                .controlGlass()
                .disabled(isBusy || isLive)
                ControlAddRow(action: addMac)
                    .disabled(isBusy)
            }
            .controlAppear(appeared, delay: 0.12)
        }
    }

    private func syncStatus(_ host: DiscoveredHostRow) -> ControlMacStatus {
        host.endpoint.metadata.appVersion == "unknown" && !host.isSaved ? .unverified : (host.isAvailable ? .online : .offline)
    }

    @ViewBuilder private func syncMenu(_ host: DiscoveredHostRow) -> some View {
        if host.isSaved {
            Button("Remove from Macs", systemImage: "minus.circle", role: .destructive) {
                hosts.removeSavedHost(host.id)
            }
        }
        if !host.isAvailable && !isTailscale(host) {
            Button("Wake Mac", systemImage: "sun.max") { wake(host) }
        }
    }

    /// Store builds stop new sessions once the free daily minutes are used; website builds are never gated.
    private var allowsNewSession: Bool {
        !StreamingUnlockStore.isEnforced || unlock.isEffectivelyUnlocked || usage.hasTimeRemaining
    }

    private func connectCompanion(_ saved: BeetCodeRemoteSessionViewModel.SavedAssistant) {
        guard allowsNewSession else {
            showsPaywall = true
            return
        }
        connectionTask?.cancel()
        companion.cancelConnectionAttempt()
        connectionTask = Task {
            await coordinator.endSession()
            guard !Task.isCancelled else { return }
            await companion.reconnect(saved)
        }
    }

    private func syncRow(_ host: DiscoveredHostRow) -> some View {
        ControlMacRow(name: host.title, source: "sync", route: isTailscale(host) ? "tailscale" : "local",
                      status: syncStatus(host), thumbnail: thumbnails.images[host.id]) { connect(host) }
            .contextMenu { syncMenu(host) }
    }

    private func companionRow(_ saved: BeetCodeRemoteSessionViewModel.SavedAssistant) -> some View {
        ControlMacRow(name: companionName(saved), source: "companion",
                      route: saved.connectionKind == .tailscale ? "tailscale" : "private",
                      status: companionStatus(saved)) { connectCompanion(saved) }
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

    // MARK: Actions

    private func connect(_ host: DiscoveredHostRow) {
        guard !host.isTerminalOnlyHost else { return }
        guard allowsNewSession else {
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

    /// Add a Mac: beside the list on an open Duo held like a book, a sheet everywhere else.
    private func addMac() {
        if fold?.isVertical == true { addsMacOnPage = true } else { showsAddMac = true }
    }

    private func presentPairedCompanion() {
        if companion.session != nil { destination = .companion }
    }

    private func openSession() {
        AppHaptics.selection()
        restoresDesktop = false
        destination = .sync
    }

    /// Back to Home with the session still running; the live preview card brings it back.
    private func minimizeSession() {
        destination = nil
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

// MARK: - Pieces

/// `key   value` — one line of `vamp status`.
private struct ControlKeyRow<Value: View>: View {
    let key: String
    @ViewBuilder var value: Value
    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: key).foregroundStyle(ControlDesign.secondary)
                .frame(width: 96, alignment: .leading)
            HStack(spacing: ControlDesign.gap) { value }
                .foregroundStyle(ControlDesign.ink)
            Spacer(minLength: 0)
        }
        .font(.body)
        .lineLimit(1)
        .frame(minHeight: ControlDesign.lineHeight)
    }
}

/// The stage page's choices for the next session. They are the Settings tab's own settings,
/// so changing one here changes it there.
private struct ControlSessionSetup: View {
    @ObservedObject var environment: ClientAppEnvironment

    var body: some View {
        ControlConfigSection(command: "config stream", label: "Next session") {
            ControlChoiceRow(key: "Quality", selection: $environment.preferredQualityPreset,
                             options: [(.performance, "Eco"), (.balanced, "Balanced"),
                                       (.quality, "Sharp"), (.ultra, "Full")])
            ControlRule()
            Toggle("View only", isOn: $environment.prefersViewOnly)
        }
        .toggleStyle(ControlSwitchStyle())
    }
}

/// What folding does, said once on an open Duo's stage page.
private struct ControlFoldTip: View {
    var body: some View {
        HStack(alignment: .top, spacing: ControlDesign.stack) {
            Image(systemName: "laptopcomputer")
                .font(.title3).foregroundStyle(ControlDesign.ink)
                .frame(width: 44, height: 44)
                .background(ControlDesign.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                ControlMono(text: "Fold it halfway", size: 10.5)
                Text("In a session, your Mac’s screen takes one side and a trackpad the other.")
                    .font(.subheadline).foregroundStyle(ControlDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(ControlDesign.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlGlass()
        .accessibilityElement(children: .combine)
    }
}

/// Hairline between terminal lines inside one glass block.
struct ControlRule: View {
    var body: some View {
        Rectangle().fill(ControlDesign.line).frame(height: 0.5)
    }
}

enum ControlMacStatus {
    case online, offline, checking, unverified
    var title: LocalizedStringKey {
        switch self {
        case .online: "ready"
        case .offline: "offline"
        case .checking: "checking…"
        case .unverified: "not verified"
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

/// One Mac, one line: `● studio-mac   sync · local   connect →`. The whole line is the button.
private struct ControlMacRow: View {
    let name: String
    let source: LocalizedStringKey
    let route: LocalizedStringKey
    let status: ControlMacStatus
    /// The last frame of this run's session with the Mac, if any.
    var thumbnail: UIImage?
    /// Two-page library: this Mac is on the stage, so the row shows that instead of Connect.
    var isStaged: Bool?
    var isLive = false
    let action: () -> Void

    /// Where the name starts inside the list; dividers start here too.
    static let textLeading = ControlDesign.inset + 8 + ControlDesign.gap

    private var verb: LocalizedStringKey { status == .offline ? "Retry" : "Connect" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: ControlDesign.stack) {
                ControlPulseDot(color: status.tint, isLive: false)
                    .frame(width: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: name).font(.body.weight(.semibold)).foregroundStyle(ControlDesign.ink)
                    Text("\(Text(source)) · \(status == .online ? Text(route) : Text(status.title))")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(ControlDesign.secondary)
                }
                .lineLimit(1)
                .opacity(status == .offline ? 0.8 : 1)
                Spacer(minLength: ControlDesign.gap)
                if let thumbnail {
                    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                    Color.black
                        .overlay { Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill) }
                        .frame(width: 52, height: 33)
                        .clipShape(shape)
                        .overlay { shape.strokeBorder(Color.white.opacity(0.12)) }
                        .saturation(status == .offline ? 0.35 : 1)
                        .accessibilityHidden(true)
                }
                if let isStaged {
                    Image(systemName: isLive ? "dot.radiowaves.left.and.right" : "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(isStaged ? ControlDesign.ink : ControlDesign.secondary.opacity(0.6))
                        .frame(width: 20)
                } else {
                    ControlCapsule(title: verb)
                }
            }
            .padding(.horizontal, ControlDesign.inset)
            .frame(minHeight: ControlDesign.rowHeight)
            .background { if isStaged == true { ControlDesign.ink.opacity(0.07) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlRowPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(isLive ? Text("live") : Text(status.title))
        .accessibilityHint(isStaged == nil ? (status == .offline ? "Tries to connect again" : "Connects to this Mac")
                                           : "Shows this Mac beside the list")
        .accessibilityAddTraits(isStaged == true ? [.isButton, .isSelected] : .isButton)
    }
}

/// The featured Mac, drawn as its screen: the live picture while a session runs
/// behind Home, a waiting shell prompt otherwise. The whole screen is the button.
private struct ControlScreenCard: View {
    let name: String
    let source: LocalizedStringKey
    let route: LocalizedStringKey
    let status: ControlMacStatus
    let isLive: Bool
    @ObservedObject var renderer: VideoRendererViewModel
    let onPrimary: () -> Void
    let onEnd: () -> Void
    /// The last frame of this run's session with the Mac, shown while no session runs.
    var thumbnail: UIImage?

    /// `Mac M4` → `mac-m4`, the way a shell would name it.
    static func slug(_ name: String) -> String { name.lowercased().replacingOccurrences(of: " ", with: "-") }

    /// The live picture keeps the stream's own shape; the waiting screen is a 16:10 display.
    private var aspect: CGFloat {
        guard isLive, let size = renderer.frameSize, size.height > 0 else { return 16 / 10 }
        return size.width / size.height
    }
    /// Concentric with the card: card radius minus its 8 pt padding.
    private let screen = RoundedRectangle(cornerRadius: ControlDesign.innerRadius, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onPrimary) {
                // Full card width. A portrait stream stays its own shape, centred on the glass,
                // and never grows taller than a little more than the card is wide.
                Color.clear
                    .aspectRatio(max(aspect, 0.9), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        display
                            .aspectRatio(aspect, contentMode: .fit)
                            .clipShape(screen)
                            .overlay { screen.strokeBorder(Color.white.opacity(0.1)) }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(ControlPressStyle())
            .accessibilityLabel(isLive ? Text("Open \(name)") : Text("Connect to \(name)"))

            HStack(spacing: ControlDesign.gap) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: name).font(.title3.weight(.semibold)).foregroundStyle(ControlDesign.ink)
                    HStack(spacing: ControlDesign.gap) {
                        ControlPulseDot(color: isLive ? ControlDesign.available : status.tint, isLive: isLive)
                            .frame(width: 8)
                        // The dot carries readiness; the words say where, or what's wrong.
                        Text("\(Text(source)) · \(isLive ? Text("live") : status == .online ? Text(route) : Text(status.title))")
                    }
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(ControlDesign.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if isLive {
                    Button(action: onEnd) {
                        ControlCapsule(title: "End", style: .end, height: ControlDesign.buttonHeight)
                    }
                    .buttonStyle(ControlPressStyle())
                    .accessibilityLabel("End session")
                }
                ControlPrimaryButton(title: isLive ? "Open" : status == .offline ? "Retry" : "Connect",
                                     symbol: isLive ? "arrow.up.right" : "arrow.right", action: onPrimary)
            }
            // 8 pt card padding + 8 here puts the name on the shared 16 pt text column.
            .padding(.horizontal, ControlDesign.gap)
            .padding(.top, ControlDesign.stack)
            .padding(.bottom, ControlDesign.gap)
        }
        .padding(ControlDesign.gap)
        .controlGlass()
    }

    @ViewBuilder private var display: some View {
        if isLive {
            ZStack {
                Color.black
                VideoFrameRendererView(pixelBuffer: nil, renderer: renderer)
                if renderer.latestPixelBuffer == nil { ProgressView().tint(.white) }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    ControlPulseDot(color: ControlDesign.available, isLive: true)
                    Text(verbatim: "LIVE").font(.system(size: 10.5, weight: .semibold, design: .monospaced)).tracking(1.2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, ControlDesign.stack - 2).padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(ControlDesign.stack - 2)
            }
        } else if let thumbnail {
            Color.black
                .overlay { Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill) }
                .clipped()
                .saturation(status == .offline ? 0.35 : 1)
                .overlay(alignment: .bottomLeading) {
                    Text(verbatim: "LAST SESSION")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced)).tracking(1.2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, ControlDesign.stack - 2).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(ControlDesign.stack - 2)
                }
                .accessibilityHidden(true)
        } else {
            idleScreen
        }
    }

    /// A dark display holding a shell that waits for you, whatever the app's appearance.
    private var idleScreen: some View {
        let slug = Self.slug(name)
        let green = Color(hex: 0x3DD07A)
        let comment: LocalizedStringKey = switch status {
        case .online: "# \(slug) is ready"
        case .checking: "# looking for \(slug)…"
        case .offline: "# \(slug) is offline · open Vamp Sync on it"
        case .unverified: "# \(slug) isn’t verified yet"
        }
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hex: 0x1C1C1C), Color(hex: 0x0B0B0B)], startPoint: .top, endPoint: .bottom)
            ControlSymbol().fill(Color.white.opacity(0.06))
                .frame(width: 72, height: 72)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                Text(comment).foregroundStyle(status == .online ? green : Color.white.opacity(0.5))
                HStack(spacing: 0) {
                    Text("\(Text(verbatim: "$").foregroundStyle(green)) vamp connect \(slug) ")
                        .foregroundStyle(Color.white.opacity(0.9))
                    ControlCursor()
                }
            }
            .font(.system(.subheadline, design: .monospaced))
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(ControlDesign.inset)
        }
        .accessibilityHidden(true)
    }
}

/// A blinking block cursor. Still under Reduce Motion and in the background.
private struct ControlCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.55)) { context in
            let on = reduceMotion || scenePhase != .active
                || Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 9, height: 17).opacity(on ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}

/// First run: one sentence and one obvious next step.
private struct ControlFirstMac: View {
    let isSearching: Bool
    let onAdd: () -> Void
    let onRefresh: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: ControlDesign.inset) {
            VStack(alignment: .leading, spacing: 4) {
                Text("No Macs yet").font(.title3.weight(.semibold)).foregroundStyle(ControlDesign.ink)
                Text("Open Vamp Sync on your Mac, then add it here.")
                    .font(.subheadline).foregroundStyle(ControlDesign.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: ControlDesign.gap) {
                ControlPrimaryButton(title: "Add your Mac", symbol: "plus", fillsWidth: false, action: onAdd)
                    .accessibilityIdentifier("control.firstMac")
                Button(action: onRefresh) {
                    ControlCapsule(title: isSearching ? "Looking…" : "Look nearby", height: ControlDesign.buttonHeight)
                }
                .buttonStyle(ControlPressStyle())
                .disabled(isSearching)
            }
        }
        .padding(ControlDesign.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlGlass()
    }
}

/// `+ add a mac`, drawn like a pending line: dashed, quiet, always last.
private struct ControlAddRow: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            // Same slot as a Mac row's dot, so "add a mac" starts where the Mac names do.
            HStack(spacing: ControlDesign.stack) {
                Image(systemName: "plus").font(.subheadline.weight(.bold))
                    .foregroundStyle(ControlDesign.endInk).frame(width: 8)
                Text("Add a Mac").foregroundStyle(ControlDesign.ink)
            }
                .font(.body.weight(.semibold))
                .padding(.horizontal, ControlDesign.inset)
                .frame(maxWidth: .infinity, minHeight: ControlDesign.lineHeight, alignment: .leading)
                .overlay {
                    RoundedRectangle(cornerRadius: ControlDesign.radius, style: .continuous)
                        .strokeBorder(ControlDesign.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(ControlPressStyle())
        .accessibilityLabel("Add a Mac")
        .accessibilityHint("Add a Mac running Vamp Sync")
        .accessibilityIdentifier("control.addMac")
    }
}

struct ControlPrivacyFootnote: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ControlDesign.secondary)
            ControlMono(text: "Private · peer approved · no relay")
        }
        .accessibilityElement(children: .combine)
    }
}

struct ControlNotice: View {
    let message: String
    var onDismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ControlDesign.stack) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(ControlDesign.caution)
            Text(message).font(.subheadline).foregroundStyle(ControlDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button("Dismiss", systemImage: "xmark", action: onDismiss).labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold)).foregroundStyle(ControlDesign.secondary)
                    .frame(width: ControlDesign.smallButtonHeight, height: ControlDesign.smallButtonHeight).contentShape(Rectangle())
            }
        }
        .padding(.leading, ControlDesign.inset).padding(.trailing, ControlDesign.gap).padding(.vertical, ControlDesign.stack)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlGlass()
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

struct ControlConnectionProgress: View {
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
        VStack(alignment: .leading, spacing: ControlDesign.stack) {
            HStack(alignment: .top, spacing: ControlDesign.stack) {
                if hostConfirmation == nil {
                    ProgressView().tint(ControlDesign.accent)
                } else {
                    Image(systemName: hostConfirmation?.fingerprint == nil ? "exclamationmark.shield" : "checkmark.shield")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(hostConfirmation?.fingerprint == nil ? ControlDesign.caution : ControlDesign.ink)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.footnote).foregroundStyle(ControlDesign.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(ControlDesign.ink)
                    .padding(.horizontal, ControlDesign.stack).frame(minHeight: ControlDesign.smallButtonHeight)
                    .controlGlass(radius: ControlDesign.smallButtonHeight / 2, interactive: true, emphasis: .control)
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
        .foregroundStyle(ControlDesign.ink).padding(ControlDesign.inset)
        .frame(maxWidth: ControlDesign.maxWidth).controlGlass(emphasis: .control)
        .animation(.smooth, value: isApproved)
        .animation(.smooth, value: hostConfirmation)
    }

    private func fingerprintBox(label: LocalizedStringKey, value: String, accessibilityLabel: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: ControlDesign.gap) {
            ControlMono(text: label, size: 9)
            Text(Self.grouped(value))
                .font(.system(size: 13, weight: .medium, design: .monospaced)).lineSpacing(3)
                .foregroundStyle(ControlDesign.ink).textSelection(.enabled)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(value)
        }
        .padding(ControlDesign.stack).frame(maxWidth: .infinity, alignment: .leading)
        .background(ControlDesign.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: ControlDesign.innerRadius, style: .continuous))
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
    ScrollView {
        VStack(alignment: .leading, spacing: ControlDesign.section) {
            ControlPrompt(command: "ls macs", label: "Your Macs")
            ControlFirstMac(isSearching: false, onAdd: {}, onRefresh: {})
            ControlPrivacyFootnote()
        }.padding(ControlDesign.gutter)
    }
    .background { ControlBackground() }.fontDesign(.monospaced)
    .tint(ControlDesign.accent).preferredColorScheme(.light)
}

#Preview("Control · Your Macs · Dark") {
    ScrollView {
        VStack(alignment: .leading, spacing: ControlDesign.gap) {
            ControlPrompt(command: "ls macs", label: "Your Macs")
            VStack(spacing: 0) {
                ControlMacRow(name: "Studio Mac", source: "sync", route: "local", status: .online, action: {})
                ControlRule().padding(.leading, ControlMacRow.textLeading)
                ControlMacRow(name: "MacBook Pro", source: "companion", route: "tailscale", status: .offline, action: {})
            }.controlGlass()
            ControlAddRow {}
        }.padding(ControlDesign.gutter)
    }
    .background { ControlBackground() }.fontDesign(.monospaced).preferredColorScheme(.dark)
}

/// The last frame of each Mac's session in this run, for its card. Memory only: a Mac's
/// screen is never written to disk, so after a relaunch the cards show the prompt again
/// until the next session.
@MainActor
final class ControlHostThumbnails: ObservableObject {
    static let shared = ControlHostThumbnails()
    @Published private(set) var images: [UUID: UIImage] = [:]
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    func record(_ frame: CVPixelBuffer, for hostID: UUID) {
        let image = CIImage(cvPixelBuffer: frame)
        let scale = min(1, 640 / max(image.extent.width, 1))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = Self.context.createCGImage(small, from: small.extent) else { return }
        images[hostID] = UIImage(cgImage: cg)
    }

    #if SCREENSHOTS
    /// Screenshot builds only: each Mac shows a fictional desktop from `-VampSampleThumbnails`
    /// (comma-separated paths), so store images never carry a real screen.
    func seedSamples(for ids: [UUID]) {
        let paths = (UserDefaults.standard.string(forKey: "VampSampleThumbnails") ?? "").split(separator: ",")
        let samples = paths.compactMap { UIImage(contentsOfFile: String($0)) }
        guard !samples.isEmpty else { return }
        for (index, id) in ids.enumerated() where images[id] == nil { images[id] = samples[index % samples.count] }
    }
    #endif
}
