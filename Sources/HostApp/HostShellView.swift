import SwiftUI
import Permissions
import Discovery
import Diagnostics
import SharedModels
import Network
import SharedUtilities
import Foundation
#if os(macOS)
import AppKit
#endif

/// Validates that a string is a valid IPv4 address.
private func isValidIPAddress(_ address: String) -> Bool {
    let ipPattern = "^(\\d{1,3}\\.){3}\\d{1,3}$"
    guard let regex = try? NSRegularExpression(pattern: ipPattern) else { return false }
    let range = NSRange(address.startIndex..<address.endIndex, in: address)
    return regex.firstMatch(in: address, range: range) != nil
}

/// Returns the first non-loopback IPv4 address of the host, or nil.
private func getLocalIPAddress() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let sa = ptr.pointee.ifa_addr.pointee
        guard sa.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: ptr.pointee.ifa_name)
        // Skip loopback
        guard name != "lo0" else { continue }
        // Prefer en0 (Wi-Fi / Ethernet)
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(ptr.pointee.ifa_addr, socklen_t(sa.sa_len),
                       &hostname, socklen_t(hostname.count),
                       nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: hostname)
            if name.hasPrefix("en") { return ip }
            if address == nil { address = ip }
        }
    }
    return address
}

struct HostShellView: View {
    @ObservedObject var environment: HostAppEnvironment
    @AppStorage("host.onboarding.completed") private var onboardingCompleted = false
    @AppStorage("host.dashboard.compact") private var isCompact = false
    @AppStorage("host.appearance.dark") private var prefersDarkAppearance = false
    @State private var showOnboarding = false
    @State private var showSettings = false
    @State private var showWidgetHelp = false
    @State private var compactSize = CGSize(width: 300, height: 240)

    var body: some View {
        // The in-app compact "mini window" has been retired in favor of the macOS
        // desktop widget — toggling the window toolbar/title bar for that mode
        // caused an AppKit title-bar layout crash (_updateTitleTextField) on
        // macOS 26. The window now always uses the stable full dashboard; the
        // widget is the always-on mini surface.
        HostMinimalDashboard(environment: environment, isCompact: .constant(false))
            .preferredColorScheme(prefersDarkAppearance ? .dark : .light)
            #if os(macOS)
            .onAppear {
                isCompact = false
                HostWindowCloseBehaviorController.shared.setCompact(false, size: compactSize)
                HostWindowCloseBehaviorController.shared.setDarkAppearance(prefersDarkAppearance)
            }
            .onChange(of: prefersDarkAppearance) { isDark in
                HostWindowCloseBehaviorController.shared.setDarkAppearance(isDark)
            }
            #endif
            .overlay {
                HostConnectionFrame(
                    phase: environment.sessionCoordinator.phase,
                    hasPermissionBlockers: !environment.permissionsViewModel.blockers.isEmpty
                )
                .allowsHitTesting(false)
                .padding(4)
            }
            // Always keep the standard window toolbar — never toggle it. Toggling
            // .windowToolbar visibility drove an AppKit title-bar layout crash.
            .toolbar(.automatic, for: .windowToolbar)
            .task {
                await environment.startRuntimeIfNeeded()
                if !onboardingCompleted {
                    showOnboarding = true
                }
            }
            .sheet(isPresented: $showOnboarding) {
                HostOnboardingView(environment: environment) {
                    onboardingCompleted = true
                    showOnboarding = false
                }
            }
            .toolbar {
                ToolbarItem {
                    Menu {
                        Section("Vamp Host") {
                            Button {
                                prefersDarkAppearance.toggle()
                            } label: {
                                Label(
                                    prefersDarkAppearance ? "Use light appearance" : "Use dark appearance",
                                    systemImage: prefersDarkAppearance ? "sun.max" : "moon"
                                )
                            }
                        }

                        Section("Manage") {
                            Button {
                                environment.chooseAdditionalWorkspaceFolder()
                            } label: {
                                Label("Add workspace folder…", systemImage: "folder.badge.plus")
                            }
                            Button {
                                showSettings = true
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                            Button {
                                showWidgetHelp = true
                            } label: {
                                Label("Desktop widget", systemImage: "square.grid.2x2")
                            }
                            Button {
                                showOnboarding = true
                            } label: {
                                Label("Setup guide", systemImage: "questionmark.circle")
                            }
                        }
                    } label: {
                        Label("Host menu", systemImage: "ellipsis.circle")
                    }
                    .help("Vamp Host menu")
                }
            }
            .popover(isPresented: $showSettings) {
                HostSettingsView(environment: environment, showOnboarding: {
                    showSettings = false
                    showOnboarding = true
                })
                .frame(width: 340)
            }
            .popover(isPresented: $showWidgetHelp) {
                HostWidgetHelpView()
                    .frame(width: 320)
            }
            .alert(
                environment.fileTransferStore.pendingPrompt.map { "Save \($0.fileName)?" } ?? "Incoming File",
                isPresented: Binding(
                    get: { environment.fileTransferStore.pendingPrompt != nil },
                    set: { isPresented in
                        if !isPresented, environment.fileTransferStore.pendingPrompt != nil {
                            environment.resolveFileTransferPrompt(approved: false)
                        }
                    }
                ),
                presenting: environment.fileTransferStore.pendingPrompt
            ) { _ in
                Button("Reject", role: .destructive) {
                    environment.resolveFileTransferPrompt(approved: false)
                }
                Button("Save") {
                    environment.resolveFileTransferPrompt(approved: true)
                }
            } message: { prompt in
                Text("The connected client Mac wants to send a file to this Mac. It will be saved in \(prompt.destinationDescription).")
            }
    }
}

private enum PermissionsPivotTab: String, CaseIterable, Identifiable {
    case readiness
    case required
    case optional

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private enum StreamingPivotTab: String, CaseIterable, Identifiable {
    case capture
    case transport
    case diagnostics

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private enum DiagnosticsPivotTab: String, CaseIterable, Identifiable {
    case health
    case pipeline
    case events

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

// MARK: - Minimal Dashboard

private struct HostMinimalDashboard: View {
    @ObservedObject private var environment: HostAppEnvironment
    @Binding var isCompact: Bool
    @ObservedObject private var discoveryViewModel: DiscoveryAdvertiserViewModel
    @ObservedObject private var permissionsViewModel: HostPermissionsViewModel
    @ObservedObject private var sessionCoordinator: HostSessionCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var tailscaleInfo: TailscaleConnectionInfo?
    @State private var tailscaleInstalled = false
    @State private var copiedAddress: String?
    @State private var showPermissions = false
    @State private var showLightNotification = false
    @State private var lightNotificationText = ""
    @State private var showPermissionExplainer = false
    @State private var compactGlow = false
    @State private var compactAppear = false
    @State private var showCompactSettings = false

    init(environment: HostAppEnvironment, isCompact: Binding<Bool>) {
        self._environment = ObservedObject(wrappedValue: environment)
        self._isCompact = isCompact
        self.permissionsViewModel = environment.permissionsViewModel
        self.discoveryViewModel = environment.discoveryAdvertiserViewModel
        self.sessionCoordinator = environment.sessionCoordinator
    }

    var body: some View {
        Group {
            if isCompact {
                compactDashboard
            } else {
                fullDashboard
            }
        }
        .background {
            if !isCompact { AppBackground() }
        }
        .task {
            // Show the in-app explainer before any system permission dialog
            // fires.  Once dismissed, refresh() is free to call CGRequest...
            if permissionsViewModel.shouldShowExplainer {
                showPermissionExplainer = true
            } else {
                await permissionsViewModel.refresh()
            }
            environment.refreshStartAtLoginState()
            let snapshot = await Task.detached(priority: .utility) {
                getTailscaleDetectionSnapshot()
            }.value
            tailscaleInfo = snapshot.info
            tailscaleInstalled = snapshot.installed
            await discoveryViewModel.updateTailscaleIdentity(
                hostname: snapshot.info?.dnsName,
                ip: snapshot.info?.ipAddress
            )
        }
        .sheet(isPresented: $showPermissionExplainer) {
            HostPermissionExplainerSheet(
                supportsRemoteInput: environment.runtimePolicy.supportsRemoteInput,
                onContinue: {
                    permissionsViewModel.markExplainerShown()
                    showPermissionExplainer = false
                    Task { await permissionsViewModel.requestPrompt(for: .screenRecording) }
                }
            )
            .frame(width: 460)
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task.detached(priority: .utility) {
                let snapshot = getTailscaleDetectionSnapshot()
                await MainActor.run {
                    tailscaleInfo = snapshot.info
                    tailscaleInstalled = snapshot.installed
                    Task {
                        await discoveryViewModel.updateTailscaleIdentity(
                            hostname: snapshot.info?.dnsName,
                            ip: snapshot.info?.ipAddress
                        )
                    }
                }
            }
        }
        .onChange(of: sessionCoordinator.phase) { _ in
            showTransientNotification(phaseNotificationText)
        }
    }

    private var fullDashboard: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    // Trust-prompt banner — top of stack so the host operator sees the
                    // pairing request. Auto-dismisses on resolve/timeout.
                    if let prompt = environment.pendingTrustPrompt {
                        TrustPromptBanner(
                            prompt: prompt,
                            deadline: environment.pendingTrustPromptDeadline,
                            onApprove: { environment.resolveTrustPrompt(approved: true) },
                            onReject:  { environment.resolveTrustPrompt(approved: false) }
                        )
                    }

                    dashboardHeader
                    statusHeroCard

                    HostTailscaleStatusView(
                        info: $tailscaleInfo,
                        installed: $tailscaleInstalled,
                        compact: false
                    )

                    // Pairing is a first-class homepage action for both host products.
                    // Advanced Safari settings remain available from Settings, but the
                    // operator no longer has to search for the QR code or code.
                    HostHomepagePairingCard(
                        sectionTitle: "Pair a browser",
                        title: "Open Safari control",
                        subtitle: "Scan the QR code, then enter the 12-digit code shown on this Mac.",
                        environment: environment,
                        tailscaleInfo: tailscaleInfo,
                        copiedValue: copiedAddress,
                        browserPairingURL: browserPairingURL,
                        onCopy: copyHomepageValue,
                        onRotate: { environment.rotateBrowserPairingCode() }
                    )

                    // One concise address list is enough for Vamp Remote. Safari's
                    // address is shown in the pairing card above, avoiding duplicate
                    // LAN/Tailscale/Safari cards on the homepage.
                    if !connectAddresses.isEmpty {
                        connectSection
                    }

                    // Live metrics — only relevant once a session is up.
                    if sessionCoordinator.phase != .idle {
                        metricsRow
                    }

                    // Inline permission banner — only when blockers exist.
                    if !permissionsViewModel.blockers.isEmpty {
                        permissionBanner
                            .popover(isPresented: $showPermissions) {
                                HostPermissionsView(environment: environment)
                                    .frame(width: 460, height: 540)
                            }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .top)
            }

            if showLightNotification {
                HostLightNotification(text: lightNotificationText)
                    .padding(.top, 14)
                    .padding(.trailing, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
                    .allowsHitTesting(false)
            }
        }
        // Keep a stable, screen-safe dashboard frame. The content scrolls instead
        // of forcing a window taller than a laptop display when permissions,
        // pairing, or diagnostics become visible.
        .frame(minWidth: 500, idealWidth: 720, maxWidth: 720,
               minHeight: 520, idealHeight: 900, maxHeight: 900)
        .animation(.easeInOut(duration: 0.2), value: sessionCoordinator.phase)
        .animation(.easeInOut(duration: 0.2), value: permissionsViewModel.blockers.count)
    }

    private var dashboardHeader: some View {
        HStack(spacing: 10) {
            HostAppLogo(size: 34, cornerRadius: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text("Vamp Host")
                    .font(.headline.weight(.semibold))
                Text("Remote control · terminal · Safari")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(appVersionLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: Dashboard sections

    /// Compact status "hero": dot + primary status + secondary line + inline action.
    private var statusHeroCard: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.16))
                    .frame(width: 34, height: 34)
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: statusColor.opacity(0.55), radius: 5)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(heroPrimaryText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(heroSecondaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 7) {
                if sessionCoordinator.phase == .idle {
                    Button {
                        Task { await environment.startRuntimeIfNeeded() }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                } else {
                    Button(role: .destructive) {
                        Task { await environment.stopRuntime() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Color.red.opacity(0.11),
                                in: RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                    .strokeBorder(Color.red.opacity(0.16), lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .tint(.red)
                    .controlSize(.regular)
                }

                Button {
                    Task {
                        await environment.stopRuntime()
                        await environment.startRuntimeIfNeeded()
                    }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Restart the host runtime")
            }
        }
        .padding(16)
        .hostGlassSurface(
            in: RoundedRectangle(cornerRadius: AppRadius.extraLarge, style: .continuous),
            tint: statusColor,
            isFloating: true
        )
    }

    private var heroPrimaryText: String {
        // An active authenticated session is the primary state. Permission
        // reminders remain available in setup, but must not make a live host
        // look broken or disconnected.
        if sessionCoordinator.phase != .streaming,
           !permissionsViewModel.blockers.isEmpty { return "Setup required" }
        switch sessionCoordinator.phase {
        case .streaming:
            return sessionCoordinator.connectedClientName.map { "Streaming to \($0)" } ?? "Streaming"
        case .advertising, .awaitingClient:                          return "Ready for connections"
        case .signalingConnected, .trustPending,
             .negotiating, .pipelineStarting:                        return "Connecting…"
        case .error:                                                  return "Connection error"
        case .idle:                                                   return "Stopped"
        }
    }

    private var heroSecondaryText: String {
        if let err = sessionCoordinator.errorMessage, !err.isEmpty { return err }
        return "\(hostDisplayName) · \(statusSubtitle)"
    }

    private var hostDisplayName: String {
        #if os(macOS)
        Host.current().localizedName ?? "This Mac"
        #else
        "This Mac"
        #endif
    }

    /// Compact "Connect from" section: label pill + monospaced address + copy button.
    private var connectSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect from", systemImage: "network")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(connectAddresses, id: \.value) { entry in
                connectAddressRow(entry)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hostGlassSurface(
            in: RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
        )
    }

    /// Compact metrics row: thermal · fps · bitrate as small inline stat tiles.
    private var metricsRow: some View {
        HStack(spacing: 8) {
            metricTile(
                title: "Thermal",
                value: environment.performanceStateController.thermalState.title,
                color: thermalColor
            )
            metricTile(
                title: "FPS",
                value: "\(environment.performanceStateController.profile.targetFrameRate)",
                color: .accentColor
            )
            metricTile(
                title: "Bitrate",
                value: formattedBitrate(kbps: environment.performanceStateController.profile.maxBitrateKbps),
                color: .secondary
            )
        }
    }

    /// Human-friendly bitrate: Mbps for kbps values ≥ 1000, kbps otherwise.
    private func formattedBitrate(kbps: Int) -> String {
        guard kbps >= 1000 else { return "\(kbps) kbps" }
        let mbps = Double(kbps) / 1000
        return mbps == mbps.rounded()
            ? "\(Int(mbps)) Mbps"
            : String(format: "%.1f Mbps", mbps)
    }

    private func metricTile(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hostGlassSurface(
            in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
        )
    }

    /// Compact inline permission banner: warning + "Fix" that opens the popover.
    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("\(permissionsViewModel.blockers.count) permission\(permissionsViewModel.blockers.count == 1 ? "" : "s") required")
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
            Button("Fix") { showPermissions = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .hostGlassSurface(
            in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous),
            tint: .orange
        )
    }

    // MARK: - Compact (mini) mode

    private var compactDashboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── header ───────────────────────────────────────────
            HStack(spacing: 7) {
                HostPulseDot(color: statusColor)
                Text("vamp host")
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppColor.textPrimary)
                    .tracking(0.4)
                Text(appVersionLabel)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppColor.textSecondary.opacity(0.7))
                    .padding(.leading, 1)
                Spacer(minLength: 6)
                Text(headerStateLabel)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppColor.textSecondary)
                    .tracking(0.7)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.06), in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
                    .contentTransition(.opacity)
                compactGlyphButton(systemName: "gearshape", help: "Settings") {
                    showCompactSettings.toggle()
                }
                .popover(isPresented: $showCompactSettings, arrowEdge: .top) {
                    HostSettingsView(environment: environment, showOnboarding: {})
                        .frame(width: 340)
                }
                compactExpandButton
                compactGlyphButton(systemName: "xmark", help: "Hide window") {
                    #if os(macOS)
                    HostWindowCloseBehaviorController.shared.hideWindow()
                    #endif
                }
            }

