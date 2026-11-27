import SwiftUI
import AppKit
import Discovery
import SharedModels

/// Home of Vamp Control for macOS. Toolbar tabs switch between your Macs, Vamp
/// Assistant and trusted Macs; the Macs tab shows a grid of cards, the Vamp Sync
/// promo card and the add-by-address bar, or the discovery radar while nothing
/// has been found yet.
struct MacHostsScreen: View {
    enum Tab: Hashable { case macs, assistant, trusted }

    @ObservedObject var environment: ClientAppEnvironment
    @ObservedObject var assistant: MacAssistantSession
    @ObservedObject private var hostsVM: HostsListViewModel
    @ObservedObject private var coordinator: ClientSessionCoordinator
    @StateObject private var trustedVM: ClientTrustedHostsViewModel

    @State private var tab: Tab = .macs
    /// Store screenshots launch with `-VampSampleHosts YES`: the real interface with fictional Macs,
    /// so nobody's network names or trusted devices end up in public images. Read from the launch
    /// arguments only; nothing is saved and every other behaviour is unchanged.
    private static let usesSampleHosts = UserDefaults.standard.bool(forKey: "VampSampleHosts")
    private var displayHosts: [DiscoveredHostRow] { Self.usesSampleHosts ? MacSampleHosts.rows : hostsVM.displayHosts }
    @AppStorage(MacExperiments.assistantKey) private var assistantEnabled = false
    @State private var manualAddress: String = ""
    @State private var manualAddError: String?
    /// True once the first scan has produced a result, so repeated background
    /// re-scans (which momentarily reset the shared state to `.loading`) don't
    /// blow the content away and cause flicker.
    @State private var hasCompletedFirstScan = false

    /// The host currently being woken (drives its button spinner), plus a
    /// transient toast describing what the wake attempt actually dispatched.
    @State private var wakingHostID: DiscoveredHostRow.ID?
    @State private var wakeFeedback: String?
    @State private var wakeFeedbackIsError = false

    /// Set when the user taps Connect on a Tailscale/relay host while the VPN is
    /// off; drives a warning alert so we don't fire a doomed long-timeout connect
    /// to an address that can't resolve without Tailscale up.
    @State private var pendingTailscaleHost: DiscoveredHostRow?
    @State private var showsAssistantPairing = false
    @State private var confirmForgetAssistant = false

    @ObservedObject private var nicknames = MacHostNicknameStore.shared
    /// The host being renamed, plus the in-progress text.
    @State private var renamingHost: DiscoveredHostRow?
    @State private var renameText = ""

    /// The manual-add field is the only text control on the screen, so AppKit
    /// made it first responder on launch — a blue focus ring shouting for
    /// attention before the user has any intent to type an address.
    @FocusState private var manualFieldFocused: Bool

    /// The shell's daily-limit gate. When it refuses, the shell presents Vamp Pro instead of connecting.
    private let allowsNewSession: () -> Bool
    private let onSessionBlocked: () -> Void

    init(environment: ClientAppEnvironment, assistant: MacAssistantSession,
         allowsNewSession: @escaping () -> Bool = { true },
         onSessionBlocked: @escaping () -> Void = {}) {
        self.environment = environment
        self.assistant = assistant
        self.hostsVM = environment.sharedHostsViewModel
        self.coordinator = environment.sessionCoordinator
        _trustedVM = StateObject(wrappedValue: ClientTrustedHostsViewModel(peerStore: environment.trustedPeerStore))
        self.allowsNewSession = allowsNewSession
        self.onSessionBlocked = onSessionBlocked
    }

