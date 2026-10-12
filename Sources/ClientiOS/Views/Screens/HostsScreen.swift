import SwiftUI
#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

struct HostsScreen: View {
    let environment: ClientAppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject private var hostsVM: HostsListViewModel
    @ObservedObject private var sessionCoordinator: ClientSessionCoordinator
    @State private var manualAddress = ""
    @State private var wakingHostID: UUID?
    @State private var wakeFeedback: String?
    @State private var wakeFeedbackIsError = false
    @State private var isRefreshing = false
    @State private var editingSavedHost: DiscoveredHostRow?
    @State private var editedSavedHostName = ""
    @State private var pendingTailscaleHost: DiscoveredHostRow?
    @State private var pendingTerminalOnlyHost: DiscoveredHostRow?

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        self.sessionCoordinator = environment.sessionCoordinator
        self.hostsVM = environment.sharedHostsViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            PRScreenHeader(
                title: "Hosts",
                host: headerHostLine,
                latency: latencyText,
                state: headerState
            )

            ScrollView {
                VStack(spacing: 12) {
                    connectionOverviewCard

                    PRCard("Available Hosts", trailing: {
                        Button {
                            Task { await refreshHosts() }
                        } label: {
                            HStack(spacing: 6) {
                                if isRefreshing {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .tint(PR.bg)
                                }
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 10, weight: .bold))
                                Text(isRefreshing ? "Scanning" : "Refresh")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(PR.accent2)
                            .overlay(Capsule().strokeBorder(PR.accent2.opacity(0.45), lineWidth: 1))
                            .clipShape(Capsule())
                            .foregroundColor(PR.bg)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isRefreshing)
                    }) {
                        if hostsVM.displayHosts.isEmpty {
                            emptyHostsState
                        } else {
                            VStack(spacing: 0) {
                                ForEach(hostsVM.displayHosts) { host in
                                    hostRow(host)
                                }
                            }
                        }
                    }

                    PRCard("Connect Manually") {
                        VStack(spacing: 0) {
                            connectSectionHeader(
                                title: "Address",
                                subtitle: "Enter the IP, hostname, or Tailscale address shown by Vamp Host."
                            )

                            VStack(alignment: .leading, spacing: 10) {
                                TextField("192.168.1.42  ·  my-mac.tailnet.ts.net", text: $manualAddress)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(PR.fg)
#if canImport(UIKit) && !os(macOS)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
#endif
                                    .submitLabel(.go)
                                    .onSubmit {
                                        connectManualAddress()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 12)
                                    .background(PR.bg2)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: PR.r8)
                                            .strokeBorder(PR.border, lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: PR.r8))

                                Button {
                                    connectManualAddress()
                                } label: {
                                    HStack(spacing: 8) {
                                        Text("Connect")
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(manualAddressButtonEnabled ? PR.bg : PR.dim)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(manualAddressButtonEnabled ? PR.accent : PR.bg2)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: PR.r8)
                                            .strokeBorder(manualAddressButtonEnabled ? PR.accent.opacity(0.45) : PR.border, lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: PR.r8))
                                }
                                .buttonStyle(.plain)
                                .disabled(!manualAddressButtonEnabled)

                                Text("Port 9471 is used when no port is specified.")
                                    .font(.caption)
                                    .foregroundColor(PR.dim)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }

                        if !recentConnectHosts.isEmpty {
                            Divider().overlay(PR.border)

                            connectSectionHeader(
                                title: "Recent",
                                subtitle: "Saved and recently used hosts"
                            )

                            VStack(spacing: 0) {
                                ForEach(Array(recentConnectHosts.enumerated()), id: \.element.id) { index, host in
                                    recentConnectRow(host, isLast: index == recentConnectHosts.count - 1)
                                }
                            }
                        }

                        Divider().overlay(PR.border)

