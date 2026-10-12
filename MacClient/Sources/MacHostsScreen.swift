import SwiftUI
import AppKit
import Discovery
import SharedModels

/// Discovers hosts on the local network and starts sessions.
struct MacHostsScreen: View {
    @ObservedObject var environment: ClientAppEnvironment
    @ObservedObject var assistant: MacAssistantSession
    @ObservedObject private var hostsVM: HostsListViewModel
    @ObservedObject private var coordinator: ClientSessionCoordinator

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

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @ObservedObject private var nicknames = MacHostNicknameStore.shared
    /// The host being renamed, plus the in-progress text.
    @State private var renamingHost: DiscoveredHostRow?
    @State private var renameText = ""

    /// The manual-add field is the only text control on the screen, so AppKit
    /// made it first responder on launch — a blue focus ring shouting for
    /// attention before the user has any intent to type an address.
    @FocusState private var manualFieldFocused: Bool

    init(environment: ClientAppEnvironment, assistant: MacAssistantSession) {
        self.environment = environment
        self.assistant = assistant
        self.hostsVM = environment.sharedHostsViewModel
        self.coordinator = environment.sessionCoordinator
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            manualEntryBar
        }
        .background(MacBrand.pageBackdrop)
        .defaultFocus($manualFieldFocused, false)
        .toolbar {
            // The idle window's title bar used to carry nothing but a refresh
            // icon, so the top of the app read as unfinished next to the
            // session toolbar. Give it the same status-pill idiom.
            discoveryStatusItem
            wordmarkItem

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsAssistantPairing = true
                } label: {
                    SessionToolbarToggleLabel(title: "Pair Assistant", systemImage: "sparkles.rectangle.stack")
                }
                .buttonStyle(SessionToolbarToggleButtonStyle())
                .help("Pair a Mac running Vamp Assistant")
                .accessibilityLabel("Pair Vamp Assistant")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await hostsVM.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isScanning)
                .help("Search the local network again")
            }
        }
        .task { await hostsVM.start() }
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
                    .padding(.bottom, 64)
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

    /// Only show the full-screen spinner before the very first scan completes.
    /// After that we keep stable content and surface re-scans via the toolbar.
    private var isInitialScan: Bool { isScanning && !hasCompletedFirstScan }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        if case .localNetworkIssue(let message) = hostsVM.state {
            centeredState {
                statusGraphic("wifi.exclamationmark", tint: .orange)
                Text("Local Network Unavailable").font(.title2.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        } else if !hostsVM.displayHosts.isEmpty {
            hostsList
        } else if isInitialScan {
            centeredState {
                DiscoveryHero(isScanning: true)
                Text("Searching for Vamp Sync…")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        } else {
            emptyState
        }
    }

    /// Shared centered layout for the non-list states.
    private func centeredState<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
    }

    private func statusGraphic(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: 72, height: 72)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyState: some View {
        centeredState {
            DiscoveryHero(isScanning: isScanning)
                .padding(.bottom, 4)
            Text("No Macs found yet")
                .font(.title2.weight(.semibold))
            Text("Open Vamp Sync, or pair Vamp Assistant. Keep both Macs on the same LAN or reachable over Tailscale.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            assistantCard
                .padding(.top, 10)
            vampHostBox
                .padding(.top, 10)
            if isScanning {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Scanning your network…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            Text("…or add one by IP address below.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    // MARK: - Get Vamp Sync

    /// Canonical direct-download page for the host companion.
    private static let hostWebsiteURL = URL(string: "https://thevamp.app/sync/")!

    /// Small directional card pointing users to install the free Vamp Sync on the Mac they
    /// want to control.
    private var vampHostBox: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 5) {
                Text("Don’t have Vamp Sync yet?")
                    .font(.headline)
                Text("Control the whole desktop or choose a single app window. Install Vamp Sync on the remote Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: Self.hostWebsiteURL) {
                    Label("Download from project website", systemImage: "arrow.down.circle")
                }
                .font(.callout.weight(.medium))
                .buttonStyle(.bordered)
                .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: 460, alignment: .leading)
        .macGlassSurface(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            isInteractive: true
        )
    }

    // MARK: - Hosts list

    private var hostsList: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel(assistant.savedAddress == nil ? "Add a connection" : "Saved connections")
                    assistantCard

                    if let message = errorBannerMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    sectionLabel("On your network")
                        .padding(.top, 4)

                    LazyVStack(spacing: 10) {
                        ForEach(hostsVM.displayHosts) { row in
                            HostCardView(
                                row: row,
                                displayName: nicknames.displayName(for: row.endpoint),
                                isRenamed: nicknames.nickname(for: row.endpoint) != nil,
                                isBusy: isConnecting,
                                canWake: canWake(row),
                                isWaking: wakingHostID == row.id,
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
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                // Top-align the list: a few hosts centered in a tall window
                // floats in a void. Pinning to the top reads as intentional —
                // the native macOS list idiom (System Settings, Mail, Finder).
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
    }

    /// Sits directly on the backdrop art rather than on glass, so it needs more
    /// weight than a plain secondary label to stay readable over the engraving.
    /// macOS 26 wraps every toolbar item in its own glass capsule. That is right
    /// for controls and wrong for ambient status text, which should read as part
    /// of the bar rather than as a second shape competing with the window title.
    @ToolbarContentBuilder
    private var discoveryStatusItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { discoveryStatus }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { discoveryStatus }
        }
    }

    /// Centred in the bar rather than trailing the status text, and unchromed
    /// for the same reason the status is: it is a wordmark, not a control.
    @ToolbarContentBuilder
    private var wordmarkItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) { MacBrandWordmark() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { MacBrandWordmark() }
        }
    }

    private var discoveryStatus: some View {
        MacDiscoveryStatus(
            title: discoveryStatusText,
            tint: discoveryStatusColor,
            isScanning: isScanning,
            differentiateWithoutColor: differentiateWithoutColor
        )
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }

    private var discoveryStatusColor: Color {
        if case .localNetworkIssue = hostsVM.state { return .orange }
        if isScanning { return .yellow }
        return hostsVM.displayHosts.contains(where: \.isAvailable) ? .green : .secondary
    }

    /// One line, one fact. Stacking "2 Macs found" over "2 online" crammed two
    /// counts of the same thing into a two-line pill built for a live session's
    /// host name and quality; "2 of 2 online" says both at once.
    private var discoveryStatusText: String {
        if case .localNetworkIssue = hostsVM.state { return "Local network blocked" }
        let hosts = hostsVM.displayHosts
        guard !hosts.isEmpty else { return isScanning ? "Scanning…" : "No Macs found" }
        let online = hosts.filter(\.isAvailable).count
        if online == hosts.count {
            return "\(online) online"
        }
        return "\(online) of \(hosts.count) online"
    }

    private var assistantCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("Desktop via Vamp Assistant")
                    .font(.headline)
                Text(assistant.savedAddress ?? "Private LAN or Tailscale control · port 9575")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let error = assistant.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            if assistant.isWorking {
                ProgressView().controlSize(.small)
            } else if assistant.savedAddress != nil {
                Button("Reconnect") { Task { await assistant.reconnect() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Menu {
                    Button("Pair a Different Mac") { showsAssistantPairing = true }
                    Button("Forget Saved Assistant", role: .destructive) {
                        assistant.disconnect(forget: true)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Button("Pair Assistant") { showsAssistantPairing = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(14)
        .macGlassSurface(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            isInteractive: true
        )
        .accessibilityElement(children: .contain)
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
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Add a Mac by IP or hostname  (e.g. 192.168.1.20:9471)", text: $manualAddress)
                .textFieldStyle(.roundedBorder)
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
                Text(manualAddError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Button("Add", action: addManualHost)
                .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        // Match the 720pt card column so the footer aligns with the list above
        // instead of spanning the whole window edge-to-edge.
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Connecting overlay

    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(connectingStatusText)
                    .font(.title3.weight(.semibold))
                Text("If this is the first connection, approve this Mac in the Vamp Sync window on the other computer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Cancel") {
                    Task { await coordinator.disconnect() }
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .padding(.top, 2)
            }
            .padding(32)
            .macGlassSurface(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                isInteractive: true
            )
        }
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
        let tint = isError ? Color.orange : Color.secondary
        return HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "bolt.horizontal.fill")
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isError ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 460)
        .macGlassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 24)
    }
}

// MARK: - Discovery hero

/// First-run / empty-list illustration: a Mac framed by concentric "signal"
/// rings, used both while scanning and when no hosts are found. The rings
/// breathe while a scan is in flight, so the first thing a new user sees reads
/// as "looking for Macs on your network" rather than a bare spinner or a
/// stamped app icon.
private struct DiscoveryHero: View {
    var isScanning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(Color.accentColor.opacity(0.16 - Double(i) * 0.04), lineWidth: 1.5)
                    .frame(width: 100 + CGFloat(i) * 42, height: 100 + CGFloat(i) * 42)
                    .scaleEffect(animating ? 1.06 : 0.97)
                    .opacity(animating ? 0.9 : 0.55)
                    .animation(
                        isScanning && !reduceMotion
                            ? .easeInOut(duration: 1.9).repeatForever(autoreverses: true).delay(Double(i) * 0.22)
                            : .easeOut(duration: 0.3),
                        value: animating
                    )
            }

            Image(systemName: "desktopcomputer")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(width: 92, height: 92)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
                )
        }
        .frame(width: 210, height: 200)
        .onAppear { animating = isScanning && !reduceMotion }
        .onChange(of: isScanning) { animating = $0 && !reduceMotion }
    }
}