            // ── status + live equalizer ─────────────────────────
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor.opacity(0.9))
                    .frame(width: 6, height: 6)
                Text(statusTitle.lowercased())
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.interpolate)
                Spacer(minLength: 4)
                LiveActivityBars(color: .white.opacity(0.5), active: sessionCoordinator.phase == .streaming)
            }

            // ── primary connect address ─────────────────────────
            if let entry = connectAddresses.first {
                connectAddressRow(entry, valueColor: AppColor.textPrimary, accent: AppColor.textSecondary)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // ── controls ────────────────────────────────────────
            HStack(spacing: 7) {
                if sessionCoordinator.phase == .idle {
                    controlChip(label: "start", icon: "play.fill", role: .ghost) {
                        Task { await environment.startRuntimeIfNeeded() }
                    }
                } else {
                    controlChip(label: "stop", icon: "stop.fill", role: .danger) {
                        Task { await environment.stopRuntime() }
                    }
                }
                controlChip(label: "restart", icon: "arrow.clockwise", role: .ghost) {
                    Task {
                        await environment.stopRuntime()
                        await environment.startRuntimeIfNeeded()
                    }
                }
                Spacer(minLength: 0)
            }

            // ── permission nudge (compact) ──────────────────────
            if !permissionsViewModel.blockers.isEmpty {
                Button { showPermissions = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(AppColor.textSecondary)
                        Text("\(permissionsViewModel.blockers.count) permission\(permissionsViewModel.blockers.count == 1 ? "" : "s") required")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppColor.textPrimary)
                        Spacer()
                        Text("fix →")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .popover(isPresented: $showPermissions) {
                    HostPermissionsView(environment: environment)
                        .frame(width: 460, height: 540)
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: sessionCoordinator.phase)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: permissionsViewModel.blockers.count)
        .animation(.easeInOut(duration: 0.25), value: connectAddresses.first?.value)
        .padding(16)
        .frame(width: 300, alignment: .topLeading)
        // Measure the content (before it's stretched) so the window can be sized
        // to fit it exactly.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CompactSizeKey.self, value: proxy.size)
            }
        )
        // Stretch to fill the whole window, then paint the glass over that full
        // area so there is never a transparent strip if the size is slightly off.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(compactCardBackground)
        .overlay { compactBorder }
        .ignoresSafeArea(.container, edges: .all)
        .scaleEffect(compactAppear ? 1 : 0.96)
        .opacity(compactAppear ? 1 : 0)
        .onAppear {
            compactAppear = false
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) { compactAppear = true }
            compactGlow = false
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { compactGlow = true }
        }
    }

    // Frosted-glass mini widget: a transparent window lets the material blur the
    // desktop, while slow-drifting light blobs under the glass keep it alive.
    private var compactCardBackground: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                compactAmbientGlow(t)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                // Cool dark tint (a hint of blue) keeps text legible without
                // killing the light underneath.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.05, green: 0.07, blue: 0.14).opacity(0.16))
                // Glowing blue light blooms ON TOP of the frost so it actually
                // reads as light, then a cool top sheen.
                compactLightBloom(t)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.66, green: 0.82, blue: 1.0).opacity(0.14), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                compactSheen(t)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // Soft cool light sources drifting behind the glass — frosted by the material
    // into a gentle, always-moving glow.
    private func compactAmbientGlow(_ t: TimeInterval) -> some View {
        let x1 = CGFloat(sin(t * 0.45)) * 46
        let y1 = CGFloat(cos(t * 0.38)) * 26
        let x2 = CGFloat(cos(t * 0.31)) * 50
        let y2 = CGFloat(sin(t * 0.41)) * 30
        return ZStack {
            Circle().fill(Color(red: 0.40, green: 0.66, blue: 1.0).opacity(0.45))
                .frame(width: 200, height: 200).blur(radius: 46)
                .offset(x: x1 - 46, y: y1 - 28)
            Circle().fill(Color(red: 0.58, green: 0.80, blue: 1.0).opacity(0.34))
                .frame(width: 165, height: 165).blur(radius: 46)
                .offset(x: x2 + 52, y: y2 + 30)
            Circle().fill(Color.white.opacity(0.16))
                .frame(width: 130, height: 130).blur(radius: 42)
                .offset(x: x1 * 0.5 + 6, y: -y2 * 0.6 + 30)
        }
    }

    // Blue light blooms layered above the frost so it reads as glowing light,
    // travelling continuously for a living feel.
    private func compactLightBloom(_ t: TimeInterval) -> some View {
        let bx = CGFloat(sin(t * 0.5)) * 70
        let by = CGFloat(sin(t * 0.33 + 1.0)) * 18
        let pulse = 0.5 + 0.5 * CGFloat(sin(t * 0.9))
        return ZStack {
            Circle().fill(Color(red: 0.45, green: 0.70, blue: 1.0).opacity(0.16 + 0.10 * pulse))
                .frame(width: 150, height: 150).blur(radius: 38)
                .offset(x: bx - 30, y: by - 36)
                .blendMode(.plusLighter)
            Circle().fill(Color(red: 0.60, green: 0.85, blue: 1.0).opacity(0.10))
                .frame(width: 90, height: 90).blur(radius: 26)
                .offset(x: -bx * 0.7 + 40, y: 30)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    // A specular highlight that sweeps slowly across the glass.
    private func compactSheen(_ t: TimeInterval) -> some View {
        let p = CGFloat((sin(t * 0.5) + 1) / 2)
        return LinearGradient(
            colors: [.clear, .white.opacity(0.12), .clear],
            startPoint: UnitPoint(x: p - 0.35, y: -0.2),
            endPoint: UnitPoint(x: p + 0.35, y: 1.2)
        )
        .blendMode(.plusLighter)
    }

    private var compactBorder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(compactGlow ? 0.30 : 0.16), .white.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    private var compactExpandButton: some View {
        compactGlyphButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Expand to full dashboard") {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                isCompact = false
            }
        }
    }

    private func compactGlyphButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(AppColor.textTertiary)
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(HostPressableButtonStyle())
        .help(help)
    }

    // MARK: Control chip (used by the dead compact widget surface)

    private enum ControlChipRole { case primary, ghost, danger }

    private func controlChip(label: String, icon: String, role: ControlChipRole, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(chipBackground(role), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(chipBorder(role), lineWidth: 0.5)
            }
            .foregroundStyle(chipForeground(role))
        }
        .buttonStyle(.plain)
    }

    private func chipBackground(_ role: ControlChipRole) -> Color {
        switch role {
        case .primary: AppColor.mint.opacity(0.18)
        case .ghost:   Color.white.opacity(0.05)
        case .danger:  AppColor.error.opacity(0.12)
        }
    }

    private func chipBorder(_ role: ControlChipRole) -> Color {
        switch role {
        case .primary: AppColor.mint.opacity(0.38)
        case .ghost:   Color.white.opacity(0.10)
        case .danger:  AppColor.error.opacity(0.30)
        }
    }

    private func chipForeground(_ role: ControlChipRole) -> Color {
        switch role {
        case .primary: AppColor.mint
        case .ghost:   AppColor.textPrimary
        case .danger:  AppColor.error
        }
    }

    // MARK: Thermal color

    private var thermalColor: Color {
        switch environment.performanceStateController.thermalState {
        case .nominal:  return .green
        case .fair:     return .green
        case .serious:  return .orange
        case .critical: return .red
        }
    }

    // MARK: State helpers

    /// Reads the app's marketing version + build straight from the bundle, so it
    /// updates automatically with every release (e.g. "v3.6.0 (3)").
    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    private var headerStateLabel: LocalizedStringKey {
        if sessionCoordinator.phase != .streaming,
           !permissionsViewModel.blockers.isEmpty { return "SETUP" }
        switch sessionCoordinator.phase {
        case .streaming:                                                          return "LIVE"
        case .advertising, .awaitingClient:                                       return "READY"
        case .signalingConnected, .trustPending, .negotiating, .pipelineStarting: return "CONNECTING"
        case .error:                                                              return "ERROR"
        case .idle:                                                               return "IDLE"
        }
    }

    private var statusColor: Color {
        if sessionCoordinator.phase != .streaming,
           !permissionsViewModel.blockers.isEmpty { return AppColor.warning }
        switch sessionCoordinator.phase {
        case .streaming:                    return AppColor.primaryAccent
        case .advertising, .awaitingClient: return AppColor.success
        case .error:                        return AppColor.error
        default:                            return AppColor.disconnected
        }
    }

    private var statusTitle: String {
        if sessionCoordinator.phase != .streaming,
           !permissionsViewModel.blockers.isEmpty { return "Setup Required" }
        switch sessionCoordinator.phase {
        case .streaming:
            return sessionCoordinator.connectedClientName.map { "Connected to \($0)" } ?? "Streaming"
        case .advertising, .awaitingClient:                          return "Ready"
        case .signalingConnected, .trustPending,
             .negotiating, .pipelineStarting:                        return "Connecting"
        case .error:                                                  return "Error"
        case .idle:                                                   return "Stopped"
        }
    }

    private var statusSubtitle: String {
        if let err = sessionCoordinator.errorMessage, !err.isEmpty { return err }
        switch sessionCoordinator.phase {
        case .streaming:                    return "session active"
        case .advertising, .awaitingClient: return discoveryViewModel.statusText
        case .signalingConnected, .trustPending,
             .negotiating, .pipelineStarting: return "establishing secure session"
        case .error:                        return "check settings · restart to retry"
        case .idle:                         return "runtime not started"
        }
    }

    private struct ConnectAddressEntry: Hashable {
        let label: String
        let value: String
    }

    private var connectAddresses: [ConnectAddressEntry] {
        var entries: [ConnectAddressEntry] = []
        if let lan = getLocalIPAddress() {
            entries.append(.init(label: "lan", value: "\(lan):\(RemoteDesktopConstants.defaultSignalingPort)"))
        }
        if let ts = tailscaleInfo {
            // MagicDNS name first when present — it's stable across IP rotation.
            if let dns = ts.dnsName, !dns.isEmpty {
                entries.append(.init(label: "tailscale", value: "\(dns):\(RemoteDesktopConstants.defaultSignalingPort)"))
            }
            entries.append(.init(label: ts.dnsName == nil ? "tailscale" : "ts ip", value: "\(ts.ipAddress):\(RemoteDesktopConstants.defaultSignalingPort)"))
        }
        // Drop duplicates (e.g. if LAN IP somehow matches TS IP, unlikely but safe).
        var seen = Set<String>()
        return entries.filter { seen.insert($0.value).inserted }
    }

    private var browserPairingURL: String? {
        guard environment.browserControlStatus.running,
              let port = environment.browserControlStatus.port,
              !environment.browserControlStatus.pairingCode.isEmpty else { return nil }

        let baseURL = tailscaleInfo?.browserControlURL(port: port) ?? "http://127.0.0.1:\(port)"
        return HostBrowserPairingLink.make(baseURL: baseURL)
    }

    private func copyHomepageValue(_ value: String) {
        copyToPasteboard(value)
        copiedAddress = value
        showTransientNotification("Copied to clipboard")
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedAddress == value { copiedAddress = nil }
        }
    }

    private func connectAddressRow(_ entry: ConnectAddressEntry, valueColor: Color = AppColor.textPrimary, accent: Color = AppColor.primaryAccent) -> some View {
        let isCopied = copiedAddress == entry.value
        return Button {
            copyToPasteboard(entry.value)
            copiedAddress = entry.value
            showTransientNotification("\(entry.label) address copied")
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if copiedAddress == entry.value { copiedAddress = nil }
            }
        } label: {
            HStack(spacing: 8) {
                Text(entry.label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay { Capsule().strokeBorder(AppColor.borderSubtle, lineWidth: 0.5) }
                Text(entry.value)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.callout)
                    .foregroundStyle(isCopied ? Color.green : Color.secondary)
                    .animation(.easeInOut(duration: 0.15), value: isCopied)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .strokeBorder(AppColor.borderSubtle, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy \(entry.value)")
    }

    private var phaseNotificationText: String {
        switch sessionCoordinator.phase {
        case .streaming:
            return "Live session started"
        case .advertising, .awaitingClient:
            return "Host is ready for connection"
        case .signalingConnected, .trustPending, .negotiating, .pipelineStarting:
            return "Negotiating secure session"
        case .error:
            return "Connection issue detected"
        case .idle:
            return "Host session stopped"
        }
    }

    private func showTransientNotification(_ text: String) {
        lightNotificationText = text
        withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
            showLightNotification = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2.1))
            withAnimation(.easeOut(duration: 0.24)) {
                showLightNotification = false
            }
        }
    }
}


