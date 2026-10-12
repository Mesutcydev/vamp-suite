import SwiftUI
import Discovery
import SharedModels

struct VampTerminalHomeView: View {
    @ObservedObject var environment: ClientAppEnvironment
    @ObservedObject private var hosts: HostsListViewModel
    @ObservedObject private var coordinator: ClientSessionCoordinator
    @StateObject private var workspace: TerminalWorkspaceViewModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var manualAddress = ""
    @State private var manualAddressError: String?
    @State private var showingManualAddress = false
    @State private var showingGuide = false
    @FocusState private var manualAddressFocused: Bool
    @AppStorage("vampTerminal.hostPromo.dismissed") private var hostPromoDismissed = false

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        _hosts = ObservedObject(wrappedValue: environment.sharedHostsViewModel)
        _coordinator = ObservedObject(wrappedValue: environment.sessionCoordinator)
        _workspace = StateObject(
            wrappedValue: TerminalWorkspaceViewModel(coordinator: environment.sessionCoordinator)
        )
    }

    var body: some View {
        Group {
            if isWorkspaceVisible {
                VampTerminalWorkspaceView(
                    workspace: workspace,
                    coordinator: coordinator
                )
            } else {
                homeContent
            }
        }
        .task {
            await hosts.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await hosts.handleSceneBecameActive() }
        }
    }

    private var isWorkspaceVisible: Bool {
        switch coordinator.phase {
        case .waitingForMedia, .receiving:
            guard let capabilities = coordinator.negotiatedCapabilities else {
                return false
            }
            return capabilities.supportsTerminal && capabilities.supportsMultipleTerminals
        case .idle, .connecting, .signalingConnected, .negotiating, .error:
            return false
        }
    }

    private var terminalUnavailableMessage: (title: String, message: String, icon: String)? {
        guard coordinator.phase == .waitingForMedia
                || coordinator.phase == .receiving else {
            return nil
        }
        guard let capabilities = coordinator.negotiatedCapabilities else {
            return (
                "Terminal capability not reported",
                "This host did not report multi-terminal support. Update Vamp Host on the Mac before using Vamp Terminal.",
                "questionmark.circle"
            )
        }
        if !capabilities.supportsTerminal {
            return (
                "Terminal Mode is not supported",
                "This host can connect, but it does not provide an authenticated terminal channel. Update Vamp Host on the Mac.",
                "terminal"
            )
        }
        if !capabilities.supportsMultipleTerminals {
            return (
                "Multiple terminals are not supported",
                "This host supports only the older single-terminal flow. Update Vamp Host on the Mac to use terminal tabs.",
                "rectangle.split.2x1"
            )
        }
        return nil
    }

    private var homeContent: some View {
        NavigationStack {
            ZStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: VampTerminalDesign.space6) {
                            hero
                                .id("vamp-terminal-home-top")

                            hostSection

                            if isConnecting {
                                connectionProgressCard
                            }

                            if let blocked = coordinator.blockedState {
                                messageCard(
                                    title: blocked.title,
                                    message: blocked.message,
                                    icon: "lock.shield",
                                    tint: VampGlassPalette.warning
                                )
                            } else if let error = coordinator.errorMessage,
                                      coordinator.phase == .error {
                                connectionAttentionCard(error)
                            } else if let unavailable = terminalUnavailableMessage {
                                terminalUnavailableCard(
                                    title: unavailable.title,
                                    message: unavailable.message,
                                    icon: unavailable.icon
                                )
                            }

                            guideEntry

                            if !hostPromoDismissed {
                                VampHostPromoCard {
                                    hostPromoDismissed = true
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                hostSetupRecovery
                            }

                            pairingNote
                        }
                        .padding(.horizontal, VampTerminalDesign.space4)
                        .padding(.top, VampTerminalDesign.space3)
                        .padding(.bottom, VampTerminalDesign.space7)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: manualAddressFocused) { _, isFocused in
                        guard !isFocused else { return }
                        // SwiftUI may leave the scroll view parked at the
                        // address field after the keyboard is dismissed.
                        // Return to the stable dashboard top so the hero and
                        // host cards are not left half-clipped.
                        DispatchQueue.main.async {
                            var transaction = Transaction()
                            transaction.animation = nil
                            withTransaction(transaction) {
                                proxy.scrollTo("vamp-terminal-home-top", anchor: .top)
                            }
                        }
                    }
                }
            }
            .background(VampTerminalBackdrop())
            .navigationTitle("Vamp Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await hosts.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isConnecting)
                    .accessibilityLabel("Refresh hosts")
                }
            }
            .sheet(isPresented: $showingGuide) {
                VampTerminalGuideView()
            }
        }
    }

    private var hero: some View {
        HStack(spacing: VampTerminalDesign.space3) {
            VampGlassIconTile(systemImage: "terminal.fill", size: 62)

            VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                Text("Your Mac, in tabs.")
                    .font(.system(size: VampTerminalDesign.heroTitleSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(VampGlassPalette.ink)
                Text("Secure terminal access from anywhere on your tailnet.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("REMOTE SHELL  ·  TAILSCALE READY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(VampGlassPalette.inkTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var guideEntry: some View {
        Button {
            showingGuide = true
        } label: {
            HStack(spacing: VampTerminalDesign.space3) {
                VampGlassIconTile(systemImage: "book.closed", size: 42)
                VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                    Text("How to use Vamp Terminal")
                        .font(.headline)
                        .foregroundStyle(VampGlassPalette.ink)
                    Text("Pair once, switch tabs, resume tmux sessions, and use the mobile controls.")
                        .font(.footnote)
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VampGlassPalette.inkTertiary)
            }
            .padding(VampTerminalDesign.space3)
            .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.cardMinHeight, alignment: .leading)
            .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
            .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius)
        }
        .buttonStyle(VampGlassPressStyle())
        .accessibilityLabel("How to use Vamp Terminal")
        .accessibilityHint("Opens the visual setup and terminal controls guide")
    }

    private var hostSetupRecovery: some View {
        Button {
            showingGuide = true
        } label: {
            HStack(spacing: VampTerminalDesign.space3) {
                Image(systemName: "questionmark.circle")
                    .font(.headline)
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                    Text("Have you installed a host?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VampGlassPalette.ink)
                    Text("Open the setup guide for Vamp Host or the terminal-only host.")
                        .font(.footnote)
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: VampTerminalDesign.space1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VampGlassPalette.inkTertiary)
            }
            .padding(VampTerminalDesign.space3)
            .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.cardMinHeight, alignment: .leading)
            .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
            .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius)
        }
        .buttonStyle(VampGlassPressStyle())
        .accessibilityLabel("Have you installed a host?")
        .accessibilityHint("Opens host installation and pairing instructions")
    }

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space3) {
            VampTerminalSectionLabel(
                title: "Hosts",
                detail: hosts.displayHosts.isEmpty ? nil : "\(hosts.displayHosts.count)"
            )

            if hosts.displayHosts.isEmpty {
                emptyHostsCard
            } else {
                VStack(spacing: VampTerminalDesign.space2) {
                    ForEach(hosts.displayHosts) { row in
                        hostRow(row)
                    }
                }
            }

            manualAddressEntry
        }
    }

    private func hostRow(_ row: DiscoveredHostRow) -> some View {
        let metadata = row.endpoint.metadata
        let isManual = metadata.appVersion == "unknown"
        let supportsMultipleTerminals = metadata.capabilities.contains(.supportsMultipleTerminals)
        let supportsTerminal = metadata.capabilities.contains(.supportsTerminal)
        let isSupported = supportsTerminal && supportsMultipleTerminals
        let isBusy = metadata.availability == .busy

        return ViewThatFits(in: .horizontal) {
            hostRowLayout(
                row: row,
                isManual: isManual,
                isSupported: isSupported,
                supportsTerminal: supportsTerminal,
                supportsMultipleTerminals: supportsMultipleTerminals,
                isBusy: isBusy,
                stacked: false
            )
            hostRowLayout(
                row: row,
                isManual: isManual,
                isSupported: isSupported,
                supportsTerminal: supportsTerminal,
                supportsMultipleTerminals: supportsMultipleTerminals,
                isBusy: isBusy,
                stacked: true
            )
        }
        .padding(VampTerminalDesign.space4)
        .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.hostCardMinHeight, alignment: .leading)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius)
    }

    @ViewBuilder
    private func hostRowLayout(
        row: DiscoveredHostRow,
        isManual: Bool,
        isSupported: Bool,
        supportsTerminal: Bool,
        supportsMultipleTerminals: Bool,
        isBusy: Bool,
        stacked: Bool
    ) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: VampTerminalDesign.space3) {
                HStack(spacing: VampTerminalDesign.space3) {
                    hostStatusDot(row: row, isBusy: isBusy)
                    hostRowDetails(
                        row: row,
                        isManual: isManual,
                        isSupported: isSupported,
                        supportsTerminal: supportsTerminal,
                        supportsMultipleTerminals: supportsMultipleTerminals,
                        isBusy: isBusy
                    )
                }
                HStack {
                    Spacer(minLength: 0)
                    hostRowAction(row: row, isManual: isManual, isSupported: isSupported, isBusy: isBusy)
                }
            }
        } else {
            HStack(spacing: VampTerminalDesign.space3) {
                hostStatusDot(row: row, isBusy: isBusy)
                hostRowDetails(
                    row: row,
                    isManual: isManual,
                    isSupported: isSupported,
                    supportsTerminal: supportsTerminal,
                    supportsMultipleTerminals: supportsMultipleTerminals,
                    isBusy: isBusy
                )
                Spacer(minLength: VampTerminalDesign.space1)
                hostRowAction(row: row, isManual: isManual, isSupported: isSupported, isBusy: isBusy)
            }
        }
    }

    private func hostStatusDot(row: DiscoveredHostRow, isBusy: Bool) -> some View {
        Circle()
            .fill(row.isAvailable && !isBusy ? VampGlassPalette.good : VampGlassPalette.inkSubtle)
            .frame(width: 10, height: 10)
            .overlay {
                if row.isAvailable && !isBusy {
                    Circle().stroke(VampGlassPalette.good.opacity(0.24), lineWidth: 5)
                }
            }
            .accessibilityHidden(true)
    }

    private func hostRowDetails(
        row: DiscoveredHostRow,
        isManual: Bool,
        isSupported: Bool,
        supportsTerminal: Bool,
        supportsMultipleTerminals: Bool,
        isBusy: Bool
    ) -> some View {
        let metadata = row.endpoint.metadata
        return VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
            HStack(spacing: VampTerminalDesign.space2) {
                Text(metadata.displayName)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(VampGlassPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if row.isSaved {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                }
            }
            Text("\(row.endpoint.hostname):\(row.endpoint.port)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(VampGlassPalette.inkTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            statusLine(
                row: row,
                isManual: isManual,
                isSupported: isSupported,
                supportsTerminal: supportsTerminal,
                supportsMultipleTerminals: supportsMultipleTerminals,
                isBusy: isBusy
            )
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func hostRowAction(
        row: DiscoveredHostRow,
        isManual: Bool,
        isSupported: Bool,
        isBusy: Bool
    ) -> some View {
        let metadata = row.endpoint.metadata
        if row.isAvailable && (isSupported || isManual) && !isBusy {
            Button {
                connect(to: row)
            } label: {
                Label("Connect", systemImage: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, VampTerminalDesign.space3)
                    .frame(minHeight: VampTerminalDesign.minTapTarget)
                    .background(VampGlassPalette.ink, in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous))
            }
            .buttonStyle(VampGlassPressStyle())
            .accessibilityLabel("Connect to \(metadata.displayName)")
        } else if !row.isAvailable {
            VampGlassStatusPill(text: "Offline", color: VampGlassPalette.inkSecondary)
        } else if isBusy {
            VampGlassStatusPill(text: "Busy", color: VampGlassPalette.warning)
        } else {
            VampGlassStatusPill(text: "Unsupported", color: VampGlassPalette.warning)
        }
    }

    private func statusLine(
        row: DiscoveredHostRow,
        isManual: Bool,
        isSupported: Bool,
        supportsTerminal: Bool,
        supportsMultipleTerminals: Bool,
        isBusy: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: connectionIcon(for: row.endpoint))
                .font(.system(size: 10, weight: .semibold))
            Text(connectionLabel(for: row.endpoint))
            Text("·")
            if isManual {
                Text("Capabilities checked after pairing")
            } else if !supportsTerminal {
                Text("Terminal Mode unavailable")
            } else if !supportsMultipleTerminals {
                Text("Single terminal only")
            } else if isBusy {
                Text("Another client is connected")
            } else if row.isAvailable && isSupported {
                Text("8 tabs")
            } else {
                Text("Waiting for host")
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(VampGlassPalette.inkTertiary)
        .lineLimit(1)
    }

    private var emptyHostsCard: some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space2) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(VampGlassPalette.inkSecondary)
            Text("Looking for Vamp Host")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(VampGlassPalette.ink)
            Text("Keep Vamp Host open on your Mac, or enter its Tailscale MagicDNS name below.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(VampGlassPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VampTerminalDesign.space4)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius)
    }

    private var manualAddressEntry: some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space3) {
            Button {
                showingManualAddress.toggle()
            } label: {
                Label("Connect with Tailscale address", systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.ink)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(VampGlassPressStyle())

            if showingManualAddress {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: VampTerminalDesign.space2) {
                        addressField
                        addAddressButton
                    }

                    VStack(spacing: VampTerminalDesign.space2) {
                        addressField
                        addAddressButton
                            .frame(maxWidth: .infinity)
                    }
                }
                Text("Vamp Terminal uses the Vamp Host pairing protocol on port 9471. Tailscale must be active on both devices.")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let manualAddressError {
                    Label(manualAddressError, systemImage: "exclamationmark.triangle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(VampGlassPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, VampTerminalDesign.space1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: showingManualAddress) { _, isShowing in
            if !isShowing {
                manualAddressFocused = false
                manualAddressError = nil
            }
        }
        .onChange(of: manualAddress) { _, _ in
            manualAddressError = nil
        }
    }

    private var addressField: some View {
        TextField("mac.tailnet.ts.net or 100.x.y.z", text: $manualAddress)
            .focused($manualAddressFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(VampGlassPalette.ink)
            .padding(.horizontal, VampTerminalDesign.space3)
            .frame(minHeight: VampTerminalDesign.minTapTarget)
            .vampGlassSurface(.field, cornerRadius: VampTerminalDesign.controlRadius)
            .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
            .submitLabel(.done)
            .onSubmit {
                addManualHost()
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        manualAddressFocused = false
                    }
                }
            }
    }

    private var addAddressButton: some View {
        Button {
            addManualHost()
        } label: {
            Text("Add")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white)
                .padding(.horizontal, VampTerminalDesign.space3)
                .frame(minHeight: VampTerminalDesign.minTapTarget)
                .background(VampGlassPalette.ink, in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous))
        }
        .buttonStyle(VampGlassPressStyle())
        .disabled(manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var pairingNote: some View {
        HStack(alignment: .top, spacing: VampTerminalDesign.space3) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(VampGlassPalette.good)
            Text("Connections stay on your LAN or Tailscale. On first use, approve the pairing request in Vamp Host; the signed host identity is then remembered on this device.")
                .font(.footnote)
                .foregroundStyle(VampGlassPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VampTerminalDesign.space4)
        .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.cardMinHeight, alignment: .leading)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius, color: VampGlassPalette.good.opacity(0.28))
    }

    private var connectionProgressCard: some View {
        HStack(spacing: VampTerminalDesign.space3) {
            ProgressView()
                .tint(VampGlassPalette.ink)
            VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                Text(connectionPhaseTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(VampGlassPalette.ink)
                Text(connectionPhaseMessage)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                Task { await environment.sessionCoordinator.endSession() }
            } label: {
                Text("Cancel")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.ink)
                    .padding(.horizontal, VampTerminalDesign.space3)
                    .frame(minHeight: VampTerminalDesign.minTapTarget)
                    .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                    .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
            }
            .buttonStyle(VampGlassPressStyle())
        }
        .padding(VampTerminalDesign.space4)
        .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.cardMinHeight, alignment: .leading)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius, color: VampGlassPalette.ruleStrong)
    }

    private func messageCard(title: String, message: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: VampTerminalDesign.space3) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: VampTerminalDesign.space6)
            VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(VampGlassPalette.ink)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(VampTerminalDesign.space4)
        .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.cardMinHeight, alignment: .leading)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius, color: tint.opacity(0.30))
    }

    private func connectionAttentionCard(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space3) {
            HStack(alignment: .top, spacing: VampTerminalDesign.space3) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(VampGlassPalette.warning)
                    .frame(width: VampTerminalDesign.space6)
                VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                    Text("Connection needs attention")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(VampGlassPalette.ink)
                    Text(humanizedConnectionError(error))
                        .font(.footnote)
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: VampTerminalDesign.space2) {
                Button {
                    if let row = selectedHostForRetry {
                        connect(to: row)
                    } else {
                        Task { await hosts.refresh() }
                    }
                } label: {
                    Label(selectedHostForRetry == nil ? "Refresh hosts" : "Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(VampGlassPalette.ink)
                        .padding(.horizontal, VampTerminalDesign.space3)
                        .frame(minHeight: VampTerminalDesign.minTapTarget)
                        .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                        .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius, color: VampGlassPalette.ruleStrong)
                }
                .buttonStyle(VampGlassPressStyle())

                Button {
                    Task { await environment.sessionCoordinator.endSession() }
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .padding(.horizontal, VampTerminalDesign.space3)
                        .frame(minHeight: VampTerminalDesign.minTapTarget)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(VampTerminalDesign.space4)
        .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.cardMinHeight, alignment: .leading)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius, color: VampGlassPalette.warning.opacity(0.30))
    }

    private var selectedHostForRetry: DiscoveredHostRow? {
        guard let selectedHostID = hosts.selectedHostID else { return nil }
        return hosts.displayHosts.first(where: { $0.id == selectedHostID })
            ?? hosts.hosts.first(where: { $0.id == selectedHostID })
    }

    private func terminalUnavailableCard(title: String, message: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space3) {
            HStack(alignment: .top, spacing: VampTerminalDesign.space3) {
                Image(systemName: icon)
                    .foregroundStyle(VampGlassPalette.warning)
                    .frame(width: VampTerminalDesign.space6)
                VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(VampGlassPalette.ink)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                Task { await environment.sessionCoordinator.endSession() }
            } label: {
                Text("Disconnect")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.ink)
                    .padding(.horizontal, VampTerminalDesign.space3)
                    .frame(minHeight: VampTerminalDesign.minTapTarget)
                    .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                    .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius, color: VampGlassPalette.ruleStrong)
            }
            .buttonStyle(VampGlassPressStyle())
        }
        .padding(VampTerminalDesign.space4)
        .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.cardMinHeight, alignment: .leading)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius, color: VampGlassPalette.warning.opacity(0.30))
    }

    private var isConnecting: Bool {
        switch environment.sessionCoordinator.phase {
        case .connecting, .signalingConnected, .negotiating:
            return true
        case .idle, .waitingForMedia, .receiving, .error:
            return false
        }
    }

    private var connectionPhaseTitle: String {
        switch environment.sessionCoordinator.phase {
        case .connecting: return "Connecting to Mac"
        case .signalingConnected: return "Approve this device on the Mac"
        case .negotiating: return "Opening secure channel"
        default: return "Connecting"
        }
    }

    private var connectionPhaseMessage: String {
        switch environment.sessionCoordinator.phase {
        case .connecting:
            return "Looking for the host over LAN or Tailscale…"
        case .signalingConnected:
            return "Vamp Host is waiting for approval. Bring the host dashboard forward and tap Approve."
        case .negotiating:
            return "Waiting for host approval and the signed WebRTC channel…"
        default:
            return "Waiting for the signed WebRTC session to become ready…"
        }
    }

    private func connect(to row: DiscoveredHostRow) {
        hosts.connect(to: row)
        Task {
            await environment.sessionCoordinator.connect(
                to: row.endpoint,
                qualityPreset: .performance
            )
            if environment.sessionCoordinator.phase != .error {
                hosts.markHostConnected(row.id)
            }
        }
    }

    private func addManualHost() {
        let address = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            manualAddressError = "Enter a MagicDNS name or a 100.x.y.z Tailscale address."
            manualAddressFocused = true
            return
        }
        guard let row = hosts.addManualHost(address: address) else {
            manualAddressError = "That address could not be added. Check the hostname or Tailscale IP and try again."
            manualAddressFocused = true
            return
        }
        manualAddress = ""
        manualAddressError = nil
        manualAddressFocused = false
        showingManualAddress = false
        connect(to: row)
    }

    private func connectionIcon(for endpoint: ResolvedHostEndpoint) -> String {
        let hostname = endpoint.hostname.lowercased()
        if hostname.contains("ts.net") || hostname.hasPrefix("100.") {
            return "shield.lefthalf.filled"
        }
        return "wifi"
    }

    private func connectionLabel(for endpoint: ResolvedHostEndpoint) -> String {
        let hostname = endpoint.hostname.lowercased()
        if hostname.contains("ts.net") || hostname.hasPrefix("100.") {
            return "Tailscale"
        }
        return "LAN"
    }

    /// Turns a raw transport/error string into a plain-language sentence with a
    /// concrete next step. Unknown errors fall through to the original text, so
    /// this only ever adds clarity.
    private func humanizedConnectionError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("pair") || lower.contains("approve") || lower.contains("trust") {
            return "This device isn't paired yet. Open Vamp Host on the Mac, approve the pairing request, then retry."
        }
        if lower.contains("busy") || lower.contains("another client") || lower.contains("in use") {
            return "Another client is already connected to this host. Disconnect it, or try again in a moment."
        }
        if lower.contains("fingerprint") || lower.contains("identity") || lower.contains("mismatch") || lower.contains("certificate") {
            return "The host's identity didn't match the one saved on this device. If you reinstalled Vamp Host, forget the host and pair again."
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return "The Mac didn't answer in time. Make sure Vamp Host is open and the Mac is awake, then retry."
        }
        if lower.contains("refused") || lower.contains("unreachable") || lower.contains("no route") || lower.contains("offline") || lower.contains("not reach") {
            return "Couldn't reach the Mac. Check that both devices are on the same Wi-Fi or Tailscale network, then retry."
        }
        return raw
    }
}