                        Button(action: {}) {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(PR.bg2)
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        Image(systemName: "qrcode.viewfinder")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(PR.dim)
                                    }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Scan QR Code")
                                        .font(.body.weight(.medium))
                                        .foregroundColor(PR.fg)
                                    Text("Scan a code shown by Vamp Host")
                                        .font(.caption)
                                        .foregroundColor(PR.dim)
                                }

                                Spacer()

                                Text("Coming Soon")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(PR.dim)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .refreshable {
                await refreshHosts()
            }
        }
        .background(PR.bg)
        .overlay(alignment: .bottom) {
            if let wakeFeedback {
                wakeToast(wakeFeedback, isError: wakeFeedbackIsError)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            await hostsVM.start()
        }
        .onChangeCompat(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await refreshHosts() }
        }
        .onChangeCompat(of: sessionCoordinator.phase) { phase in
            if phase == .waitingForMedia || phase == .receiving, let hostID = hostsVM.selectedHostID {
                hostsVM.markHostConnected(hostID)
            }
        }
        .alert("Edit Saved Host", isPresented: Binding(
            get: { editingSavedHost != nil },
            set: { if !$0 { editingSavedHost = nil } }
        )) {
            TextField("Host name", text: $editedSavedHostName)
            Button("Save") {
                guard let host = editingSavedHost else { return }
                hostsVM.renameSavedHost(host.id, to: editedSavedHostName)
                editingSavedHost = nil
            }
            Button("Cancel", role: .cancel) {
                editingSavedHost = nil
            }
        } message: {
            Text("Update how this saved host appears in the list.")
        }
        .alert("Turn on Tailscale", isPresented: Binding(
            get: { pendingTailscaleHost != nil },
            set: { if !$0 { pendingTailscaleHost = nil } }
        )) {
            Button("Open Tailscale") {
                #if canImport(UIKit) && !os(macOS)
                if let url = URL(string: "tailscale://") { UIApplication.shared.open(url) }
                #endif
                pendingTailscaleHost = nil
            }
            Button("Connect anyway") {
                let host = pendingTailscaleHost
                pendingTailscaleHost = nil
                if let host { performConnect(host) }
            }
            Button("Cancel", role: .cancel) { pendingTailscaleHost = nil }
        } message: {
            Text("This looks like a Tailscale address. Make sure the Tailscale VPN is connected on this iPhone, then try again — otherwise the host can’t be reached.")
        }
        .alert("Terminal-only host", isPresented: Binding(
            get: { pendingTerminalOnlyHost != nil },
            set: { if !$0 { pendingTerminalOnlyHost = nil } }
        )) {
            Button("OK", role: .cancel) { pendingTerminalOnlyHost = nil }
        } message: {
            Text("\(pendingTerminalOnlyHost?.title ?? "This host") only provides terminal tabs. Use the separate Vamp Terminal client for this host. Vamp Control connects to Vamp Host for screen and remote-control sessions.")
        }
    }

    private func hostRow(_ host: DiscoveredHostRow) -> some View {
        let isActive = hostsVM.selectedHostID == host.id
        let signalColor = signalTint(for: host)
        let actionState = rowActionState(host)
        let isTerminalOnly = host.endpoint.metadata.capabilities.isTerminalOnlyHost
        let canWake = !host.isAvailable
            && (host.endpoint.metadata.macAddress != nil || host.endpoint.bonjourServiceName != nil)
        let isWaking = wakingHostID == host.id

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Connect tap area — disabled when host is unavailable
                Button {
                    connect(host)
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(host.isAvailable ? PR.accent : PR.dim)
                            .frame(width: 8, height: 8)
                            .shadow(color: host.isAvailable ? PR.accent.opacity(0.8) : .clear, radius: 5)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(host.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(HostNameColor.color(for: host.id))
                                if host.isSaved {
                                    Image(systemName: "checkmark.shield.fill")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(PR.accent)
                                }
                                if isTerminalOnly {
                                    Text("TERMINAL ONLY")
                                        .font(.caption2.weight(.bold))
                                        .foregroundColor(PR.warn)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(PR.warn.opacity(0.10))
                                        .overlay(Capsule().strokeBorder(PR.warn.opacity(0.35), lineWidth: 1))
                                        .clipShape(Capsule())
                                }
                            }
                            Text("\(host.endpoint.hostname) · \(host.endpoint.metadata.appVersion)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(PR.dim)
                            if isTerminalOnly && !environment.supportsTerminalOnlyHosts {
                                Text("use Vamp Terminal for terminal tabs")
                                    .font(.caption2)
                                    .foregroundColor(PR.warn)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!host.isAvailable || actionState.isBusy)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(signalLabel(for: host))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundColor(signalColor)
                        .background(signalColor.opacity(0.12))
                        .overlay(
                            Capsule().strokeBorder(signalColor.opacity(0.45), lineWidth: 1)
                        )
                        .clipShape(Capsule())

                    if canWake {
                        wakeButton(for: host, isWaking: isWaking)
                    } else {
                        Text(actionState.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(actionState.color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(actionState.color.opacity(0.10))
                            .overlay(
                                Capsule().strokeBorder(actionState.color.opacity(0.45), lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }

                    hostRowMenu(host, canWake: canWake, isWaking: isWaking)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isActive ? actionState.color.opacity(0.08) : Color.clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isActive ? actionState.color : .clear)
                    .frame(width: 3)
            }

            Divider().overlay(PR.border)
        }
        .contextMenu {
            if host.isSaved {
                Button(role: .destructive) {
                    hostsVM.removeSavedHost(host.id)
                } label: {
                    Label("Remove Saved Host", systemImage: "trash")
                }
            }
        }
    }

    private func hostRowMenu(_ host: DiscoveredHostRow, canWake: Bool, isWaking: Bool) -> some View {
        Menu {
            if canWake {
                Button(isWaking ? "Waking..." : "Wake Host") {
                    sendWake(host)
                }
                .disabled(isWaking)
            }

            if host.isSaved {
                Button("Rename Host") {
                    editingSavedHost = host
                    editedSavedHostName = host.title
                }
                Button("Remove Saved Host", role: .destructive) {
                    hostsVM.removeSavedHost(host.id)
                }
            } else {
                Button("Save Host") {
                    hostsVM.saveHost(host.id)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(PR.dim)
                .frame(width: 30, height: 24)
                .background(PR.bg2)
                .overlay(
                    Capsule().strokeBorder(PR.border, lineWidth: 1)
                )
                .clipShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private func wakeButton(for host: DiscoveredHostRow, isWaking: Bool) -> some View {
        Button {
            sendWake(host)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isWaking ? "bolt.horizontal.fill" : "power")
                    .font(.system(size: 9, weight: .bold))
                Text(isWaking ? "waking…" : "wake")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundColor(PR.warn)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(PR.warn.opacity(0.12))
            .overlay(
                Capsule().strokeBorder(PR.warn.opacity(0.45), lineWidth: 1)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isWaking)
    }

    private func sendWake(_ host: DiscoveredHostRow) {
        let mac = host.endpoint.metadata.macAddress
        let bonjourName = host.endpoint.bonjourServiceName
        guard mac != nil || bonjourName != nil else { return }
        AppHaptics.impact(.rigid)
        wakingHostID = host.id
        let targetHost = host.endpoint.hostname
        Task {
            // WakeCoordinator fires both paths in parallel — magic packet (Ethernet / Intel) and the
            // Bonjour resolve that triggers the LAN Sleep Proxy (the only path that wakes Apple-Silicon
            // Macs on Wi-Fi) — captures errors, and reports what was actually dispatched. The spinner
            // clears when the operations truly finish, not after a fixed delay.
            let outcome = await WakeCoordinator().wake(
                macAddress: mac,
                bonjourServiceName: bonjourName,
                targetHost: targetHost,
                wakeSupported: host.endpoint.metadata.wakeSupported
            )
            showWakeFeedback(outcome)
            guard !outcome.isError else {
                if wakingHostID == host.id { wakingHostID = nil }
                await hostsVM.refresh()
                return
            }
            // The Mac takes ~5–30s to wake and re-advertise; poll and auto-connect the moment it
            // reappears instead of leaving the user to keep tapping. Bounded so a host that can't
            // be woken clears the spinner and leaves the honest wake-guidance toast.
            await pollAndConnectAfterWake(host)
        }
    }

    private func pollAndConnectAfterWake(_ host: DiscoveredHostRow) async {
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            guard wakingHostID == host.id else { return }
            if sessionCoordinator.phase == .receiving { wakingHostID = nil; return }
            await hostsVM.refresh()
            if let live = wokenHostNowOnline(host) {
                wakingHostID = nil
                connect(live)
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
        if wakingHostID == host.id { wakingHostID = nil }
    }

    private func wokenHostNowOnline(_ host: DiscoveredHostRow) -> DiscoveredHostRow? {
        let mac = host.endpoint.metadata.macAddress?.lowercased()
        let name = host.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return hostsVM.displayHosts.first { row in
            guard row.isAvailable else { return false }
            if row.id == host.id { return true }
            if let mac, let rowMac = row.endpoint.metadata.macAddress?.lowercased(), mac == rowMac { return true }
            return !name.isEmpty && row.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name
        }
    }

    private func showWakeFeedback(_ outcome: WakeCoordinator.Outcome) {
        if outcome.isError { AppHaptics.error() } else { AppHaptics.success() }
        let message = outcome.userMessage
        withAnimation(.easeOut(duration: 0.2)) {
            wakeFeedback = message
            wakeFeedbackIsError = outcome.isError
        }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if wakeFeedback == message {
                withAnimation(.easeOut(duration: 0.25)) { wakeFeedback = nil }
            }
        }
    }

    private func wakeToast(_ message: String, isError: Bool) -> some View {
        let tint = isError ? PR.err : PR.accent2
        return HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "bolt.horizontal.fill")
                .font(.system(size: 11, weight: .bold))
            Text(message)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PR.bg2)
        .overlay(
            RoundedRectangle(cornerRadius: PR.r8).strokeBorder(tint.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: PR.r8))
    }

    private func refreshHosts() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await hostsVM.refresh()
        isRefreshing = false
    }

    private var latencyText: String {
        guard let latency = sessionCoordinator.lastRoundTripLatencyMs else { return "--" }
        return String(format: "%.1fms", latency)
    }

    private var manualAddressButtonEnabled: Bool {
        !manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var recentConnectHosts: [DiscoveredHostRow] {
        let visibleHostIDs = Set(hostsVM.hosts.map(\.id))
        return Array(hostsVM.savedHosts.filter { !visibleHostIDs.contains($0.id) }.prefix(3))
    }

    private var headerState: PRScreenHeader.State {
        switch sessionCoordinator.phase {
        case .receiving: .live
        case .error: .error
        default: .idle
        }
    }

    private var headerHostLine: String {
        switch sessionCoordinator.phase {
        case .receiving:
            return sessionCoordinator.connectedHostName ?? "live session"
        case .connecting, .signalingConnected, .negotiating, .waitingForMedia:
            return "trusted \(hostsVM.savedHosts.count) · \(hostAvailabilitySummary)"
        case .error, .idle:
            return "trusted \(hostsVM.savedHosts.count) · \(hostAvailabilitySummary)"
        }
    }

    private var hostAvailabilitySummary: String {
        let remote = hostsVM.displayHosts.filter { !$0.isTerminalOnlyHost && $0.isAvailable }.count
        let terminal = hostsVM.displayHosts.filter { $0.isTerminalOnlyHost && $0.isAvailable }.count
        if remote == 0, terminal > 0 { return "no remote hosts · \(terminal) terminal" }
        if terminal > 0 { return "online \(remote) · \(terminal) terminal" }
        return "online \(remote)"
    }

    private func signalLabel(for host: DiscoveredHostRow) -> String {
        if host.endpoint.hostname.contains("ts.net") || host.endpoint.hostname.hasPrefix("100.") { return "RELAY" }
        return "LAN"
    }

    private func signalTint(for host: DiscoveredHostRow) -> Color {
        if !host.isAvailable { return PR.err }
        return signalLabel(for: host) == "RELAY" ? PR.warn : PR.accent
    }

    private var connectionStatusText: LocalizedStringKey {
        switch sessionCoordinator.phase {
        case .receiving:
            return "session live"
        case .connecting, .signalingConnected, .negotiating, .waitingForMedia:
            return "connecting to host..."
        case .error:
            return "connection failed"
        case .idle:
            return "ready to connect"
        }
    }

    private var connectionStatusColor: Color {
        switch sessionCoordinator.phase {
        case .receiving:
            return PR.accent
        case .connecting, .signalingConnected, .negotiating, .waitingForMedia:
            return PR.warn
        case .error:
            return PR.err
        case .idle:
            return PR.accent2
        }
    }

    private var connectionDetailText: String {
        switch sessionCoordinator.phase {
        case .idle:
            return "choose a trusted host below or connect directly with an address"
        case .error:
            return "the last session did not start cleanly. check the host, then retry or rescan."
        case .connecting, .signalingConnected, .negotiating, .waitingForMedia:
            return "setting up the remote session and waiting for the stream to become ready"
        case .receiving:
            return "stream is live. disconnect when you are finished or jump to another trusted host below."
        }
    }

    private var hasRetryTarget: Bool {
        guard let hostID = hostsVM.selectedHostID else { return false }
        return hostsVM.hosts.contains(where: { $0.id == hostID }) || hostsVM.savedHosts.contains(where: { $0.id == hostID })
    }

    private var connectionOverviewCard: some View {
        PRCard("status") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(connectionStatusColor)
                        .frame(width: 10, height: 10)
                        .shadow(color: connectionStatusColor.opacity(0.8), radius: 6)
                        .padding(.top, 5)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(connectionStatusText)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(connectionStatusColor)

                        Text(connectionDetailText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(PR.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }

                HStack(spacing: 8) {
                    primaryConnectionAction

                    if sessionCoordinator.phase != .receiving {
                        secondaryScanAction
                    }
                }

                HStack(spacing: 10) {
                    Text("trusted \(hostsVM.savedHosts.count)")
                    Text("·")
                        .foregroundColor(PR.dim)
                    Text(hostAvailabilitySummary)
                    if sessionCoordinator.phase != .idle && !latencyText.isEmpty {
                        Text("·")
                            .foregroundColor(PR.dim)
                        Text("latency \(latencyText)")
                            .foregroundColor(connectionStatusColor)
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(PR.dim)
            }
        }
    }

    private var primaryConnectionAction: some View {
        Group {
            switch sessionCoordinator.phase {
            case .connecting, .signalingConnected, .negotiating, .waitingForMedia:
                Button {
                    Task { await sessionCoordinator.disconnect() }
                } label: {
                    actionCapsule(title: "stop", tint: PR.err, fill: PR.err.opacity(0.10))
                }
            case .error:
                if hasRetryTarget {
                    Button {
                        retryConnection()
                    } label: {
                        actionCapsule(title: "try again", tint: PR.warn, fill: PR.warn.opacity(0.10))
                    }
                } else {
                    Button {
                        Task { await refreshHosts() }
                    } label: {
                        actionCapsule(title: isRefreshing ? "scanning..." : "scan now", tint: PR.accent, fill: PR.accent.opacity(0.12))
                    }
                    .disabled(isRefreshing)
                }
            case .idle:
                Button {
                    Task { await refreshHosts() }
                } label: {
                    actionCapsule(title: isRefreshing ? "scanning..." : "scan now", tint: PR.accent, fill: PR.accent.opacity(0.12))
                }
                .disabled(isRefreshing)
            case .receiving:
                Button {
                    Task { await sessionCoordinator.disconnect() }
                } label: {
                    actionCapsule(title: "disconnect", tint: PR.err, fill: PR.err.opacity(0.10))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var secondaryScanAction: some View {
        Button {
            Task { await refreshHosts() }
        } label: {
            actionCapsule(title: "+ scan", tint: PR.accent2, fill: PR.accent2.opacity(0.10))
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
    }

    private func actionCapsule(title: String, tint: Color, fill: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(fill)
            .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
            .clipShape(Capsule())
    }

    private var emptyHostsState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(PR.bg2)
                        .frame(width: 34, height: 34)
                    Image(systemName: isRefreshing ? "antenna.radiowaves.left.and.right" : "dot.radiowaves.left.and.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(PR.accent2)
                        .opacity(isRefreshing ? 1 : 0.88)
                        .animation(.easeInOut(duration: 0.25), value: isRefreshing)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(isRefreshing ? "scanning local network…" : "no hosts found")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(PR.fg)
                    Text(isRefreshing
                         ? "looking for Vamp Host on your network"
                         : "open Vamp Host on your Mac, then scan")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(PR.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                Task { await refreshHosts() }
            } label: {
                HStack(spacing: 8) {
                    Text(isRefreshing ? "scanning…" : "+ scan network")
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(PR.bg)
                    }
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.bg)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(PR.accent2)
                .overlay(
                    RoundedRectangle(cornerRadius: PR.r8)
                        .strokeBorder(PR.accent2.opacity(0.45), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: PR.r8))
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
        }
    }

    private func rowActionState(_ host: DiscoveredHostRow) -> (title: String, color: Color, isBusy: Bool) {
        if !host.isAvailable {
            return ("offline", PR.err, false)
        }

        if host.endpoint.metadata.capabilities.isTerminalOnlyHost && !environment.supportsTerminalOnlyHosts {
            return ("terminal only", PR.warn, false)
        }

        guard hostsVM.selectedHostID == host.id else {
            return ("connect", PR.accent, false)
        }

        switch sessionCoordinator.phase {
        case .receiving:
            return ("live", PR.accent, false)
        case .connecting, .signalingConnected, .negotiating, .waitingForMedia:
            return ("connecting", PR.warn, true)
        case .error:
            return ("retry", PR.err, false)
        case .idle:
            return ("connect", PR.accent, false)
        }
    }

    private func connect(_ host: DiscoveredHostRow) {
        if host.endpoint.metadata.capabilities.isTerminalOnlyHost && !environment.supportsTerminalOnlyHosts {
            pendingTerminalOnlyHost = host
            return
        }
        // Remind the user to enable the VPN before a Tailscale/relay address —
        // it can't resolve without Tailscale connected.
        if isRelayHost(host) && sessionCoordinator.tailscaleVPNStatus == .inactive {
            pendingTailscaleHost = host
            return
        }
        performConnect(host)
    }

    private func performConnect(_ host: DiscoveredHostRow) {
        AppHaptics.impact(.medium)
        hostsVM.connect(to: host)
        // Don't persist on tap — saving here wrote failed/typo'd attempts and created duplicates.
        // Persistence happens only after the host's signed answer verifies
        // (HostsListViewModel.recordVerifiedHostIdentity), keyed by the canonical fingerprint.
        Task {
            await sessionCoordinator.connect(
                to: host.endpoint,
                qualityPreset: environment.effectivePreferredQualityPreset
            )
        }
    }

    private func isRelayHost(_ host: DiscoveredHostRow) -> Bool {
        host.endpoint.hostname.contains("ts.net") || host.endpoint.hostname.hasPrefix("100.")
    }

    private func connectManualAddress() {
        guard let added = hostsVM.addManualHost(address: manualAddress), added.isAvailable else { return }
        connect(added)
    }

    private func connectSectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(PR.fg)
                    .textCase(.lowercase)
            Text(subtitle)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(PR.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func recentConnectRow(_ host: DiscoveredHostRow, isLast: Bool) -> some View {
        Button {
            connect(host)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(host.isAvailable ? PR.accent : PR.dim)
                    .frame(width: 8, height: 8)
                    .shadow(color: host.isAvailable ? PR.accent.opacity(0.8) : .clear, radius: 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(host.title)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(HostNameColor.color(for: host.id))
                    Text("\(host.endpoint.hostname):\(host.endpoint.port)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(PR.dim)
                }

                Spacer()

                Text("connect")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(host.isAvailable ? PR.accent : PR.dim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!host.isAvailable)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().overlay(PR.border)
            }
        }
    }

    private func retryConnection() {
        guard let hostID = hostsVM.selectedHostID,
              let host = hostsVM.hosts.first(where: { $0.id == hostID })
                ?? hostsVM.savedHosts.first(where: { $0.id == hostID }) else { return }
        AppHaptics.impact(.medium)
        Task {
            await sessionCoordinator.disconnect()
            connect(host)
        }
    }
}

#Preview("HostsScreen") {
    HostsScreen(environment: ClientAppEnvironment.makeDefault(clientName: "Vamp Control"))
}