/// A thin, static accent hairline around the window while a session is active.
/// No animated glow — flat and native.
private struct HostConnectionFrame: View {
    let phase: HostSessionCoordinator.SessionPhase
    let hasPermissionBlockers: Bool

    private var accent: Color {
        if hasPermissionBlockers { return .orange }
        switch phase {
        case .error:
            return .red
        case .streaming, .advertising, .awaitingClient:
            return .green
        case .signalingConnected, .trustPending, .negotiating, .pipelineStarting:
            return .orange
        case .idle:
            return .clear
        }
    }

    private var isActive: Bool {
        phase != .idle
    }

    var body: some View {
        RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
            .strokeBorder(isActive ? accent.opacity(0.38) : .clear, lineWidth: 1)
            .shadow(color: isActive ? accent.opacity(0.12) : .clear, radius: 10)
            .animation(.easeInOut(duration: 0.25), value: phase)
    }
}

private struct HostPulseDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }
}

/// Carries the intrinsic size of the compact dashboard up to `HostShellView`
/// so the real window can be resized to fit it exactly.
private struct CompactSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// A tiny five-bar audio-style equalizer that gently animates while a session
/// is live and rests flat when idle — the heartbeat of the mini widget.
private struct LiveActivityBars: View {
    let color: Color
    let active: Bool
    private let count = 5

    var body: some View {
        // Always animating — gently at idle, lively while streaming — so the
        // widget never looks frozen.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(color.opacity(active ? 0.9 : 0.5))
                        .frame(width: 2.5, height: barHeight(index: i, time: t))
                }
            }
            .frame(height: 14)
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let speed = active ? 6.2 : 2.0
        let amp: CGFloat = active ? 10.5 : 3.2
        let wave = (sin(time * speed + Double(index) * 0.95) + 1) / 2  // 0...1
        return 3.0 + CGFloat(wave) * amp
    }
}