// MARK: - Host card
private struct HostCardView: View {
    let row: DiscoveredHostRow
    /// The nickname if this Mac has one, otherwise the advertised name.
    let displayName: String
    let isRenamed: Bool
    let isBusy: Bool
    let canWake: Bool
    let isWaking: Bool
    let onConnect: () -> Void
    let onWake: () -> Void
    let onRename: () -> Void
    let onResetName: () -> Void
    let onToggleSave: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MacBrand.cardCornerRadius, style: .continuous)
    }

    /// The whole card is one button. Previously only the small trailing Connect
    /// button did anything and a single click on the row was inert, which reads
    /// on macOS as a selection that never happens; the real action was an
    /// undiscoverable double-click.
    var body: some View {
        Button(action: primaryAction) {
            BrandCard(hovering: isHovering) {
                HStack(spacing: 14) {
                    icon
                    details
                    Spacer(minLength: 12)
                    statusPill
                    actionAffordance
                }
                .padding(14)
                .contentShape(cardShape)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isActionable)
        .focused($isFocused)
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
        .help(actionHint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayName)
        .accessibilityValue("\(productName), \(row.isAvailable ? "online" : "offline"), \(row.subtitle)")
        .accessibilityHint(actionHint)
    }

    // MARK: - Action

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

    // MARK: - Pieces

    private var icon: some View {
        Image(systemName: "desktopcomputer")
            .font(.title2)
            .foregroundStyle(row.isAvailable ? Color.accentColor : Color.secondary)
            .frame(width: 48, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(row.isAvailable
                          ? Color.accentColor.opacity(0.12)
                          : Color.secondary.opacity(0.12))
            )
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(displayName)
                    .font(.headline)
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
                        .foregroundStyle(.yellow)
                }
            }
            HStack(spacing: 8) {
                productBadge
                Text(row.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    /// Vamp Sync shares one app window; Vamp Host shares the whole desktop.
    /// They are indistinguishable in the list otherwise, and picking the wrong
    /// one is the difference between a desktop and an app browser. Rendered as a
    /// badge rather than more dot-separated prose — the subtitle already carries
    /// an address.
    private var productBadge: some View {
        Text(productName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.14), in: Capsule())
    }

    private var productName: String {
        let capabilities = row.endpoint.metadata.capabilities
        if capabilities.contains(.supportsAppStreaming), !capabilities.contains(.supportsMultiDisplay) {
            return capabilities.contains(.supportsDesktopControl) ? "Desktop + Apps" : "Apps · Update Sync for desktop"
        }
        return "Legacy host"
    }

    /// Looks like the old trailing button but is part of the card's own hit
    /// area — a real nested button inside a button swallows the outer action.
    @ViewBuilder
    private var actionAffordance: some View {
        if isBusy {
            ProgressView().controlSize(.small)
        } else if row.isAvailable {
            affordanceLabel("Connect", tint: Color.accentColor, filled: true)
        } else if canWake {
            affordanceLabel(isWaking ? "Waking…" : "Wake", tint: .orange, filled: false)
        } else {
            affordanceLabel("Offline", tint: .secondary, filled: false)
        }
    }

    private func affordanceLabel(_ title: String, tint: Color, filled: Bool) -> some View {
        Text(title)
            .font(.callout.weight(.medium))
            .foregroundStyle(filled ? Color.white : tint)
            .frame(minWidth: 56)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if filled {
                    Capsule().fill(tint.opacity(isHovering ? 1 : 0.9))
                } else {
                    Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1)
                }
            }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(row.isAvailable ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(row.isAvailable ? "Online" : "Offline")
                .font(.caption.weight(.medium))
                .foregroundStyle(row.isAvailable ? Color.green : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            (row.isAvailable ? Color.green : Color.secondary).opacity(0.12),
            in: Capsule()
        )
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
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { fieldFocused = true }
    }
}

// MARK: - Discovery status

/// Ambient status text for the host list's toolbar.
///
/// Deliberately unchromed: it is not a control and nothing here is tappable, so
/// a capsule around it only added a second competing shape next to the window
/// title. It reads as part of the toolbar instead.
private struct MacDiscoveryStatus: View {
    let title: String
    let tint: Color
    let isScanning: Bool
    let differentiateWithoutColor: Bool

    @Environment(\.controlActiveState) private var controlActiveState

    private var dotColor: Color {
        controlActiveState == .inactive ? Color.secondary : tint
    }

    var body: some View {
        HStack(spacing: 7) {
            if isScanning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.8)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .overlay {
                        if differentiateWithoutColor {
                            Circle().strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
                        }
                    }
            }
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.trailing, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Discovery status")
        .accessibilityValue(title)
    }
}