    var body: some View {
        Group {
            switch tab {
            case .macs: macsTab
            case .assistant:
                // Falls back to Macs if the experimental switch is turned off while this tab is open.
                if assistantEnabled { assistantTab } else { macsTab }
            case .trusted: trustedTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacBrand.pageBackdrop)
        .defaultFocus($manualFieldFocused, false)
        .toolbar {
            wordmarkItem
            tabsItem
            statusItem
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await hostsVM.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isScanning)
                .help("Search the local network again")
            }
            ToolbarItem(placement: .primaryAction) { settingsButton }
        }
        .task { await hostsVM.start() }
        .task { await trustedVM.refresh() }
        #if SCREENSHOTS
        .onAppear { MacHostThumbnails.shared.seedSamples(for: displayHosts.map(\.id)) }
        #endif
        .onChange(of: hostsVM.state) { state in
            if state != .loading { hasCompletedFirstScan = true }
        }
        .overlay {
            if isConnecting {
                connectingOverlay
            }
        }
        .overlay(alignment: .bottom) {
            if let wakeFeedback {
                wakeToast(wakeFeedback, isError: wakeFeedbackIsError)
                    .padding(.bottom, 76)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Warn before connecting to a Tailscale/relay host with the VPN off —
        // otherwise the connect attempt just hangs until a long timeout because
        // the ts.net / 100.x address can't resolve without Tailscale running.
        .alert("Turn on Tailscale", isPresented: Binding(
            get: { pendingTailscaleHost != nil },
            set: { if !$0 { pendingTailscaleHost = nil } }
        )) {
            Button("Open Tailscale") {
                openTailscaleApp()
                pendingTailscaleHost = nil
            }
            Button("Connect anyway") {
                let host = pendingTailscaleHost
                pendingTailscaleHost = nil
                if let host { startConnect(to: host) }
            }
            Button("Cancel", role: .cancel) { pendingTailscaleHost = nil }
        } message: {
            Text("This looks like a Tailscale address. Make sure the Tailscale VPN is connected on this Mac, then try again — otherwise the host can’t be reached.")
        }
        .sheet(isPresented: $showsAssistantPairing) {
            MacAssistantPairingSheet(model: assistant)
        }
        .confirmationDialog("Forget the saved Assistant?", isPresented: $confirmForgetAssistant, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { assistant.disconnect(forget: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to pair this Mac again to use the Assistant.")
        }
        .sheet(item: $renamingHost) { row in
            MacRenameHostSheet(
                advertisedName: row.endpoint.metadata.displayName,
                text: $renameText,
                onCancel: { renamingHost = nil },
                onSave: {
                    nicknames.setNickname(renameText, for: row.endpoint)
                    renamingHost = nil
                }
            )
        }
    }

    private var isConnecting: Bool {
        switch coordinator.phase {
        case .connecting, .signalingConnected, .negotiating:
            return true
        default:
            return false
        }
    }

    private var isScanning: Bool { hostsVM.state == .loading }

    private var isTailscaleActive: Bool { coordinator.tailscaleVPNStatus == .active }

    // MARK: - Toolbar

    /// Leading and unchromed: a wordmark, not a control.
    @ToolbarContentBuilder
    private var wordmarkItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { MacBrandWordmark() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { MacBrandWordmark() }
        }
    }

    /// The tabs draw their own glass capsule, so macOS 26's automatic one is hidden.
    @ToolbarContentBuilder
    private var tabsItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) { homeTabs }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { homeTabs }
        }
    }

    private var homeTabs: some View {
        MacHomeTabs(selection: $tab,
                    showsAssistant: assistantEnabled,
                    macCount: displayHosts.count,
                    assistantIsSaved: assistant.savedAddress != nil,
                    trustedCount: Self.usesSampleHosts ? 3 : trustedVM.trustedHosts.count)
    }

    /// Ambient status, not a control: no automatic glass behind it.
    @ToolbarContentBuilder
    private var statusItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { discoveryStatus }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { discoveryStatus }
        }
    }

    private var discoveryStatus: some View {
        MacStatusPill(title: discoveryStatusText, tone: discoveryTone, isWorking: isScanning)
            .accessibilityLabel("Discovery status")
            .accessibilityValue(discoveryStatusText)
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
        }
    }

    private var discoveryTone: MacStatusTone {
        if case .localNetworkIssue = hostsVM.state { return .attention }
        return displayHosts.contains(where: \.isAvailable) ? .live : .idle
    }

    /// One line, one fact: "2 of 2 online" says both counts at once.
    private var discoveryStatusText: String {
        if case .localNetworkIssue = hostsVM.state { return "Network blocked" }
        let hosts = displayHosts
        guard !hosts.isEmpty else { return isScanning ? "Scanning" : "No Macs" }
        let online = hosts.filter(\.isAvailable).count
        if online == hosts.count {
            return "\(online) online"
        }
        return "\(online) of \(hosts.count) online"
    }

    // MARK: - Macs tab

    private var macsTab: some View {
        VStack(spacing: 0) {
            macsContent
            manualEntryBar
        }
    }

    @ViewBuilder
    private var macsContent: some View {
        if case .localNetworkIssue(let message) = hostsVM.state {
            discoveryView(issue: message)
        } else if !displayHosts.isEmpty {
            hostsGrid
        } else {
            discoveryView(issue: nil)
        }
    }

    private var networkMeta: String {
        isTailscaleActive ? "Local network · Tailscale" : "Local network"
    }

    private func pageHeader(meta: String, title: String, lede: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            MacMetaLabel(text: meta)
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.6)
                .accessibilityAddTraits(.isHeader)
            Text(lede)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hostsGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageHeader(meta: networkMeta,
                           title: "Your Macs",
                           lede: "Pick a Mac to see and control it. Vamp Sync needs to be open on that Mac.")

                if let message = errorBannerMessage {
                    noticeBanner(message)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 232, maximum: 380), spacing: 18, alignment: .top)],
                          alignment: .leading, spacing: 18) {
                    ForEach(displayHosts) { row in
                        MacHostCard(
                            row: row,
                            displayName: nicknames.displayName(for: row.endpoint),
                            isRenamed: nicknames.nickname(for: row.endpoint) != nil,
                            isBusy: isConnecting,
                            canWake: canWake(row),
                            isWaking: wakingHostID == row.id,
                            isPrimary: row.id == displayHosts.first(where: \.isAvailable)?.id,
                            onConnect: { connect(to: row) },
                            onWake: { sendWake(row) },
                            onRename: { beginRename(row) },
                            onResetName: { nicknames.setNickname(nil, for: row.endpoint) },
                            onToggleSave: {
                                if row.isSaved { hostsVM.removeSavedHost(row.id) }
                                else { hostsVM.saveHost(row.id) }
                            }
                        )
                    }
                }

                MacSyncPromoCard(wide: true)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
        }
    }

    private func noticeBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            MacStatusDot(tone: .attention)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macCard(radius: 12)
    }

    // MARK: - Discovery (nothing found yet, scanning, or blocked)

    private func discoveryView(issue: String?) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 14) {
                    DiscoveryRadar(isScanning: isScanning && issue == nil, isBlocked: issue != nil)
                        .padding(.bottom, 4)
                    Text(issue != nil ? "Local network unavailable" : (isScanning ? "Looking for your Macs" : "No Macs found yet"))
                        .font(.system(size: 24, weight: .bold))
                        .tracking(-0.4)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(issue ?? "Open Vamp Sync on the Mac you want to reach. It shows up here as soon as it is found.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 440)
                    discoveryChecklist(blocked: issue != nil)
                    MacSyncPromoCard(wide: true)
                        .frame(maxWidth: 640)
                        .padding(.top, 6)
                    Link("Why can’t I see my Mac?", destination: VampProductLinks.support)
                        .buttonStyle(MacCapsuleButtonStyle(kind: .quiet))
                }
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
    }

    private func discoveryChecklist(blocked: Bool) -> some View {
        VStack(spacing: 0) {
            DiscoveryChecklistRow(
                mark: blocked ? .blocked : (isScanning ? .working : .idle),
                title: "Local network",
                detail: blocked ? "Allow Local Network for Vamp Control in System Settings"
                    : (isScanning ? "Searching with Bonjour on Wi-Fi and Ethernet" : "No Vamp Sync answered yet")
            ) {
                if isScanning && !blocked {
                    MacMetaLabel(text: "Searching")
                } else {
                    Button("Search again") { Task { await hostsVM.refresh() } }
                        .buttonStyle(MacCapsuleButtonStyle(kind: .quiet))
                        .disabled(isScanning)
                }
            }
            Divider().opacity(0.5)
            DiscoveryChecklistRow(
                mark: isTailscaleActive ? .done : .idle,
                title: "Tailscale",
                detail: isTailscaleActive ? "Connected on this Mac" : "Off · only needed for Macs away from this network"
            ) {
                if isTailscaleActive {
                    MacMetaLabel(text: "Ready")
                } else {
                    Button("Open Tailscale", action: openTailscaleApp)
                        .buttonStyle(MacCapsuleButtonStyle(kind: .quiet))
                }
            }
            Divider().opacity(0.5)
            DiscoveryChecklistRow(mark: .add, title: "By address", detail: "Type an IP address or hostname below") {
                Button("Add Mac…") { manualFieldFocused = true }
                    .buttonStyle(MacCapsuleButtonStyle(kind: .glass))
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: 460)
        .macCard(radius: 16)
    }

    // MARK: - Assistant tab

    private var assistantTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageHeader(meta: "Vamp Assistant · private port 9575",
                           title: "Assistant",
                           lede: "Reach a Mac running Vamp Assistant over your LAN or Tailscale. It pairs with a code instead of discovery.")
                assistantCard
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
    }

    private var assistantCard: some View {
        HStack(spacing: 14) {
            MacMarkTile(size: 46, arc: .control, badge: "sparkles")

            VStack(alignment: .leading, spacing: 3) {
                Text("Desktop via Vamp Assistant")
                    .font(.system(size: 14, weight: .semibold))
                Text(assistant.savedAddress ?? "Not paired yet")
                    .font(MacBrand.mono(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let error = assistant.errorMessage {
                    HStack(alignment: .top, spacing: 6) {
                        MacStatusDot(tone: .attention)
                        Text(error)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
            }

            Spacer(minLength: 12)

            if assistant.isWorking {
                ProgressView().controlSize(.small)
                if assistant.canCancelWork {
                    Button("Cancel") { assistant.cancelWork() }
                        .buttonStyle(MacCapsuleButtonStyle(kind: .glass))
                }
            } else if assistant.savedAddress != nil {
                Button("Reconnect") { assistant.startReconnect() }
                    .buttonStyle(MacCapsuleButtonStyle(kind: .primary, large: true))
                Menu {
                    Button("Pair a Different Mac") { showsAssistantPairing = true }
                    Button("Forget Saved Assistant…", role: .destructive) {
                        confirmForgetAssistant = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Assistant options")
            } else {
                Button("Pair Assistant") { showsAssistantPairing = true }
                    .buttonStyle(MacCapsuleButtonStyle(kind: .primary, large: true))
            }
        }
        .padding(14)
        .macCard(radius: 18, interactive: true)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Trusted tab

    private var trustedTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageHeader(meta: "Approved with a fingerprint",
                           title: "Trusted Macs",
                           lede: "Macs you approved reconnect without asking. Forget one and it asks for approval again.")
                MacTrustedMacsList(model: trustedVM)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
    }

    private var errorBannerMessage: String? {
        if let message = coordinator.errorMessage, coordinator.phase == .error || coordinator.phase == .idle {
            return message
        }
        // A permission-blocked host sets `phase == .error` and `blockedState`
        // but leaves `errorMessage` nil, so without this fallback the banner
        // would be empty and the user would get no guidance about granting
        // Screen Recording / Accessibility on the host.
        if coordinator.phase == .error, let blocked = coordinator.blockedState {
            return blocked.message
        }
        return hostsVM.connectionMessage
    }

    // MARK: - Manual entry

    private var manualEntryBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Add a Mac by IP or hostname — 192.168.1.20:9471", text: $manualAddress)
                .textFieldStyle(.plain)
                .font(MacBrand.mono(12.5))
                .focused($manualFieldFocused)
                // Return submits only while this field has focus. It used to be
                // the window's default action, so Return anywhere on the screen
                // meant "Add" — including while a host was selected.
                .onSubmit(addManualHost)
                // A stale "Invalid address" shouldn't linger while the user is
                // already fixing the input.
                .onChange(of: manualAddress) { _ in manualAddError = nil }
                .accessibilityLabel("Add a Mac by IP address or hostname")

            if let manualAddError {
                HStack(spacing: 6) {
                    MacStatusDot(tone: .attention)
                    Text(manualAddError)
                        .font(.callout)
                }
            }
            Button("Add", action: addManualHost)
                .buttonStyle(MacCapsuleButtonStyle(kind: .glass))
                .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 42)
        .macCard(radius: 21)
        .frame(maxWidth: 1100)
        .padding(.horizontal, 32)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Connecting overlay

    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()
            VStack(spacing: 14) {
                if let confirmation = coordinator.pendingHostConfirmation {
                    hostConfirmation(confirmation)
                } else {
                    ProgressView().controlSize(.large)
                    Text(connectingStatusText)
                        .font(.system(size: 18, weight: .semibold))
                    Text("If this is the first connection, approve this Mac in Vamp Sync on the other computer.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    if coordinator.hostUsesLegacyHandshake {
                        HStack(alignment: .top, spacing: 6) {
                            MacStatusDot(tone: .attention)
                            Text(ClientSessionCoordinator.legacyHostNotice)
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: 380)
                    }
                }
                Button("Cancel") {
                    Task { await coordinator.disconnect() }
                }
                .buttonStyle(MacCapsuleButtonStyle(kind: .glass, large: true))
                .keyboardShortcut(.cancelAction)
                .padding(.top, 2)
            }
            .padding(30)
            .frame(maxWidth: 460)
            .macCard(radius: 22, interactive: true)
        }
    }

    /// Pairing is paused until the user has compared the other Mac's fingerprint, or has
    /// accepted a Vamp Sync too old to prove its identity. Deliberately no default-action
    /// shortcut: Return must not confirm a fingerprint nobody looked at.
    @ViewBuilder
    private func hostConfirmation(_ confirmation: PendingHostConfirmation) -> some View {
        let isOlderSync = confirmation.fingerprint == nil
        MacMetaLabel(text: isOlderSync ? "Older Vamp Sync" : "Check the code")
        Text(isOlderSync ? "Older Vamp Sync on \(confirmation.hostName)" : "Is this your Mac?")
            .font(.system(size: 18, weight: .semibold))
        Text(isOlderSync
             ? "It can’t prove its identity before pairing. Update Vamp Sync on that Mac, or connect anyway."
             : "Compare this with the Host fingerprint in Vamp Sync on \(confirmation.hostName). Continue only if every group matches.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
        if let fingerprint = confirmation.fingerprint {
            MacFingerprintChunks(fingerprint: fingerprint, large: true)
                .frame(maxWidth: 400)
                .accessibilityLabel("Mac fingerprint")
        }
        Button(isOlderSync ? "Connect Anyway" : "It Matches") { coordinator.confirmPendingHost() }
            .buttonStyle(MacCapsuleButtonStyle(kind: .primary, large: true))
    }

    private var connectingStatusText: String {
        switch coordinator.phase {
        case .connecting: return "Connecting…"
        case .signalingConnected: return "Contacting host…"
        case .negotiating: return "Waiting for host approval…"
        default: return "Connecting…"
        }
    }

    // MARK: - Actions

    private func beginRename(_ row: DiscoveredHostRow) {
        renameText = nicknames.displayName(for: row.endpoint)
        renamingHost = row
    }

    private func addManualHost() {
        let address = manualAddress.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        if let row = hostsVM.addManualHost(address: address) {
            manualAddError = nil
            manualAddress = ""
            connect(to: row)
        } else {
            manualAddError = "Invalid address"
        }
    }

    private func connect(to row: DiscoveredHostRow) {
        guard allowsNewSession() else {
            onSessionBlocked()
            return
        }
        // Remind to enable the VPN before attempting a Tailscale/relay address —
        // a ts.net / 100.x host won't resolve without Tailscale connected, so we
        // route through a warning alert instead of a doomed long-timeout connect.
        if isRelay(row) && coordinator.tailscaleVPNStatus == .inactive {
            pendingTailscaleHost = row
            return
        }
        startConnect(to: row)
    }

    /// Starts the session for `row`, after any pre-connect guards have passed.
    private func startConnect(to row: DiscoveredHostRow) {
        hostsVM.connect(to: row)
        let preset = environment.effectivePreferredQualityPreset
        Task {
            await coordinator.connect(to: row.endpoint, qualityPreset: preset)
            if coordinator.phase == .receiving || coordinator.phase == .waitingForMedia {
                hostsVM.markHostConnected(row.id)
            }
        }
    }

    /// A relay host is reachable only over Tailscale (a ts.net name or 100.x CGNAT
    /// address), so connecting to one needs the VPN up first.
    private func isRelay(_ row: DiscoveredHostRow) -> Bool {
        row.endpoint.hostname.contains("ts.net") || row.endpoint.hostname.hasPrefix("100.")
    }

    /// Opens the Tailscale app via its URL scheme (macOS uses NSWorkspace, not UIApplication).
    private func openTailscaleApp() {
        if let url = URL(string: "tailscale://") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Wake on LAN

    /// A host can be woken when it's offline but we still know how to reach it —
    /// a saved MAC (magic packet) or a Bonjour name (Sleep Proxy / Wake-on-Demand).
    private func canWake(_ row: DiscoveredHostRow) -> Bool {
        !row.isAvailable
            && (row.endpoint.metadata.macAddress != nil || row.endpoint.bonjourServiceName != nil)
    }

    private func sendWake(_ row: DiscoveredHostRow) {
        let mac = row.endpoint.metadata.macAddress
        let bonjourName = row.endpoint.bonjourServiceName
        guard mac != nil || bonjourName != nil else { return }
        wakingHostID = row.id
        let targetHost = row.endpoint.hostname
        Task {
            // WakeCoordinator fires both paths in parallel — magic packet (Ethernet / Intel)
            // and the Bonjour resolve that triggers the LAN Sleep Proxy (the only path that
            // wakes Apple-Silicon Macs on Wi-Fi) — and reports what was actually dispatched.
            let outcome = await WakeCoordinator().wake(
                macAddress: mac,
                bonjourServiceName: bonjourName,
                targetHost: targetHost,
                wakeSupported: row.endpoint.metadata.wakeSupported
            )
            if wakingHostID == row.id { wakingHostID = nil }
            showWakeFeedback(outcome)
        }
    }

    private func showWakeFeedback(_ outcome: WakeCoordinator.Outcome) {
        let message = outcome.userMessage
        withAnimation(.easeOut(duration: 0.2)) {
            wakeFeedback = message
            wakeFeedbackIsError = outcome.isError
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if wakeFeedback == message {
                withAnimation(.easeOut(duration: 0.25)) { wakeFeedback = nil }
            }
        }
    }

    private func wakeToast(_ message: String, isError: Bool) -> some View {
        HStack(spacing: 10) {
            MacStatusDot(tone: isError ? .attention : .live)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 460)
        .macCard(radius: 14)
        .padding(.horizontal, 24)
    }
}

// MARK: - Toolbar tabs

/// Option D from the redesign: sections live in the toolbar, not a sidebar.
/// Every tab maps to something real: discovered Macs, Vamp Assistant, trusted Macs.
private struct MacHomeTabs: View {
    @Binding var selection: MacHostsScreen.Tab
    let showsAssistant: Bool
    let macCount: Int
    let assistantIsSaved: Bool
    let trustedCount: Int

    var body: some View {
        HStack(spacing: 2) {
            tab(.macs, title: "Macs", systemImage: "desktopcomputer", count: macCount)
            if showsAssistant {
                tab(.assistant, title: "Assistant", systemImage: "sparkles", count: nil)
            }
            tab(.trusted, title: "Trusted", systemImage: "checkmark.shield", count: trustedCount)
        }
        .padding(3)
        .macCard(radius: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    private func tab(_ value: MacHostsScreen.Tab, title: String, systemImage: String, count: Int?) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(title)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(MacBrand.mono(10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background {
                if isSelected {
                    Capsule().fill(Color.primary.opacity(0.12))
                        .overlay(Capsule().strokeBorder(MacBrand.hairline, lineWidth: 0.5))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

// MARK: - Discovery pieces

/// Concentric rings with a sweep while a scan is running; still under Reduce Motion.
private struct DiscoveryRadar: View {
    var isScanning: Bool
    var isBlocked: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1).frame(width: 232, height: 232)
            Circle().strokeBorder(Color.primary.opacity(0.09), lineWidth: 1).frame(width: 168, height: 168)
            Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1).frame(width: 104, height: 104)
            if isScanning && !reduceMotion {
                Circle()
                    .fill(AngularGradient(gradient: Gradient(stops: [
                        .init(color: Color.primary.opacity(0.18), location: 0),
                        .init(color: .clear, location: 0.24),
                        .init(color: .clear, location: 1),
                    ]), center: .center))
                    .frame(width: 232, height: 232)
                    .mask(Circle().strokeBorder(Color.black, lineWidth: 82))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 3.2).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
                    .onDisappear { spin = false }
                Circle().fill(MacBrand.live).frame(width: 7, height: 7)
                    .shadow(color: MacBrand.live.opacity(0.7), radius: 6)
                    .offset(x: -74, y: -42)
            }
            Image(systemName: isBlocked ? "wifi.exclamationmark" : "desktopcomputer")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 64, height: 64)
                .macCard(radius: 18)
        }
        .frame(width: 232, height: 232)
        .accessibilityHidden(true)
    }
}

private struct DiscoveryChecklistRow<Trailing: View>: View {
    enum Mark { case working, done, idle, add, blocked }
    let mark: Mark
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            markView
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var markView: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.06))
            Circle().strokeBorder(MacBrand.hairline, lineWidth: 0.5)
            switch mark {
            case .working:
                ProgressView().controlSize(.mini).scaleEffect(0.8)
            case .done:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(MacBrand.live)
            case .idle:
                MacStatusDot(tone: .idle)
            case .add:
                Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            case .blocked:
                MacStatusDot(tone: .attention)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

// MARK: - Mac card

/// One Mac: a stylized display, its name and route, status, and one clear action.
/// The display and name are the card's main button; the footer holds the explicit
/// action so a nested button never swallows the card's click.
private struct MacHostCard: View {
    let row: DiscoveredHostRow
    /// The nickname if this Mac has one, otherwise the advertised name.
    let displayName: String
    let isRenamed: Bool
    let isBusy: Bool
    let canWake: Bool
    let isWaking: Bool
    /// Only the first available Mac carries the crimson primary; one primary action per screen.
    var isPrimary = true
    let onConnect: () -> Void
    let onWake: () -> Void
    let onRename: () -> Void
    let onResetName: () -> Void
    let onToggleSave: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @ObservedObject private var thumbnails = MacHostThumbnails.shared

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: primaryAction) {
                VStack(alignment: .leading, spacing: 10) {
                    // Status rides on the screen tile so the name gets the card's full width.
                    MacScreenTile(seed: row.endpoint.metadata.displayName, state: tileState,
                                  thumbnail: thumbnails.images[row.id])
                        .overlay(alignment: .topTrailing) {
                            MacStatusPill(title: statusTitle, tone: statusTone)
                                .padding(8)
                        }
                    details
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isActionable)
            .focused($isFocused)
            .help(actionHint)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(displayName)
            .accessibilityValue("\(productName), \(statusTitle), \(row.subtitle)")
            .accessibilityHint(actionHint)

            HStack(spacing: 8) {
                MacMetaLabel(text: footnote)
                Spacer(minLength: 6)
                actionButton
            }
            .padding(.horizontal, 4)
        }
        .padding(10)
        .padding(.bottom, 2)
        .macCard(radius: 18, interactive: true)
        .brightness(isHovering ? 0.02 : 0)
        .overlay {
            if isFocused {
                cardShape
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename…", action: onRename)
            if isRenamed {
                Button("Reset to \(row.endpoint.metadata.displayName)", action: onResetName)
            }
            Divider()
            Button(row.isSaved ? "Remove from Saved" : "Save Host", action: onToggleSave)
            if canWake {
                Button(isWaking ? "Waking…" : "Wake Host", action: onWake)
                    .disabled(isWaking)
            }
        }
    }

    // MARK: Action

    /// Online hosts connect; a sleeping host that we know how to reach wakes.
    private var isActionable: Bool {
        if isBusy { return false }
        return row.isAvailable || (canWake && !isWaking)
    }

    private func primaryAction() {
        if row.isAvailable {
            onConnect()
        } else if canWake {
            onWake()
        }
    }

    private var actionHint: String {
        if row.isAvailable { return "Connect to \(displayName)" }
        if canWake { return "Send a wake signal to \(displayName)" }
        return "\(displayName) is offline and can’t be woken from here"
    }

    @ViewBuilder
    private var actionButton: some View {
        if isBusy {
            ProgressView().controlSize(.small)
        } else if row.isAvailable {
            Button("Connect", action: onConnect)
                .buttonStyle(MacCapsuleButtonStyle(kind: isPrimary ? .primary : .glass))
                .accessibilityLabel("Connect to \(displayName)")
        } else if canWake {
            Button(action: onWake) {
                Label(isWaking ? "Waking…" : "Wake", systemImage: "power")
            }
            .buttonStyle(MacCapsuleButtonStyle(kind: .glass))
            .disabled(isWaking)
            .accessibilityLabel("Wake \(displayName)")
        } else {
            Button("Rename…", action: onRename)
                .buttonStyle(MacCapsuleButtonStyle(kind: .quiet))
                .accessibilityLabel("Rename \(displayName)")
        }
    }

    // MARK: Pieces

    private var tileState: MacScreenTile.State {
        if row.isAvailable { return .ready }
        return canWake ? .asleep : .offline
    }

    private var statusTitle: String {
        if row.isAvailable { return "Online" }
        return canWake ? "Asleep" : "Offline"
    }

    private var statusTone: MacStatusTone {
        if row.isAvailable { return .live }
        return canWake ? .attention : .idle
    }

    private var footnote: String {
        if row.isAvailable { return productName }
        return canWake ? "Wake ready" : "Open Vamp Sync on it"
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if isRenamed {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Renamed on this Mac — the host still advertises “\(row.endpoint.metadata.displayName)”")
                }
                if row.isSaved {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Saved")
                }
            }
            Text(row.subtitle)
                .font(MacBrand.mono(11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Vamp Sync shares one app window; Vamp Host shares the whole desktop.
    /// They are indistinguishable in the grid otherwise, and picking the wrong
    /// one is the difference between a desktop and an app browser.
    private var productName: String {
        let capabilities = row.endpoint.metadata.capabilities
        if capabilities.contains(.supportsAppStreaming), !capabilities.contains(.supportsMultiDisplay) {
            return capabilities.contains(.supportsDesktopControl) ? "Desktop + Apps" : "Apps · Update Sync"
        }
        return "Legacy host"
    }
}

// MARK: - Rename

/// Renames a Mac locally. The host keeps advertising its own name; this is a
/// label for this Mac only, so the sheet says so rather than implying it edits
/// the remote machine.
private struct MacRenameHostSheet: View {
    let advertisedName: String
    @Binding var text: String
    let onCancel: () -> Void
    let onSave: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Mac")
                .font(.headline)

            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(onSave)
                .accessibilityLabel("Name for this Mac")

            Text("Shown only on this Mac. \(advertisedName) keeps its own name; leave the field empty to go back to it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(MacBrand.crimson)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { fieldFocused = true }
    }
}

/// Fictional Macs for store screenshots (see `MacHostsScreen.usesSampleHosts`).
enum MacSampleHosts {
    static let rows: [DiscoveredHostRow] = [
        row("Studio Mac mini", host: "192.168.1.20", id: "6F1D2C55-0A4B-4E7E-9E61-1C2B3D4E5F60", available: true, saved: true),
        row("Design MacBook Pro", host: "192.168.1.44", id: "6F1D2C55-0A4B-4E7E-9E61-1C2B3D4E5F61", available: true, saved: false),
        row("Office iMac", host: "192.168.1.31", id: "6F1D2C55-0A4B-4E7E-9E61-1C2B3D4E5F62", available: false, saved: true,
            macAddress: "a2:4f:91:3c:7e:d0"),
    ]

    private static func row(_ name: String, host: String, id: String, available: Bool, saved: Bool,
                            macAddress: String? = nil) -> DiscoveredHostRow {
        let metadata = HostAdvertisementMetadata(
            protocolVersion: 1, hostID: UUID(uuidString: id)!, displayName: name, appVersion: "4.0.0",
            signalingPort: 9471,
            capabilities: [.supportsH264, .supportsHEVC, .supportsAppStreaming, .supportsDesktopControl, .supportsMacClient],
            availability: available ? .available : .unavailable, macAddress: macAddress, wakeSupported: macAddress != nil)
        return DiscoveredHostRow(endpoint: ResolvedHostEndpoint(hostname: host, port: 9471, metadata: metadata),
                                 lastSeen: Date(), isAvailable: available, isSaved: saved)
    }
}