/// Press-to-shrink interaction used on the mini-mode glyph buttons so the
/// small controls still feel tactile.
private struct HostPressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct HostLightNotification: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .hostGlassSurface(in: Capsule(style: .continuous))
    }
}

/// Guidance for the common post-rebuild state where Screen Recording /
/// Accessibility still read as not approved. A rebuilt host carries a fresh
/// ad-hoc code signature, so macOS keeps the grants attached to the previous
/// app entry and the new binary looks like a different app — removing and
/// re-adding Vamp Host re-anchors the grants.
private struct HostPermissionReGrantNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Permissions not sticking after an update? A rebuilt app has a new signature, so macOS may still list the old Vamp Host entry.")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(AppColor.primaryAccent)
            }
            stepRow(1, "In each pane (Screen Recording, Accessibility), select the old Vamp Host entry and press the − button.")
            stepRow(2, "Press + and add Vamp Host from Applications.")
            stepRow(3, "Quit and reopen Vamp Host.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hostGlassSurface(
            in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous),
            isInteractive: false
        )
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppColor.primaryAccent)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HostSettingsView: View {
    @ObservedObject var environment: HostAppEnvironment
    let showOnboarding: () -> Void
    @State private var pendingMaxFileSize = ""
    @AppStorage("host.remoteUnlock.enabled") private var remoteUnlockEnabled = false
    @AppStorage("host.vampTerminal.promo.dismissed") private var vampTerminalPromoDismissed = false
    @State private var showPairedDevices = false
    @State private var showDiagnostics = false
    @State private var browserCommandCopied = false
    @State private var browserLinkCopied = false
    @State private var tailscaleInfo: TailscaleConnectionInfo?

    var body: some View {
        Form {
            Section("Remote Access") {
                Picker("Mode", selection: Binding(
                    get: { environment.sessionModeController.mode },
                    set: { environment.setSessionMode($0) }
                )) {
                    ForEach(SessionControlMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!environment.runtimePolicy.supportsRemoteInput)

                Toggle("Start at Login", isOn: Binding(
                    get: { environment.startAtLoginEnabled },
                    set: { environment.setStartAtLogin($0) }
                ))

                if let loginMessage = environment.startAtLoginErrorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Text(loginMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        #if os(macOS)
                        Button("Open Login Items") {
                            environment.openStartAtLoginSettings()
                        }
                        .controlSize(.small)
                        #endif
                    }
                }

                Toggle("Low Power Mode", isOn: Binding(
                    get: { environment.manualLowPowerModeEnabled },
                    set: { environment.setManualLowPowerModeEnabled($0) }
                ))

                Toggle(isOn: Binding(
                    get: { environment.keepAwakeEnabled },
                    set: { environment.setKeepAwakeEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep Mac Awake & Reachable")
                        Text("Stops this Mac from sleeping so it stays connectable. Recommended for Apple-Silicon Macs on Wi-Fi, which can't be woken remotely. The display can still sleep; best when plugged in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Security") {
                Button {
                    showPairedDevices = true
                } label: {
                    HStack {
                        Label("Paired Devices", systemImage: "checkmark.shield")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Section("Diagnostics") {
                Button {
                    showDiagnostics = true
                } label: {
                    HStack {
                        Label("Connection Log", systemImage: "ladybug")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Section("AI Agents") {
                HostAgentCommandsView(style: .settings)
            }

            Section("File Transfer") {
                Toggle("Enabled", isOn: $environment.fileTransferSettings.isEnabled)
                Toggle("Confirm Every File", isOn: $environment.fileTransferSettings.requireConfirmation)

                HStack {
                    Text("Max Size")
                    Spacer()
                    TextField("", text: Binding(
                        get: { pendingMaxFileSize.isEmpty ? "\(environment.fileTransferSettings.maxFileSizeMB)" : pendingMaxFileSize },
                        set: { pendingMaxFileSize = $0 }
                    ))
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    Text("MB").foregroundStyle(.secondary)
                    Button("Apply") {
                        let clamped = min(max(Int(pendingMaxFileSize) ?? environment.fileTransferSettings.maxFileSizeMB, 1), 1024)
                        environment.fileTransferSettings.maxFileSizeMB = clamped
                        pendingMaxFileSize = "\(clamped)"
                    }
                    .controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Save Location")
                    Text(environment.fileTransferSettings.effectiveSaveLocationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    #if os(macOS)
                    Button("Choose Folder…") {
                        Task { await environment.fileTransferSettings.chooseSaveLocation() }
                    }
                    .controlSize(.small)
                    #endif
                }
            }

            Section("Terminal Mode") {
                if !vampTerminalPromoDismissed {
                    VampTerminalHostPromoCard {
                        vampTerminalPromoDismissed = true
                    }
                }
                Toggle("Enabled", isOn: Binding(
                    get: { environment.terminalModeEnabled },
                    set: { environment.setTerminalModeEnabled($0) }
                ))
                Text("When on, a paired Vamp Terminal client can open up to 8 independent interactive shell tabs on this Mac and run commands you could run in Terminal.app. Turn off if you don't need it — disabling Terminal Mode kills every active tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if os(macOS)
            Section("Safari control") {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Task-chat terminal in Safari", systemImage: "safari")
                        .font(.headline)
                    Text("The host keeps the browser workspace private to this Mac and Tailscale. Use the direct 100.x address on your phone; HTTPS Serve is optional.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if environment.browserControlStatus.running,
                   let port = environment.browserControlStatus.port {
                    LabeledContent("Mac local service", value: "127.0.0.1:\(port)")
                    if let tailscaleInfo {
                        let directURL = tailscaleInfo.browserControlURL(port: port)
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Direct Tailscale · use this on iPhone")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(directURL)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(browserLinkCopied ? "Copied" : "Copy link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(directURL, forType: .string)
                                browserLinkCopied = true
                            }
                            .controlSize(.small)
                        }

                        if let browserURL = tailscaleInfo.browserServeURL {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Optional HTTPS Serve")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(browserURL)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button(browserLinkCopied ? "Copied" : "Copy link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(browserURL, forType: .string)
                                    browserLinkCopied = true
                                }
                                .controlSize(.small)
                            }
                        }
                    } else {
                        Text("On a phone or tablet, 127.0.0.1 points back to that device. Use the direct 100.x URL shown above, or enable Tailscale Serve for HTTPS.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Label("QR code and pairing code are on the host homepage.", systemImage: "qrcode")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let serveCommand = environment.browserControlStatus.serveCommand {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(serveCommand, forType: .string)
                            browserCommandCopied = true
                        } label: {
                            Label(browserCommandCopied ? "Serve command copied" : "Copy Tailscale Serve command", systemImage: browserCommandCopied ? "checkmark" : "doc.on.doc")
                        }
                        .controlSize(.small)
                        .accessibilityHint("Paste the command into Terminal on this Mac, then open the resulting tailnet HTTPS URL in Safari.")
                        Text(serveCommand)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                } else if let error = environment.browserControlStatus.lastError {
                    Text("Browser service unavailable: \(error)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Start the host runtime to generate a private browser endpoint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            #endif

            Section("Remote Unlock") {
                Toggle("Enabled", isOn: $remoteUnlockEnabled)
                Text("Off by default. When on, a paired client can type your Mac login password at the login window (rate-limited, never logged).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Runtime") {
                LabeledContent("Thermal", value: environment.performanceStateController.thermalState.title)
                LabeledContent("FPS Cap", value: "\(environment.performanceStateController.profile.targetFrameRate) fps")
                LabeledContent("Bitrate", value: {
                    let kbps = environment.performanceStateController.profile.maxBitrateKbps
                    return kbps >= 1000 ? "\(kbps / 1000) Mbps" : "\(kbps) kbps"
                }())
            }

            Section {
                Button {
                    showOnboarding()
                } label: {
                    Label("Open Setup Guide", systemImage: "questionmark.circle")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPairedDevices) {
            NavigationStack {
                HostPairedDevicesView(environment: environment)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showPairedDevices = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack {
                HostDiagnosticsView(environment: environment)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showDiagnostics = false }
                        }
                    }
            }
        }
        .task {
            environment.refreshStartAtLoginState()
            environment.thermalMonitor.refresh()
            environment.lowPowerModeService.refresh()
            pendingMaxFileSize = "\(environment.fileTransferSettings.maxFileSizeMB)"
            tailscaleInfo = await Task.detached(priority: .utility) {
                getTailscaleConnectionInfo()
            }.value
        }
    }

}

/// Quiet, dismissible promotion for the companion open-source iPhone/iPad
/// terminal. It lives next to Terminal Mode so the host operator sees the
/// feature at the moment it becomes useful, without turning settings into an
/// advertisement-heavy surface.
private struct VampTerminalHostPromoCard: View {
    @Environment(\.openURL) private var openURL
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.title3.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Vamp Terminal for iPhone & iPad")
                        .font(.callout.weight(.semibold))
                    Text("Use up to 8 terminal tabs over Tailscale, or control the same task workspace from Safari.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss Vamp Terminal promotion")
            }

            Button {
                openURL(HostAppLinks.vampTerminalURL)
            } label: {
                Label("View open-source project", systemImage: "arrow.up.right.square")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(11)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.secondary.opacity(0.2), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct HostOnboardingView: View {
    let environment: HostAppEnvironment
    let dismiss: () -> Void
    @AppStorage("host.onboarding.agreement.accepted") private var agreementAccepted = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Setup Guide")
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Configure your host and approve trusted devices.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 4)

                    // Quick status tiles
                    HStack(spacing: 12) {
                        statusTile(
                            icon: environment.permissionsViewModel.blockers.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                            iconColor: environment.permissionsViewModel.blockers.isEmpty ? .green : .orange,
                            label: "Permissions",
                            value: environment.permissionsViewModel.blockers.isEmpty ? "All set" : "\(environment.permissionsViewModel.blockers.count) action needed"
                        )
                        statusTile(
                            icon: environment.runtimePolicy.supportsRemoteInput ? "cursorarrow" : "eye",
                            iconColor: environment.runtimePolicy.supportsRemoteInput ? .accentColor : .secondary,
                            label: "Control",
                            value: environment.runtimePolicy.supportsRemoteInput ? "Full Control" : "Video Only"
                        )
                    }
                    .padding(.horizontal, 20)

                    // Permissions checklist
                    simplifiedCard("Permissions", icon: "checkmark.shield", accentColor: .green) {
                        VStack(alignment: .leading, spacing: 10) {
                            if environment.permissionsViewModel.blockers.isEmpty {
                                Label("All required permissions are approved.", systemImage: "checkmark.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.green)
                            } else {
                                Text("Required permissions")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                ForEach(environment.permissionsViewModel.statuses.filter(\.isRequired)) { status in
                                    Label {
                                        Text(status.title).font(.callout)
                                    } icon: {
                                        Image(systemName: status.isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                            .foregroundStyle(status.isGranted ? Color.green : Color.orange)
                                    }
                                }

                                HStack(spacing: 8) {
                                    Button {
                                        Task {
                                            await environment.permissionsViewModel.openSettings(for: .screenRecording)
                                            if environment.runtimePolicy.canRequestAccessibilityPermission {
                                                await environment.permissionsViewModel.openSettings(for: .accessibility)
                                            }
                                        }
                                    } label: {
                                        Label("Open Settings", systemImage: "gearshape")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)

                                    Button {
                                        Task { await environment.permissionsViewModel.refresh() }
                                    } label: {
                                        Label("Refresh", systemImage: "arrow.clockwise")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    Spacer()
                                }

                                HostPermissionReGrantNote()
                            }
                        }
                    }

                    // How it works
                    simplifiedCard("How it works", icon: "sparkles", accentColor: .accentColor) {
                        VStack(alignment: .leading, spacing: 12) {
                            guideStep(1, "Approve permissions", "Grant Screen Recording and Accessibility access in System Settings.")
                            guideStep(2, "Keep host running", "Keep the host open or in the menu bar so discovery stays available.")
                            guideStep(3, "Review new devices", "Approve each new device that connects to establish trust.")
                            guideStep(4, "Share address", "Copy the LAN or Tailscale address to give the client connection info.")
                        }
                    }

                    // AI agent control
                    simplifiedCard("AI agent control", icon: "terminal", accentColor: .accentColor) {
                        HostAgentCommandsView(style: .onboarding)
                    }

                    // Desktop widget — show a mock + numbered steps + how-to note.
                    simplifiedCard("Add the desktop widget", icon: "square.grid.2x2", accentColor: .accentColor) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Control the host from your desktop without opening this window. Here's what the medium widget looks like:")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HostWidgetMockPreview()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 2)

                            guideStep(1, "Open Notification Center", "Click the clock / date in the menu bar.")
                            guideStep(2, "Edit Widgets", "Scroll down and click “Edit Widgets”.")
                            guideStep(3, "Search for Vamp Host", "Find it in the widget gallery.")
                            guideStep(4, "Drag the medium size onto your desktop", "Use the medium size — it has the start, stop, and restart buttons.")

                            Label {
                                Text("How to use: the widget's buttons start, stop, and restart this host directly. Once it's added, the host runs from the menu bar — reopen this window anytime from the menu-bar icon → Open Dashboard.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
                            }
                        }
                    }

                    // Security
                    simplifiedCard("Security", icon: "lock.shield", accentColor: .green) {
                        VStack(alignment: .leading, spacing: 10) {
                            securityPoint("Approval is local", "New clients always require manual approval on this Mac before access is granted.")
                            securityPoint("Fingerprint verified", "Device fingerprints are cryptographically verified on every reconnection.")
                            securityPoint("Revoke anytime", "Remove any device from Paired Devices to immediately cut off access.")

                            if !environment.runtimePolicy.supportsRemoteInput {
                                Divider()
                                Label {
                                    Text("App Sandbox limits this build to View Only because keyboard and pointer injection are unavailable.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } icon: {
                                    Image(systemName: "info.circle").foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    // User agreement + disclaimer
                    simplifiedCard("Agreement", icon: "doc.text", accentColor: .accentColor) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("User Agreement")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            agreementPoint("Authorized use only", "Use this host only on Macs you own or are explicitly authorized to manage.")
                            agreementPoint("You control access", "You are responsible for approving trusted devices and revoking access when needed.")
                            agreementPoint("Sensitive environments", "Do not use this app where remote access is prohibited by law, policy, or contract.")

                            Divider()

                            Text("User Disclaimer")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            agreementPoint("No liability for misuse", "The publisher is not responsible for unauthorized use, data exposure, or service interruptions caused by network conditions, third-party tools, or user configuration.")
                            agreementPoint("Permission dependent", "Remote features depend on macOS permissions and may be limited by system updates or App Sandbox rules.")

                            Toggle(isOn: $agreementAccepted) {
                                Text("I have read and accept the User Agreement and Disclaimer")
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .toggleStyle(.switch)
                            .padding(.top, 2)
                        }
                    }

                    // Tailscale
                    simplifiedCard("Tailscale", icon: "globe", accentColor: .orange) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("For remote access:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            guideStep(1, "Install Tailscale", "Set up Tailscale on both Mac and Macs.")
                            guideStep(2, "Same account", "Sign in with the same Tailnet account on both devices.")
                            guideStep(3, "Share address", "Use Dashboard to copy the Tailscale Connect address.")
                            guideStep(4, "No direct exposure", "Avoid exposing the host to the internet directly.")
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Guide")
            .toolbar {
                Button("Done", action: dismiss)
                    .disabled(!agreementAccepted)
            }
        }
        .frame(minWidth: 540, minHeight: 520)
        .task {
            await environment.permissionsViewModel.refresh()
        }
    }

    // MARK: - Helper Views

    private func statusTile(icon: String, iconColor: Color, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(label).font(.caption).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: icon).foregroundStyle(iconColor)
            }
            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(AppColor.borderSubtle, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func simplifiedCard<Content: View>(
        _ label: String,
        icon: String,
        accentColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label(label, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 20)
    }

    private func guideStep(_ number: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func securityPoint(_ title: String, _ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func agreementPoint(_ title: String, _ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

/// A small native SwiftUI mock of the medium "Vamp Host" desktop widget so users
/// can recognize it in the widget gallery. Static — not interactive.
private struct HostWidgetMockPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("vamp host")
                    .font(.system(.caption, design: .default).weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("READY")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
            }

            Text("192.168.1.42:51820")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                widgetMockButton("Stop", systemImage: "stop.fill", tint: .red)
                widgetMockButton("Restart", systemImage: "arrow.clockwise", tint: .secondary)
            }
        }
        .padding(12)
        .frame(width: 240)
        .hostGlassSurface(in: RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous))
    }

    private func widgetMockButton(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint == .secondary ? Color.primary : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay { Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.5) }
    }
}

private func copyToPasteboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

/// In-app pointer to the desktop widget — the mini surface that replaced the old
/// in-app compact window. Surfaced from the toolbar so users can find and use it.
private struct HostWidgetHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Desktop Widget", systemImage: "square.grid.2x2")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Keep this host a click away — without leaving the window open.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Open Notification Center", "Click the date & time in the menu bar.")
                step(2, "Edit Widgets", "Scroll down and click “Edit Widgets”.")
                step(3, "Add “Vamp Host”", "Find it in the gallery and drag it out. Use the medium size for start / stop / restart buttons.")
            }

            Label {
                Text("Widget buttons control this host directly, even when the window is closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
            }
        }
        .padding(16)
    }

    private func step(_ number: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct HostPermissionsView: View {
    /// Single source of truth for the direct-build download page, force-unwrapped
    /// exactly once here (the literal is a known-valid URL) so the two call sites
    /// below don't each repeat an inline `URL(string:)!`.
    private static let directBuildURL = HostAppLinks.websiteURL

    let environment: HostAppEnvironment
    @ObservedObject private var viewModel: HostPermissionsViewModel

    init(environment: HostAppEnvironment) {
        self.environment = environment
        self.viewModel = environment.permissionsViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    Circle()
                        .fill(headerStatusColor)
                        .frame(width: 7, height: 7)
                    Text("Host access readiness")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    HostStatusChip(role: viewModel.blockers.isEmpty ? .ready : .awaiting,
                                   label: viewModel.blockers.isEmpty ? "Ready" : "Setup")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 14) {
                    // Status overview
                    GroupBox {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(headerStatusColor)
                                .frame(width: 8, height: 8)
                            Text(viewModel.blockers.isEmpty
                                 ? "All required permissions granted"
                                 : "\(viewModel.blockers.count) permission\(viewModel.blockers.count == 1 ? "" : "s") blocking runtime")
                                .font(.callout)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(4)
                    }

                    // Required permissions
                    let required = viewModel.statuses.filter(\.isRequired)
                    if !required.isEmpty {
                        GroupBox("Required") {
                            VStack(spacing: 0) {
                                ForEach(Array(required.enumerated()), id: \.element.id) { idx, status in
                                    permRow(status)
                                    if idx < required.count - 1 { Divider() }
                                }
                            }
                        }
                    }

                    // Optional permissions
                    let optional = viewModel.statuses.filter { !$0.isRequired }
                    if !optional.isEmpty {
                        GroupBox("Optional") {
                            VStack(spacing: 0) {
                                ForEach(Array(optional.enumerated()), id: \.element.id) { idx, status in
                                    permRow(status)
                                    if idx < optional.count - 1 { Divider() }
                                }
                            }
                        }
                    }

                    // Re-grant guidance when something is still blocking.
                    if !viewModel.blockers.isEmpty {
                        HostPermissionReGrantNote()
                    }

                    // Actions
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                if let first = viewModel.statuses.first(where: { !$0.isGranted }) {
                                    await viewModel.openSettings(for: first.kind)
                                }
                            }
                        } label: {
                            Label("Open Settings", systemImage: "gearshape")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            Task { await viewModel.refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }

                    if let error = viewModel.lastErrorMessage {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .task {
            await viewModel.refresh()
        }
    }

    @ViewBuilder
    private func permRow(_ status: FriendlyPermissionStatus) -> some View {
        let isSandboxedAccessibility = false

        Button {
            if isSandboxedAccessibility {
                NSWorkspace.shared.open(Self.directBuildURL)
            } else if !status.isGranted {
                Task { await viewModel.openSettings(for: status.kind) }
            }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(isSandboxedAccessibility ? Color.secondary : status.authorizationState.permissionColor)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    if isSandboxedAccessibility {
                        Text("Unavailable in this sandboxed build")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(status.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if status.isGranted && !isSandboxedAccessibility {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                } else if isSandboxedAccessibility {
                    Text("Download")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("Fix")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func outgoingStatusText(_ status: HostOutgoingFileTransferController.TransferState.Status) -> String {
        switch status {
        case .preparing:
            return "Preparing"
        case .waitingForClient:
            return "Waiting for client Mac"
        case .sending:
            return "Sending"
        case .completed(let detail):
            return detail
        case .canceled:
            return "Canceled"
        case .failed(let detail):
            return detail
        }
    }

    private var headerStatusColor: Color {
        viewModel.blockers.isEmpty ? .green : .orange
    }
}

private struct HostPairedDevicesView: View {
    let environment: HostAppEnvironment
    @StateObject private var viewModel: HostPairedDevicesViewModel
    @State private var peerToRevoke: TrustedPeer?
    @State private var showRevokeConfirmation = false
    @State private var showClearConfirmation = false

    init(environment: HostAppEnvironment) {
        self.environment = environment
        self._viewModel = StateObject(wrappedValue: HostPairedDevicesViewModel(peerStore: environment.trustedPeerStore))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HostPageHeader(
                    eyebrow: "Paired Devices",
                    title: "Trusted Devices",
                    subtitle: "Devices that have been approved to control this Mac remotely."
                )

                if viewModel.isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else if viewModel.trustedPeers.isEmpty && viewModel.revokedPeers.isEmpty {
                    HostEmptyStateView(
                        title: "No Paired Devices",
                        systemImage: "person.crop.circle.badge.plus",
                        message: "Trusted devices will appear here after pairing. When an unknown device connects, you'll be prompted to approve it."
                    )
                } else {
                    if !viewModel.trustedPeers.isEmpty {
                        HostSurfaceCard(title: "Trusted", subtitle: "Devices approved for connection.", systemImage: "checkmark.shield", accent: AppColor.success) {
                            VStack(spacing: 10) {
                                ForEach(viewModel.trustedPeers) { peer in
                                    PairedDeviceTile(
                                        peer: peer,
                                        isActive: viewModel.isActive(peer),
                                        revoke: {
                                            peerToRevoke = peer
                                            showRevokeConfirmation = true
                                        }
                                    )
                                }
                            }
                        }
                    }
                    if !viewModel.revokedPeers.isEmpty {
                        HostSurfaceCard(title: "Revoked", subtitle: "These devices no longer have access.", systemImage: "xmark.shield", accent: AppColor.error) {
                            VStack(spacing: 10) {
                                ForEach(viewModel.revokedPeers) { peer in
                                    PairedDeviceTile(
                                        peer: peer,
                                        isActive: false,
                                        reTrust: { Task { await viewModel.reTrust(peer) } },
                                        remove: { Task { await viewModel.remove(peer) } }
                                    )
                                }
                            }
                        }
                    }
                    if let error = viewModel.errorMessage {
                        Text(error).font(.caption).foregroundStyle(AppColor.error)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .navigationTitle("Paired Devices")
        .background(HostPageBackground())
        .toolbar {
            Button("Clear All", role: .destructive) {
                showClearConfirmation = true
            }
            .disabled(viewModel.isLoading || (viewModel.trustedPeers.isEmpty && viewModel.revokedPeers.isEmpty))
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .confirmationDialog(
            "Revoke Trust",
            isPresented: $showRevokeConfirmation,
            presenting: peerToRevoke
        ) { peer in
            Button("Revoke \(peer.displayName)", role: .destructive) {
                Task { await viewModel.revoke(peer) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { peer in
            Text("This device will no longer be able to control your Mac without re-approval.")
        }
        .confirmationDialog(
            "Clear Paired Devices",
            isPresented: $showClearConfirmation
        ) {
            Button("Clear All", role: .destructive) {
                Task { await viewModel.clearAllPaired() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all trusted and revoked devices from this Mac.")
        }
        .task {
            await viewModel.refresh()
        }
    }
}

private struct PairedDeviceTile: View {
    let peer: TrustedPeer
    let isActive: Bool
    var revoke: (() -> Void)?
    var reTrust: (() -> Void)?
    var remove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(peer.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                if isActive {
                    HostStatusChip(role: .active, label: "Active")
                }
                if peer.isRevoked {
                    HostStatusChip(role: .error, label: "Revoked")
                }
                Spacer()
            }
            HStack(spacing: 12) {
                HostInfoRow(label: "trusted", value: peer.trustedAt.formatted(date: .abbreviated, time: .shortened), isMonospaced: true)
                if let lastSeen = peer.lastSeenAt {
                    HostInfoRow(label: "last seen", value: lastSeen.formatted(date: .abbreviated, time: .shortened), isMonospaced: true)
                }
            }
            Text("Fingerprint: \(peer.fingerprint.prefix(16))…")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(AppColor.textSecondary)

            HStack(spacing: 8) {
                if let revoke {
                    HostActionButton("Revoke", systemImage: "xmark.circle", role: .destructive, action: revoke)
                }
                if let reTrust {
                    HostActionButton("Re-trust", systemImage: "checkmark.circle", role: .primary, action: reTrust)
                }
                if let remove {
                    HostActionButton("Remove", systemImage: "trash", role: .secondary, action: remove)
                }
                Spacer()
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColor.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppColor.borderSubtle, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.20), radius: 10, y: 4)
        }
    }
}

private struct HostStreamingView: View {
    let environment: HostAppEnvironment
    @ObservedObject private var permissionsViewModel: HostPermissionsViewModel
    @StateObject private var captureViewModel: CaptureStreamingViewModel
    @ObservedObject private var streamingCoordinator: HostStreamingCoordinator
    @State private var pivotTab: StreamingPivotTab = .capture

    init(environment: HostAppEnvironment) {
        self.environment = environment
        self.permissionsViewModel = environment.permissionsViewModel
        self.streamingCoordinator = environment.streamingCoordinator
        _captureViewModel = StateObject(
            wrappedValue: CaptureStreamingViewModel(
                captureEngine: environment.captureEngine,
                displayLayoutProvider: environment.displayLayoutProvider,
                eventLogStore: environment.eventLogStore
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HostPageHeader(
                    eyebrow: "Capture Pipeline",
                    title: "Streaming",
                    subtitle: "Control display capture, transport, and local recording from the host runtime."
                )

                MetroPivotTabs(
                    tabs: StreamingPivotTab.allCases,
                    selectedTab: $pivotTab,
                    title: { $0.title }
                )

                if pivotTab == .capture && !permissionsViewModel.blockers.isEmpty {
                            HostSurfaceCard(title: "Blocked", subtitle: "Approve the required host permissions before streaming can start.", systemImage: "lock.trianglebadge.exclamationmark", accent: AppColor.warning) {
                        VStack(alignment: .leading, spacing: 8) {
                        Label("Streaming is blocked by missing host permissions", systemImage: "lock.trianglebadge.exclamationmark")
                            .font(.headline)
                        ForEach(permissionsViewModel.blockers) { status in
                            Text(status.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                    }
                }

                if pivotTab == .capture {
                    HostWakeReadinessCard()
                }

                if pivotTab == .capture {
                    HostSurfaceCard(title: "Capture", subtitle: "Display source, quality preset, and capture pipeline state.", systemImage: "display", accent: AppColor.primaryAccent) {
                    VStack(alignment: .leading, spacing: 12) {
                        HostInfoRow(label: "State", value: captureViewModel.stateText)
                        if let displays = captureViewModel.displayLayout?.displays, !displays.isEmpty {
                            HStack(spacing: 10) {
                                Text("Display")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 126, alignment: .leading)
                                Picker("", selection: $captureViewModel.selectedDisplayID) {
                                    ForEach(displays) { display in
                                        Text("\(display.name)\(display.isPrimary ? " (Primary)" : "")")
                                            .tag(Optional(display.id))
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                                Spacer()
                            }
                        }
                        HStack(spacing: 10) {
                            Text("Quality")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 126, alignment: .leading)
                            Picker("", selection: $captureViewModel.selectedPreset) {
                                ForEach(StreamQualityPreset.allCases, id: \.self) { preset in
                                    Text(preset.rawValue.capitalized).tag(preset)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Spacer()
                        }
                        HostInfoRow(label: "Config", value: captureViewModel.configSummary)
                        HStack(spacing: 8) {
                            if captureViewModel.canStart {
                                HostActionButton("Start Capture", systemImage: "play.fill", role: .primary) {
                                    Task { await captureViewModel.startCapture() }
                                }
                            }
                            if captureViewModel.isRunning {
                                HostActionButton("Stop Capture", systemImage: "stop.fill", role: .destructive) {
                                    Task { await captureViewModel.stopCapture() }
                                }
                                HostActionButton("Restart", systemImage: "arrow.clockwise", role: .secondary) {
                                    Task { await captureViewModel.restartCapture() }
                                }
                            }
                        }
                        .disabled(captureViewModel.isStarting)
                        .padding(.top, 4)
                        if let error = captureViewModel.errorMessage {
                            Text(error).foregroundStyle(AppColor.error).font(.caption).padding(.top, 2)
                        }
                    }
                }

                HostSurfaceCard(title: "Recording", subtitle: "Write a local H.264 MP4 from the live capture stream.", systemImage: "record.circle", accent: AppColor.error) {
                    VStack(alignment: .leading, spacing: 10) {
                    switch streamingCoordinator.recordingService.state {
                    case .idle:
                        Text("Recording is idle.")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    case .recording(let url):
                        HostInfoRow(label: "Recording To", value: url.lastPathComponent)
                    case .finished(let url):
                        VStack(alignment: .leading, spacing: 6) {
                            HostInfoRow(label: "Saved As", value: url.lastPathComponent)
                            ShareLink(item: url) {
                                Label("Share Recording", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                    case .failed(let message):
                        Text(message).foregroundStyle(AppColor.error).font(.caption)
                    }
                    HStack(spacing: 8) {
                        HostActionButton("Start Recording", systemImage: "record.circle", role: .primary) {
                            streamingCoordinator.startRecording()
                        }
                        .disabled({
                            if case .recording = streamingCoordinator.recordingService.state { return true }
                            return false
                        }())
                        HostActionButton("Stop Recording", systemImage: "stop.fill", role: .destructive) {
                            streamingCoordinator.stopRecording()
                        }
                        .disabled({
                            if case .recording = streamingCoordinator.recordingService.state { return false }
                            return true
                        }())
                    }
                    .padding(.top, 4)
                    Text("Recording now writes a playable H.264 MP4 from the capture stream without disturbing the remote transport path.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }

                HostSurfaceCard(title: "Transfers", subtitle: "Send from this Mac or approve incoming files with explicit confirmation.", systemImage: "folder.badge.plus", accent: AppColor.success) {
                    VStack(alignment: .leading, spacing: 10) {
                        HostActionButton("Send to client Mac", systemImage: "square.and.arrow.up") {
                            Task { await environment.sendFileToConnectedClient() }
                        }
                        .disabled(environment.sessionCoordinator.activeSessionID == nil)

                        if let outgoing = environment.outgoingFileTransferController.activeTransfer {
                            VStack(alignment: .leading, spacing: 4) {
                                HostInfoRow(label: "Outgoing", value: outgoing.fileName)
                                HostInfoRow(label: "Progress", value: "\(outgoing.transferredBytes) / \(outgoing.totalBytes) bytes", isMonospaced: true)
                                HostInfoRow(label: "Status", value: {
                                    switch outgoing.status {
                                    case .preparing:
                                        return "Preparing"
                                    case .waitingForClient:
                                        return "Waiting for client Mac"
                                    case .sending:
                                        return "Sending"
                                    case .completed(let detail):
                                        return detail
                                    case .canceled:
                                        return "Canceled"
                                    case .failed(let detail):
                                        return detail
                                    }
                                }())
                            }
                        } else if let outgoingMessage = environment.outgoingFileTransferController.lastMessage {
                            Text(outgoingMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        if let active = environment.fileTransferStore.activeTransferSummary {
                            VStack(alignment: .leading, spacing: 4) {
                                HostInfoRow(label: "Active", value: active.fileName)
                                HostInfoRow(label: "Progress", value: "\(active.transferredBytes) / \(active.totalBytes) bytes", isMonospaced: true)
                                HostInfoRow(label: "Folder", value: active.destinationDescription)
                            }
                        } else {
                            Text("No file transfer is active.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        if environment.fileTransferStore.history.isEmpty {
                            Text("Transfers will appear here after a client Mac sends a file.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(environment.fileTransferStore.history.prefix(4)) { item in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.fileName)
                                            .font(.system(size: 12, weight: .semibold))
                                        Text(item.destinationDescription)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    Text(item.status.rawValue)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    #if os(macOS)
                                    if item.savedFileURL != nil {
                                        Button("Reveal") {
                                            environment.fileTransferStore.reveal(item)
                                        }
                                        .font(.system(size: 10, weight: .semibold))
                                    }
                                    #endif
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        if !environment.fileTransferStore.history.isEmpty {
                            HostActionButton("Clear History", systemImage: "trash", role: .secondary) {
                                environment.fileTransferStore.clearHistory()
                            }
                        }

                        if environment.outgoingFileTransferController.activeTransfer != nil {
                            HostActionButton("Dismiss Outgoing Status", systemImage: "xmark", role: .secondary) {
                                environment.outgoingFileTransferController.dismissTransfer()
                            }
                        }
                    }
                }
                }

                if pivotTab == .transport {
                    HostSurfaceCard(title: "Pipeline", subtitle: "Encoder state, codec config, and WebRTC transport readiness.", systemImage: "cpu", accent: AppColor.relayAccent) {
                    VStack(alignment: .leading, spacing: 0) {
                        HostInfoRow(label: "Encoder", value: environment.encoderPipeline.encoderState.rawValue.capitalized)
                        if let codec = environment.encoderPipeline.encoderDiagnostics.configuredCodec {
                            HostInfoRow(label: "Codec", value: codec.rawValue.uppercased(), isMonospaced: true)
                        }
                        if let w = environment.encoderPipeline.encoderDiagnostics.configuredWidth,
                           let h = environment.encoderPipeline.encoderDiagnostics.configuredHeight {
                            HostInfoRow(label: "Resolution", value: "\(w)×\(h)", isMonospaced: true)
                        }
                        if let bitrate = environment.encoderPipeline.encoderDiagnostics.configuredBitrate {
                            HostInfoRow(label: "Bitrate", value: "\(bitrate / 1_000) kbps", isMonospaced: true)
                        }
                        let encDiag = environment.encoderPipeline.encoderDiagnostics
                        if encDiag.encodedFrames > 0 {
                            HostInfoRow(label: "Encoded", value: "\(encDiag.encodedFrames) frames (\(encDiag.keyframes) KF, \(encDiag.encodeErrors) errors)")
                        }
                        if encDiag.reconfigureCount > 0 {
                            HostInfoRow(label: "Reconfigs", value: "\(encDiag.reconfigureCount)", isMonospaced: true)
                        }
                        HostInfoRow(label: "Transport", value: environment.webRTCSessionManager.connectionState.rawValue.capitalized)
                        HostInfoRow(label: "Peer", value: environment.webRTCSessionManager.peerConnectionState.rawValue.capitalized)
                        HostInfoRow(label: "Data Channel", value: environment.webRTCSessionManager.dataChannelState.rawValue.capitalized)
                    }
                }

                HostSurfaceCard(title: "Stream Bridge", subtitle: "Coordinates encoder output into the WebRTC data channel.", systemImage: "arrow.triangle.branch", accent: AppColor.lanAccent) {
                    VStack(alignment: .leading, spacing: 0) {
                        HostInfoRow(label: "Phase", value: streamingCoordinator.phase.rawValue.capitalized)
                        let sd = streamingCoordinator.streamDiagnostics
                        if sd.framesSent > 0 {
                            HostInfoRow(label: "Frames Sent", value: "\(sd.framesSent)", isMonospaced: true)
                        }
                        if sd.bytesSent > 0 {
                            HostInfoRow(label: "Bytes Sent", value: "\(sd.bytesSent / 1024) KB", isMonospaced: true)
                        }
                        if sd.restartCount > 0 {
                            HostInfoRow(label: "Restarts", value: "\(sd.restartCount)", isMonospaced: true)
                        }
                    }
                    HStack(spacing: 8) {
                        if streamingCoordinator.phase == .idle {
                            HostActionButton("Start Coordinator", systemImage: "play.fill", role: .primary) {
                                streamingCoordinator.startCoordinating()
                            }
                        }
                        if streamingCoordinator.phase != .idle {
                            HostActionButton("Stop Coordinator", systemImage: "stop.fill", role: .destructive) {
                                streamingCoordinator.stopCoordinating()
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                }

                if pivotTab == .diagnostics && (captureViewModel.diagnostics.capturedFrames > 0 || captureViewModel.isRunning) {
                    HostSurfaceCard(title: "Capture Diagnostics", subtitle: "Live frame counters and stream restart tracking.", systemImage: "chart.bar", accent: AppColor.relayAccent) {
                        VStack(alignment: .leading, spacing: 0) {
                            HostInfoRow(label: "Frames", value: captureViewModel.frameCountText)
                            HostInfoRow(label: "Restarts", value: "\(captureViewModel.diagnostics.streamRestarts)", isMonospaced: true)
                            if let ts = captureViewModel.diagnostics.lastFrameTimestamp {
                                HostInfoRow(label: "Last Frame", value: ts.formatted(date: .omitted, time: .standard), isMonospaced: true)
                            }
                        }
                    }
                }

                if pivotTab == .transport, let displayLayout = captureViewModel.displayLayout {
                    HostSurfaceCard(title: "Displays (\(displayLayout.displays.count))", subtitle: "Connected displays and pixel layout.", systemImage: "display.2", accent: AppColor.lanAccent) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(displayLayout.displays) { display in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(display.name)
                                                .font(.system(size: 13, weight: .semibold))
                                            if display.isPrimary {
                                                HostStatusChip(role: .active, label: "Primary")
                                            }
                                        }
                                        Text("\(Int(display.frame.size.width))×\(Int(display.frame.size.height)) pt · \(Int(display.pixelSize.width))×\(Int(display.pixelSize.height)) px · \(display.scaleFactor, specifier: "%.0f")x")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .overlay(alignment: .bottom) { Divider().opacity(0.4) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .navigationTitle("Streaming")
        .background(HostPageBackground())
        .task {
            await permissionsViewModel.refresh()
            await captureViewModel.loadDisplayLayout()
            captureViewModel.startObservingState()
            if let changes = environment.displayLayoutChanges {
                for await newLayout in changes {
                    captureViewModel.displayLayout = newLayout
                }
            }
        }
    }
}

private struct HostDiagnosticsView: View {
    let environment: HostAppEnvironment
    @StateObject private var viewModel: HostDiagnosticsViewModel
    @ObservedObject private var permissionsVM: HostPermissionsViewModel
    @ObservedObject private var streamingCoordinator: HostStreamingCoordinator
    @State private var exportURL: URL?
    @State private var pivotTab: DiagnosticsPivotTab = .health

    init(environment: HostAppEnvironment) {
        self.environment = environment
        self.permissionsVM = environment.permissionsViewModel
        self.streamingCoordinator = environment.streamingCoordinator
        _viewModel = StateObject(wrappedValue: HostDiagnosticsViewModel(eventLogStore: environment.eventLogStore))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HostPageHeader(
                    eyebrow: "Observability",
                    title: "Diagnostics",
                    subtitle: "Inspect permission readiness, transport health, capture throughput, and recent event history."
                )

                MetroPivotTabs(
                    tabs: DiagnosticsPivotTab.allCases,
                    selectedTab: $pivotTab,
                    title: { $0.title }
                )

                if pivotTab == .health {
                    HostSurfaceCard(title: "Permissions", subtitle: "Required host access for streaming and control.", systemImage: "checkmark.shield", accent: permissionsVM.blockers.isEmpty ? AppColor.success : AppColor.warning) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(permissionsVM.statuses) { status in
                            HStack(spacing: 10) {
                                Text(status.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 126, alignment: .leading)
                                Text(status.summary)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(status.isGranted ? AppColor.success : AppColor.warning)
                                Spacer()
                            }
                            .padding(.vertical, 5)
                            .overlay(alignment: .bottom) { Divider().opacity(0.4) }
                        }
                        Text(permissionsVM.dashboardSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                }
                }

                if pivotTab != .events {
                    HostSurfaceCard(title: "Capture", subtitle: "Live display capture pipeline state and frame counters.", systemImage: "rectangle.dashed", accent: AppColor.primaryAccent) {
                    let cap = environment.captureEngine
                    VStack(alignment: .leading, spacing: 0) {
                        HostInfoRow(label: "State", value: cap.captureState.rawValue.capitalized)
                        HostInfoRow(label: "Frames", value: "\(cap.diagnostics.capturedFrames) captured, \(cap.diagnostics.droppedFrames) dropped")
                        HostInfoRow(label: "Restarts", value: "\(cap.diagnostics.streamRestarts)", isMonospaced: true)
                        if let display = cap.diagnostics.currentDisplayID {
                            HostInfoRow(label: "Display", value: display)
                        }
                    }
                }
                }

                if pivotTab == .pipeline {
                    HostSurfaceCard(title: "Encoder", subtitle: "VideoToolbox encoder health, codec, and output statistics.", systemImage: "cpu", accent: AppColor.relayAccent) {
                    let enc = environment.encoderPipeline
                    let diag = enc.encoderDiagnostics
                    VStack(alignment: .leading, spacing: 0) {
                        HostInfoRow(label: "State", value: enc.encoderState.rawValue.capitalized)
                        HostInfoRow(label: "Frames", value: "\(diag.encodedFrames) encoded, \(diag.keyframes) KF, \(diag.encodeErrors) errors")
                        if let codec = diag.configuredCodec {
                            HostInfoRow(label: "Codec", value: codec.rawValue.uppercased(), isMonospaced: true)
                        }
                        if let bitrate = diag.configuredBitrate {
                            HostInfoRow(label: "Bitrate", value: "\(bitrate / 1_000) kbps", isMonospaced: true)
                        }
                    }
                }
                }

                if pivotTab == .pipeline {
                    HostSurfaceCard(title: "Transport", subtitle: "WebRTC connection state and stream bridge readiness.", systemImage: "network", accent: AppColor.lanAccent) {
                    let mgr = environment.webRTCSessionManager
                    VStack(alignment: .leading, spacing: 0) {
                        HostInfoRow(label: "Connection", value: mgr.connectionState.rawValue.capitalized)
                        HostInfoRow(label: "Peer", value: mgr.peerConnectionState.rawValue.capitalized)
                        HostInfoRow(label: "Data Channel", value: mgr.dataChannelState.rawValue.capitalized)
                        HostInfoRow(label: "Bridge", value: streamingCoordinator.phase.rawValue.capitalized)
                        let sd = streamingCoordinator.streamDiagnostics
                        if sd.framesSent > 0 {
                            HostInfoRow(label: "Sent", value: "\(sd.framesSent) frames, \(sd.bytesSent / 1024) KB")
                        }
                    }
                }
                }

                if pivotTab == .events {
                    HostSurfaceCard(title: "Recent Events", subtitle: "Up to 20 most recent runtime log entries.", systemImage: "list.bullet.rectangle", accent: AppColor.relayAccent) {
                    if viewModel.items.isEmpty {
                        Text("No events recorded yet.")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.items.prefix(20)) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(item.severity.diagnosticsColor)
                                    .frame(width: 7, height: 7)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(item.category)
                                            .font(.system(size: 11, weight: .semibold))
                                        Spacer()
                                        Text(item.timestamp.formatted(date: .omitted, time: .standard))
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(item.message)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .overlay(alignment: .bottom) { Divider().opacity(0.35) }
                        }
                        }
                    }
                }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .navigationTitle("Diagnostics")
        .background(HostPageBackground())
        .toolbar {
            Button("Clear") {
                Task { await viewModel.clear() }
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            } else {
                Button("Export") {
                    Task {
                        let items = await environment.eventLogStore.recentItems(limit: 500)
                        let exporter = EventLogExportService()
                        exportURL = try? exporter.export(
                            items: items,
                            destinationDirectory: FileManager.default.temporaryDirectory,
                            filePrefix: "host-event-log"
                        )
                    }
                }
            }
            Button {
                Task {
                    await permissionsVM.refresh()
                    await viewModel.refresh()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .task {
            await permissionsVM.refresh()
            await viewModel.refresh()
        }
    }
}

private struct PermissionCardView: View {
    let status: FriendlyPermissionStatus
    let openSettings: () -> Void
    let retry: () -> Void
    let prompt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(status.authorizationState.permissionColor.opacity(0.12))
                    .frame(width: 38, height: 38)
                    .overlay {
                        Image(systemName: status.authorizationState.permissionIcon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(status.authorizationState.permissionColor)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(status.title)
                            .font(.system(size: 14, weight: .semibold))
                        HostStatusChip(
                            role: status.authorizationState == .granted ? .ready : (status.isRequired ? .awaiting : .stopped),
                            label: status.summary
                        )
                    }
                    Text(status.helperText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                HostActionButton(status.settingsButtonTitle, systemImage: "gearshape", role: .primary, action: openSettings)
                if status.isRequired {
                    HostActionButton("Retry", systemImage: "arrow.clockwise", role: .secondary, action: retry)
                    HostActionButton("Request Prompt", systemImage: "hand.tap", role: .secondary, action: prompt)
                        .disabled(status.authorizationState == .granted)
                } else {
                    Text("Available in the direct-download host.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppColor.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(status.authorizationState.permissionColor.opacity(0.28), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
        }
    }
}

private struct HostPageHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.title.weight(.semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 660, alignment: .leading)
        }
    }
}

/// A flat, native card surface with an icon + title header and optional subtitle.
/// `waveIndex` / `waveStep` are retained for source compatibility but no longer
/// drive any animation.
struct HostSurfaceCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    var waveIndex: Int = 0
    var waveStep: Double = 0.06
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(accent)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(AppColor.card)
                .overlay {
                    RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                        .strokeBorder(AppColor.borderSubtle, lineWidth: 1)
                }
        }
    }
}

private struct MetroPivotTabs<T: Identifiable & Hashable>: View {
    let tabs: [T]
    @Binding var selectedTab: T
    var compact: Bool = false
    let title: (T) -> String

    var body: some View {
        Picker("", selection: $selectedTab) {
            ForEach(tabs) { tab in
                Text(title(tab)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(compact ? .small : .regular)
    }
}


private struct HostPageBackground: View {
    var body: some View {
        AppBackground()
    }
}

private struct HostEmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppColor.primaryAccent.opacity(0.12))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AppColor.primaryAccent)
                }
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
                .tracking(-0.3)
            Text(message)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColor.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppColor.borderSubtle, lineWidth: 1)
                }
        )
    }
}

private extension PermissionKind {
    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .localNetwork: "Local Network"
        case .microphone: "Microphone"
        }
    }

    var systemImage: String {
        switch self {
        case .screenRecording: "rectangle.dashed"
        case .accessibility: "cursorarrow.motionlines"
        case .localNetwork: "network"
        case .microphone: "mic"
        }
    }
}

private extension PermissionAuthorizationState {
    var permissionIcon: String {
        switch self {
        case .granted:
            return "checkmark.circle.fill"
        case .denied, .restricted:
            return "exclamationmark.triangle.fill"
        case .unknown, .notDetermined:
            return "questionmark.circle"
        }
    }

    var permissionColor: Color {
        switch self {
        case .granted:
            return AppColor.success
        case .denied, .restricted:
            return AppColor.warning
        case .unknown, .notDetermined:
            return AppColor.disconnected
        }
    }
}

private extension EventSeverity {
    var permissionColor: Color {
        switch self {
        case .debug:
            return AppColor.disconnected
        case .info:
            return AppColor.primaryAccent
        case .warning:
            return AppColor.warning
        case .error:
            return AppColor.error
        }
    }

    var diagnosticsColor: Color {
        switch self {
        case .debug:   return AppColor.disconnected
        case .info:    return AppColor.primaryAccent
        case .warning: return AppColor.warning
        case .error:   return AppColor.error
        }
    }
}

// MARK: - Trust Prompt Banner

/// Persistent in-dashboard pairing-request banner.
/// Renders alongside the system alert so the host operator can act on the
/// request even when the alert window is hidden behind another app or the
/// MacHost UI is minimized.  Drives a live countdown from `deadline` so the
/// remaining response window is always visible.
private struct TrustPromptBanner: View {
    let prompt: HostAppEnvironment.TrustPrompt
    let deadline: Date?
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(Color.accentColor)
                Text("Pairing request")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if let deadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                        Text("Auto-rejects in \(remaining)s")
                            .font(.caption)
                            .foregroundStyle(remaining <= 5 ? Color.red : Color.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Text("\(prompt.displayName) wants to \(pairingAccessVerb) this Mac.")
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)

            Text(prompt.fingerprint)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("Compare the full fingerprint out of band before Approve.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Reject", role: .destructive, action: onReject)
                    .buttonStyle(.bordered)
                Button("Approve", action: onApprove)
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hostGlassSurface(
            in: RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous),
            isInteractive: true
        )
    }

    private var pairingAccessVerb: String {
        "control"
    }
}

// MARK: - Permission Explainer

/// First-run explainer that runs *before* macOS's TCC dialogs so the
/// operator understands what's being asked and why.  After tapping
/// "Continue", the host calls CGRequestScreenCaptureAccess() which fires
/// the real OS dialog.
private struct HostPermissionExplainerSheet: View {
    let supportsRemoteInput: Bool
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(supportsRemoteInput ? "Two quick permissions" : "One quick permission")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(supportsRemoteInput
                    ? "Vamp Host needs two macOS privacy permissions to stream your screen and accept input from another Mac. Both prompts will appear next."
                    : "Vamp Host needs Screen Recording permission to stream your Mac display.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                explainerRow(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording",
                    body: "Captures this Mac's display so it can be streamed to the client Mac. Required — without it, there's nothing to stream."
                )
                if supportsRemoteInput {
                    explainerRow(
                        icon: "hand.tap",
                        title: "Accessibility",
                        body: "Lets the client Mac send mouse and keyboard input back to your Mac. Required for control — denying it puts the session in view-only mode."
                    )
                } else {
                    explainerRow(
                        icon: "eye",
                        title: "View Only mode",
                        body: "This sandboxed build cannot request Accessibility, so it supports view-only sessions."
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Your data stays on your devices")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Nothing is sent to a project relay. Sessions run directly between your Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(28)
    }

    @ViewBuilder
    private func explainerRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
