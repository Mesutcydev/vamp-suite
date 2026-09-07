import SwiftUI
import SharedModels
import SharedProtocol
import SharedUtilities
import TransportWebRTC
#if canImport(UIKit)
import UIKit
#endif

private extension View {
    @ViewBuilder
    func prFullscreenCompat<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
#if os(macOS)
        self.sheet(isPresented: isPresented, content: content)
#else
        self.fullScreenCover(isPresented: isPresented, content: content)
#endif
    }

    @ViewBuilder
    func liquidGlassPill() -> some View {
        prGlassSurface(in: Capsule(style: .continuous))
    }
}

@available(iOS 16.1, *)
struct MirrorScreen: View {
    let environment: ClientAppEnvironment

    @StateObject private var rendererVM: VideoRendererViewModel
    @StateObject private var statsVM: SessionStatsViewModel
    @ObservedObject private var hostsVM: HostsListViewModel
    @StateObject private var fileTransferManager: ClientFileTransferManager
    @ObservedObject private var sessionCoordinator: ClientSessionCoordinator
    @State private var pendingHostID: UUID?
    @State private var isFullscreenPresented = false
    @State private var isHostPickerPresented = false
    @State private var screenshotStatus = ""
    @State private var isDisconnectPending = false
    @State private var isScanningHosts = false
    @State private var diagFramesRx: UInt64 = 0
    @State private var diagBytesRx: UInt64 = 0
    @State private var diagDecodeErrors: UInt64 = 0
    private let screenshotService = SessionScreenshotService()

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        self.sessionCoordinator = environment.sessionCoordinator
        _rendererVM = StateObject(
            wrappedValue: VideoRendererViewModel(webRTCSessionManager: environment.webRTCSessionManager)
        )
        _statsVM = StateObject(
            wrappedValue: SessionStatsViewModel(
                webRTCSessionManager: environment.webRTCSessionManager,
                sessionCoordinator: environment.sessionCoordinator
            )
        )
        self.hostsVM = environment.sharedHostsViewModel
        _fileTransferManager = StateObject(
            wrappedValue: ClientFileTransferManager(
                webRTCSessionManager: environment.webRTCSessionManager,
                sessionCoordinator: environment.sessionCoordinator,
                clientIdentity: environment.clientIdentity
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            PRScreenHeader(
                title: "mirror",
                host: sessionCoordinator.connectedHostName ?? "no-host",
                latency: statsVM.latencyText,
                state: headerState
            )

            ScrollView {
                VStack(spacing: 12) {
                    PRCard("stream") {
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: PR.r8)
                                .fill(Color.black)
                                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                                .contentShape(RoundedRectangle(cornerRadius: PR.r8))
                                .onTapGesture {
                                    presentFullscreenIfPossible()
                                }
                                .overlay {
                                    if let frame = rendererVM.latestPixelBuffer {
#if canImport(UIKit) && !os(macOS)
                                        VideoFrameRendererView(pixelBuffer: frame, renderer: rendererVM)
                                            .clipShape(RoundedRectangle(cornerRadius: PR.r8))
#elseif os(macOS)
                                        VideoFrameRendererViewMac(pixelBuffer: frame)
                                            .clipShape(RoundedRectangle(cornerRadius: PR.r8))
#endif
                                    } else {
                                        VStack(spacing: 6) {
                                            Image(systemName: "display")
                                                .font(.system(size: 22, weight: .semibold))
                                                .foregroundColor(PR.dim)
                                            Text("waiting for frame")
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(PR.dim)
                                            if sessionCoordinator.activeSessionID != nil {
                                                MirrorStreamDiagPanel(
                                                    framesReceived: diagFramesRx,
                                                    bytesReceived: diagBytesRx,
                                                    framesDecoded: rendererVM.framesDecoded,
                                                    decodeErrors: diagDecodeErrors
                                                )
                                                .padding(.top, 2)
                                            }
                                        }
                                    }
                                }

                            if environment.showsStatsOverlay {
                                MirrorHUD(
                                    isDismissible: false,
                                    fps: statsVM.fpsText,
                                    latency: statsVM.latencyText,
                                    bandwidth: statsVM.bitrateText,
                                    onClose: nil
                                )
                                .padding(10)
                            }
                        }

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            MirrorControlButton(icon: "desktopcomputer", label: "hosts", combo: "H") {
                                isHostPickerPresented = true
                            }
                            MirrorControlButton(icon: "character.cursor.ibeam", label: "keys", combo: "K") {
                                NotificationCenter.default.post(name: .prRequestTabChange, object: PRAppTab.keys.rawValue)
                            }
                            MirrorControlButton(icon: "rectangle.3.offgrid", label: "screens", combo: "S") {
                                NotificationCenter.default.post(name: .prRequestTabChange, object: PRAppTab.screens.rawValue)
                            }
                            MirrorControlButton(icon: "camera", label: "capture", combo: "◉") {
                                captureScreenshot()
                            }
                            MirrorControlButton(icon: "chart.bar", label: "stats", combo: "FPS") {
                                environment.showsStatsOverlay.toggle()
                            }
                            MirrorControlButton(icon: "folder.badge.plus", label: "file", combo: "UP") {
                                fileTransferManager.isImporterPresented = true
                            }
                            MirrorControlButton(icon: "arrow.left.arrow.right", label: "switch", combo: "⇥") {
                                cycleDisplay()
                            }
                            MirrorControlButton(
                                icon: isScanningHosts ? "dot.radiowaves.left.and.right" : "arrow.clockwise",
                                label: isScanningHosts ? "scanning" : "scan",
                                combo: "⟳"
                            ) {
                                scanHosts()
                            }
                            .disabled(isScanningHosts)
                        }

                        Button {
                            presentFullscreenIfPossible()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("fullscreen")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                Spacer()
                                Text("mouse + keyboard")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(PR.dim)
                            }
                            .foregroundColor(sessionCoordinator.activeSessionID == nil ? PR.dim : PR.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(PR.bg2)
                            .overlay(
                                RoundedRectangle(cornerRadius: PR.r8)
                                    .strokeBorder(sessionCoordinator.activeSessionID == nil ? PR.border : PR.accent.opacity(0.45))
                            )
                            .clipShape(RoundedRectangle(cornerRadius: PR.r8))
                        }
                        .buttonStyle(.plain)
                        .disabled(sessionCoordinator.activeSessionID == nil || isFullscreenPresented)

                        Button(action: primaryAction) {
                            Text(primaryActionTitle)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(primaryActionEnabled ? PR.bg : PR.dim)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(primaryActionEnabled ? PR.accent : PR.bg2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: PR.r8)
                                        .strokeBorder(primaryActionEnabled ? PR.accent.opacity(0.45) : PR.border)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: PR.r8))
                        }
                        .buttonStyle(.plain)
                        .disabled(!primaryActionEnabled)

                        if !streamHint.isEmpty {
                            Text(LocalizedStringKey(streamHint))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(PR.dim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !screenshotStatus.isEmpty {
                            Text(screenshotStatus)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(PR.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PR.bg.ignoresSafeArea())
        .task {
            rendererVM.onNeedsKeyframe = { [weak sessionCoordinator = sessionCoordinator] in
                sessionCoordinator?.requestKeyframeRefresh(reason: "decode error")
            }
            rendererVM.startReceiving()
            statsVM.start(refreshInterval: 1.0)
            await hostsVM.start()
        }
        .task(id: sessionCoordinator.activeSessionID) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let d = environment.webRTCSessionManager.streamDiagnostics
                diagFramesRx = d.framesReceived
                diagBytesRx = d.bytesReceived
                diagDecodeErrors = rendererVM.decoder.decodeErrors
            }
        }
        .onDisappear {
            if !isFullscreenPresented {
                rendererVM.stopReceiving()
            }
            statsVM.stop()
        }
        .prFullscreenCompat(isPresented: $isFullscreenPresented) {
            MirrorFullscreenStreamView(
                environment: environment,
                rendererVM: rendererVM,
                statsVM: statsVM,
                onClose: { isFullscreenPresented = false }
            )
            .ignoresSafeArea()
        }
        .onChangeCompat(of: sessionCoordinator.phase) { phase in
            if phase != .receiving {
                isDisconnectPending = false
            }
            if phase == .receiving, let id = pendingHostID {
                hostsVM.markHostConnected(id)
                pendingHostID = nil
            }
        }
        .onChangeCompat(of: sessionCoordinator.activeSessionID) { sessionID in
            guard sessionID != nil else { return }
            // Resubscribe for each new session; frame stream tasks can end on disconnect.
            rendererVM.startReceiving()
        }
        .confirmationDialog("available hosts", isPresented: $isHostPickerPresented, titleVisibility: .visible) {
            if hostPickerHosts.isEmpty {
                Button("No hosts found") {}
                    .disabled(true)
            } else {
                ForEach(hostPickerHosts) { host in
                    Button(hostPickerTitle(for: host)) {
                        connect(to: host)
                    }
                }
            }
            Button("Open hosts tab") {
                NotificationCenter.default.post(name: .prRequestTabChange, object: PRAppTab.hosts.rawValue)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if hostPickerHosts.isEmpty {
                if !terminalOnlyHosts.isEmpty {
                    Text("No Vamp Host targets are available. This Mac is running Vamp Terminal Host; use Vamp Terminal for terminal tabs.")
                } else {
                    Text("Scan from the hosts tab if nothing appears here.")
                }
            } else {
                Text("Select a Mac without leaving mirror.")
            }
        }
        .fileImporter(
            isPresented: $fileTransferManager.isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                fileTransferManager.sendFile(url: url)
            }
        }
    }

    private var isConnecting: Bool {
        if isStreamActive {
            return false
        }
        switch sessionCoordinator.phase {
        case .connecting, .signalingConnected, .negotiating, .waitingForMedia:
            return true
        default:
            return false
        }
    }

    private var isStreamActive: Bool {
        sessionCoordinator.phase == .receiving
    }

    private var primaryActionTitle: LocalizedStringKey {
        if isDisconnectPending {
            return "disconnecting..."
        }
        if isStreamActive || isConnecting {
            return isConnecting ? "connecting..." : "disconnect"
        }
        if remoteControlHosts.isEmpty {
            return terminalOnlyHosts.isEmpty ? "start stream (scan hosts first)" : "install Vamp Host to stream"
        }
        return "start stream"
    }

    private var primaryActionEnabled: Bool {
        if isDisconnectPending { return false }
        if isConnecting { return false }
        if isStreamActive { return true }
        return !remoteControlHosts.isEmpty
    }

    private var streamHint: String {
        if sessionCoordinator.phase == .error {
            return sessionCoordinator.blockedState?.message
                ?? sessionCoordinator.errorMessage
                ?? "stream failed to start"
        }
        if hostPickerHosts.isEmpty {
            return "Open hosts tab and scan LAN, then return here to start stream."
        }
        return ""
    }

    private func cycleDisplay() {
        let displays = environment.displayLayoutViewModel.displays
        guard !displays.isEmpty else { return }

        if let currentID = environment.displayLayoutViewModel.selectedDisplayID,
           let idx = displays.firstIndex(where: { $0.id == currentID }) {
            let next = displays[(idx + 1) % displays.count]
            environment.displayLayoutViewModel.selectDisplay(id: next.id)
        } else if let primary = environment.displayLayoutViewModel.primaryDisplay ?? displays.first {
            environment.displayLayoutViewModel.selectDisplay(id: primary.id)
        }
    }

    private func presentFullscreenIfPossible() {
        guard sessionCoordinator.activeSessionID != nil else { return }
        guard !isFullscreenPresented else { return }
        isFullscreenPresented = true
    }

    private func captureScreenshot() {
        guard let pixelBuffer = rendererVM.latestPixelBuffer else {
            screenshotStatus = "no frame to capture"
            return
        }

        do {
            let url = try screenshotService.capture(pixelBuffer: pixelBuffer)
            screenshotStatus = "saved: \(url.lastPathComponent)"
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                screenshotStatus = ""
            }
        } catch {
            screenshotStatus = "screenshot failed"
        }
    }

    private func primaryAction() {
        if isStreamActive {
            isDisconnectPending = true
            Task { await sessionCoordinator.disconnect() }
            return
        }

        guard let target = hostPickerHosts.first else {
            return
        }

        connect(to: target)
    }

    private func scanHosts() {
        guard !isScanningHosts else { return }
        isScanningHosts = true
        AppHaptics.selection()
        Task {
            await hostsVM.refresh()
            await MainActor.run {
                isScanningHosts = false
            }
        }
    }

    private var hostPickerHosts: [DiscoveredHostRow] {
        // One entry per physical Mac (collapses old/new LAN IPs + the relay sibling).
        remoteControlHosts
    }

    private var remoteControlHosts: [DiscoveredHostRow] {
        hostsVM.displayHosts.filter { !$0.isTerminalOnlyHost }
    }

    private var terminalOnlyHosts: [DiscoveredHostRow] {
        hostsVM.displayHosts.filter(\.isTerminalOnlyHost)
    }

    private func hostPickerTitle(for host: DiscoveredHostRow) -> String {
        let status = host.isAvailable ? "online" : "saved"
        return "\(host.title) · \(status)"
    }

    private func connect(to host: DiscoveredHostRow) {
        guard !host.isTerminalOnlyHost else {
            // Keep the mirror flow deterministic even if a terminal-only row is
            // supplied by a stale picker or a future entry point.
            return
        }
        pendingHostID = host.id
        hostsVM.connect(to: host)
        Task {
            if isStreamActive || isConnecting || sessionCoordinator.activeSessionID != nil {
                await sessionCoordinator.disconnect()
            }
            await sessionCoordinator.connect(
                to: host.endpoint,
                qualityPreset: environment.effectivePreferredQualityPreset
            )
        }
    }

    private var headerState: PRScreenHeader.State {
        switch sessionCoordinator.phase {
        case .receiving:
            return .live
        case .error:
            return .error
        default:
            return isStreamActive ? .live : .idle
        }
    }
}

// MARK: - Simple Mode Home

/// Simple Mode: an easier, friendlier front-end over the *same* functionality.
/// Saved/discovered Macs show up as laptop tiles — tap one and it connects, then
/// the exact same fullscreen stream (`MirrorFullscreenStreamView`) opens with
/// identical controls. Nothing is removed: advanced config (quality, security,
/// app lock and quality controls stay one tap away behind the gear. Built with the shared PR
/// design language so it matches the rest of the app.
@available(iOS 16.1, *)
struct SimpleHomeView: View {
    let environment: ClientAppEnvironment
    @ObservedObject var appLock: AppLockService

    @StateObject private var rendererVM: VideoRendererViewModel
    @StateObject private var statsVM: SessionStatsViewModel
    @ObservedObject private var hostsVM: HostsListViewModel
    @ObservedObject private var sessionCoordinator: ClientSessionCoordinator
    @Environment(\.scenePhase) private var scenePhase
    /// When on, a connected session shows the live mirror inline on this home screen
    /// (tap to go fullscreen) instead of auto-opening fullscreen. Mirrors the old
    /// developer "stream" card. Off keeps the simple straight-to-fullscreen flow.
    @AppStorage("client.ui.inlineStreamPreview") private var inlineStreamPreview = false
    /// Set once the user confirms that Vamp Host is installed —
    /// permanently hides the host download cards on the home screen. Settings still shows them.
    @AppStorage("client.ui.vampHostInstalled") private var vampHostInstalled = false

    @State private var manualAddress = ""
    @State private var showManualConnect = false
    @State private var showSettings = false
    @State private var showStream = false
    @State private var connectingHostID: UUID?
    @State private var isScanning = false
    @State private var wakingHostID: UUID?
    @State private var wakeFeedback: String?
    @State private var wakeFeedbackIsError = false
    @State private var errorText: String?
    @State private var pendingTailscaleHost: DiscoveredHostRow?
    /// Set when the user taps a sleeping host that the OS can't wake remotely (Apple-Silicon on
    /// Wi-Fi). Drives a guidance alert instead of a doomed wake.
    @State private var pendingUnwakeableHost: DiscoveredHostRow?
    /// Home host-promo dismissal: a session-only hide ("Not yet") plus the confirm prompt.
    @State private var promoDismissedThisSession = false
    @State private var showInstalledPrompt = false

    private let columns = [
        GridItem(.adaptive(minimum: 146, maximum: 220), spacing: 12)
    ]

    init(environment: ClientAppEnvironment, appLock: AppLockService) {
        self.environment = environment
        self.appLock = appLock
        self.sessionCoordinator = environment.sessionCoordinator
        self.hostsVM = environment.sharedHostsViewModel
        _rendererVM = StateObject(
            wrappedValue: VideoRendererViewModel(webRTCSessionManager: environment.webRTCSessionManager)
        )
        _statsVM = StateObject(
            wrappedValue: SessionStatsViewModel(
                webRTCSessionManager: environment.webRTCSessionManager,
                sessionCoordinator: environment.sessionCoordinator
            )
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 14) {
                    if let errorText {
                        errorBanner(errorText)
                    }

                    if inlineStreamPreview && sessionCoordinator.phase == .receiving {
                        streamPreviewCard
                    }

                    if hosts.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(hosts) { host in
                                laptopTile(host)
                            }
                        }
                    }

                    connectByIPButton

                    if !hosts.isEmpty && !vampHostInstalled && !promoDismissedThisSession {
                        homeHostPromo
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 85)
                .padding(.bottom, 28)
            }
            .refreshable { await scan() }

            header
                .zIndex(1)
        }
        .background { PRAppBackground() }
        .overlay(alignment: .bottom) {
            if let wakeFeedback {
                wakeToast(wakeFeedback, isError: wakeFeedbackIsError)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            rendererVM.onNeedsKeyframe = { [weak sessionCoordinator = sessionCoordinator] in
                sessionCoordinator?.requestKeyframeRefresh(reason: "decode error")
            }
            rendererVM.startReceiving()
            statsVM.start(refreshInterval: 1.0)
            await hostsVM.start()
        }
        .onDisappear {
            statsVM.stop()
            if !showStream {
                rendererVM.stopReceiving()
            }
        }
        .onChangeCompat(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await hostsVM.handleSceneBecameActive() }
        }
        .onChangeCompat(of: sessionCoordinator.activeSessionID) { sessionID in
            guard sessionID != nil else { return }
            // Resubscribe for each new session; the frame stream ends on disconnect.
            rendererVM.startReceiving()
        }
        .onChangeCompat(of: sessionCoordinator.phase) { phase in
            switch phase {
            case .receiving:
                connectingHostID = nil
                errorText = nil
                // Inline-preview mode shows the live mirror on this screen instead of
                // jumping straight to fullscreen.
                if !inlineStreamPreview && !showStream { showStream = true }
            case .error:
                connectingHostID = nil
                showStream = false
                // Prefer the host-permission-blocked message: when the Mac lacks Screen Recording /
                // Accessibility, the accurate guidance is in blockedState — falling back to the
                // generic network message here told users to check Wi-Fi for a permission problem.
                errorText = sessionCoordinator.blockedState?.message
                    ?? sessionCoordinator.errorMessage
                    ?? "Couldn’t reach that Mac. Make sure Vamp Host is open on the same network."
            case .idle:
                connectingHostID = nil
                showStream = false
            default:
                break
            }
        }
        .prFullscreenCompat(isPresented: $showStream) {
            MirrorFullscreenStreamView(
                environment: environment,
                rendererVM: rendererVM,
                statsVM: statsVM,
                onClose: {
                    showStream = false
                    // With the inline preview on, closing fullscreen returns to the inline
                    // mirror — keep the session alive; its disconnect button ends it.
                    if !inlineStreamPreview {
                        Task { await sessionCoordinator.disconnect() }
                    }
                }
            )
            .ignoresSafeArea()
        }
        .overlay {
            if connectingHostID != nil {
                connectingOverlay
            }
        }
        .sheet(isPresented: $showManualConnect) {
            manualConnectSheet
        }
        .sheet(isPresented: $showSettings) {
            ConfigScreen(environment: environment, appLock: appLock)
                .presentationDragIndicator(.visible)
        }
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
                if let host { startConnect(host) }
            }
            Button("Cancel", role: .cancel) { pendingTailscaleHost = nil }
        } message: {
            Text("This looks like a Tailscale address. Make sure the Tailscale VPN is connected on this iPhone, then try again — otherwise the host can’t be reached.")
        }
        .alert("This Mac can’t be woken remotely", isPresented: Binding(
            get: { pendingUnwakeableHost != nil },
            set: { if !$0 { pendingUnwakeableHost = nil } }
        )) {
            Button("Wake anyway") {
                let host = pendingUnwakeableHost
                pendingUnwakeableHost = nil
                if let host { wake(host) }
            }
            Button("Cancel", role: .cancel) { pendingUnwakeableHost = nil }
        } message: {
            Text("It’s an Apple-Silicon Mac on Wi-Fi, which macOS can’t wake from sleep over the network without an Apple TV/HomePod acting as a Sleep Proxy.\n\nFix: on the Mac, open Vamp Host → Settings → turn on “Keep Mac Awake & Reachable” (so it never sleeps), or connect it via Ethernet. Tap “Wake anyway” to try regardless (works if a Sleep Proxy is on the network).")
        }
        .alert("Is Vamp Host installed on your Mac?", isPresented: $showInstalledPrompt) {
            Button("Yes, it’s installed") {
                vampHostInstalled = true
                AppHaptics.selection()
            }
            Button("Not yet") {
                promoDismissedThisSession = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Vamp Host is the Mac app this controls. If it’s already installed, we’ll stop showing the download card here. You can still find it in settings.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(headerDot.opacity(0.16))
                    .frame(width: 34, height: 34)
                Circle()
                    .fill(headerDot)
                    .frame(width: 8, height: 8)
                    .shadow(color: headerDot.opacity(0.55), radius: 4)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Vamp Control")
                    .font(.headline)
                    .foregroundColor(PR.fg)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundColor(PR.fg2)
                    .lineLimit(1)
            }

            Spacer()

            headerButton(icon: isScanning ? "dot.radiowaves.left.and.right" : "arrow.clockwise") {
                Task { await scan() }
            }
            .disabled(isScanning)

            headerButton(icon: "slider.horizontal.3") {
                showSettings = true
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .prGlassSurface(
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func headerButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(PR.accent)
                .frame(width: 36, height: 36)
                .background(PR.fg.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PRGlassPressButtonStyle())
    }

    private var headerDot: Color {
        switch sessionCoordinator.phase {
        case .receiving: return PR.accent
        case .error: return PR.err
        default: return connectingHostID != nil ? PR.warn : PR.accent2
        }
    }

    private var headerSubtitle: String {
        if sessionCoordinator.phase == .receiving {
            return sessionCoordinator.connectedHostName ?? "live session"
        }
        let remoteCount = remoteControlHosts.filter(\.isAvailable).count
        let terminalCount = terminalOnlyHosts.filter(\.isAvailable).count
        if remoteCount == 0, terminalCount > 0 {
            return "no remote-control hosts · \(terminalCount) terminal host"
        }
        if terminalCount > 0 {
            return "tap a laptop to connect · \(remoteCount) remote · \(terminalCount) terminal"
        }
        return "tap a laptop to connect · \(remoteCount) online"
    }

    // MARK: Inline stream preview

    /// The "stream starts when connected" view brought over from the old developer mode:
    /// a live mirror inline on the home screen, tappable to go fullscreen, plus fullscreen
    /// and disconnect controls. Only shown while connected and when the option is enabled.
    private var streamPreviewCard: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: PR.r8)
                    .fill(Color.black)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .contentShape(RoundedRectangle(cornerRadius: PR.r8))
                    .onTapGesture { showStream = true }
                    .overlay {
                        if let frame = rendererVM.latestPixelBuffer {
#if canImport(UIKit) && !os(macOS)
                            VideoFrameRendererView(pixelBuffer: frame, renderer: rendererVM)
                                .clipShape(RoundedRectangle(cornerRadius: PR.r8))
#elseif os(macOS)
                            VideoFrameRendererViewMac(pixelBuffer: frame)
                                .clipShape(RoundedRectangle(cornerRadius: PR.r8))
#endif
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "display")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundColor(PR.dim)
                                Text("waiting for frame")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(PR.dim)
                            }
                        }
                    }

                if environment.showsStatsOverlay {
                    MirrorHUD(
                        isDismissible: false,
                        fps: statsVM.fpsText,
                        latency: statsVM.latencyText,
                        bandwidth: statsVM.bitrateText,
                        onClose: nil
                    )
                    .padding(10)
                }
            }

            HStack(spacing: 10) {
                streamPreviewButton(icon: "arrow.up.left.and.arrow.down.right", label: "fullscreen", tint: PR.accent) {
                    showStream = true
                }
                streamPreviewButton(icon: "stop.circle", label: "disconnect", tint: PR.err) {
                    Task { await sessionCoordinator.disconnect() }
                }
            }
        }
        .padding(14)
        .prGlassSurface(
            in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous)
        )
    }

    private func streamPreviewButton(icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .prGlassSurface(
                in: RoundedRectangle(cornerRadius: PR.r8, style: .continuous),
                isInteractive: true
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PRGlassPressButtonStyle())
    }

    // MARK: Laptop tiles

    @ViewBuilder
    private func laptopTile(_ host: DiscoveredHostRow) -> some View {
        if host.isTerminalOnlyHost {
            TerminalOnlyHostTile(
                title: host.title,
                hostname: host.endpoint.hostname,
                isOnline: host.isAvailable
            )
        } else {
            let online = host.isAvailable
            let isConnecting = connectingHostID == host.id
            let isWaking = wakingHostID == host.id
            let wakeable = canWake(host)

            Button {
                tapTile(host)
            } label: {
                VStack(spacing: 12) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 48, weight: .regular))
                            .foregroundColor(online ? PR.accent : PR.dim)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)

                        if host.isSaved {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(PR.accent)
                        }
                    }

                    VStack(spacing: 3) {
                        Text(host.title)
                            .font(.headline)
                            .foregroundColor(HostNameColor.color(for: host.id))
                            .lineLimit(1)
                        Text(host.endpoint.hostname)
                            .font(.caption2.monospaced())
                            .foregroundColor(PR.dim)
                            .lineLimit(1)
                    }

                    tileStatus(host, online: online, isConnecting: isConnecting, isWaking: isWaking, wakeable: wakeable)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .padding(.horizontal, 10)
                .prGlassSurface(
                    in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous),
                    isInteractive: true
                )
                .opacity(online || wakeable ? 1 : 0.6)
                .contentShape(Rectangle())
            }
            .buttonStyle(PRGlassPressButtonStyle())
            .disabled(isConnecting || isWaking)
            .contextMenu {
                if wakeable {
                    Button(isWaking ? "Waking…" : "Wake Host") { wake(host) }
                        .disabled(isWaking)
                }
                if host.isSaved {
                    Button(role: .destructive) {
                        hostsVM.removeSavedHost(host.id)
                    } label: {
                        Label("Remove Saved Host", systemImage: "trash")
                    }
                } else {
                    Button { hostsVM.saveHost(host.id) } label: {
                        Label("Save Host", systemImage: "star")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tileStatus(_ host: DiscoveredHostRow, online: Bool, isConnecting: Bool, isWaking: Bool, wakeable: Bool) -> some View {
        if isConnecting {
            tilePill("connecting…", tint: PR.warn)
        } else if isWaking {
            tilePill("waking…", tint: PR.warn)
        } else if online {
            tilePill(signalLabel(for: host).lowercased(), tint: signalTint(for: host))
        } else if wakeable {
            tilePill("offline · wake", tint: PR.warn)
        } else {
            tilePill("offline", tint: PR.err)
        }
    }

    private func tilePill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12))
            .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
            .clipShape(Capsule())
    }

    // MARK: Connect by IP

    private var connectByIPButton: some View {
        Button {
            showManualConnect = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(PR.accent2)
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("connect by address")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(PR.fg)
                    Text("ip, hostname, or tailscale")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(PR.dim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(PR.dim)
            }
            .padding(14)
            .prGlassSurface(
                in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous),
                isInteractive: true
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PRGlassPressButtonStyle())
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: isScanning ? "dot.radiowaves.left.and.right" : "laptopcomputer.slash")
                .font(.system(size: 40, weight: .regular))
                .foregroundColor(PR.dim)
                .padding(.top, 24)
            Text(isScanning ? "scanning for macs…" : "no macs found yet")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.fg)
            Text("open Vamp Host on your Mac and make sure both devices share the same Wi-Fi, then scan. Away from your network? Tap “connect by address” below and enter the Mac’s Tailscale address.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(PR.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)

            Button {
                Task { await scan() }
            } label: {
                HStack(spacing: 8) {
                    if isScanning {
                        ProgressView().controlSize(.mini).tint(PR.bg)
                    }
                    Text(isScanning ? "scanning…" : "scan network")
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.bg)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(PR.accent)
                .clipShape(RoundedRectangle(cornerRadius: PR.r8))
            }
            .buttonStyle(.plain)
            .disabled(isScanning)

            HowItWorksCard()
                .padding(.top, 4)

            if !vampHostInstalled {
                VampHostPromoCard.direct
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: Home host promo (dismissible)

    /// The Vamp Host download card shown on the home screen below "connect by address".
    /// Dismissible: tapping ✕ asks whether the host is installed; "yes" hides it for good
    /// (`vampHostInstalled`), "not yet" hides it until the next launch.
    private var homeHostPromo: some View {
        VStack(spacing: 12) {
            HStack {
                Text("GET VAMP HOST")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(PR.dim)
                Spacer()
                Button {
                    showInstalledPrompt = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(PR.dim)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(PR.bg2))
                        .overlay(Circle().strokeBorder(PR.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            VampHostPromoCard.direct
        }
    }

    // MARK: Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(PR.err)
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(PR.fg)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button {
                errorText = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(PR.dim)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: PR.r12, style: .continuous)
                .fill(PR.err.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: PR.r12).strokeBorder(PR.err.opacity(0.4)))
        )
    }

    // MARK: Connecting overlay

    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(PR.accent)
                Text("connecting…")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(PR.fg)
                if let host = connectingHost {
                    Text(host.title)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(PR.dim)
                }
                Button("cancel") {
                    connectingHostID = nil
                    Task { await sessionCoordinator.disconnect() }
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.err)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .overlay(Capsule().strokeBorder(PR.err.opacity(0.45), lineWidth: 1))
            }
            .padding(28)
            .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        }
    }

    // MARK: Manual connect sheet

    private var manualConnectSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("connect by address")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(PR.fg)
                Spacer()
                Button("done") { showManualConnect = false }
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(PR.accent)
                    .buttonStyle(.plain)
            }
            .padding(16)
            .background(PR.bg2)
            .overlay(Divider().overlay(PR.border), alignment: .bottom)

            VStack(alignment: .leading, spacing: 12) {
                TextField("192.168.1.42  ·  my-mac.tailnet.ts.net", text: $manualAddress)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(PR.fg)
#if canImport(UIKit) && !os(macOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
#endif
                    .submitLabel(.go)
                    .onSubmit { connectManualAddress() }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(PR.bg2)
                    .overlay(RoundedRectangle(cornerRadius: PR.r8).strokeBorder(PR.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: PR.r8))

                Button {
                    connectManualAddress()
                } label: {
                    Text("connect")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(manualEnabled ? PR.bg : PR.dim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(manualEnabled ? PR.accent : PR.bg2)
                        .overlay(RoundedRectangle(cornerRadius: PR.r8).strokeBorder(manualEnabled ? PR.accent.opacity(0.45) : PR.border))
                        .clipShape(RoundedRectangle(cornerRadius: PR.r8))
                }
                .buttonStyle(.plain)
                .disabled(!manualEnabled)

                Text("default port is 9471 if you don’t specify one. for outside-lan access use the mac’s tailscale address.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(PR.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(16)
        }
        .background(PR.bg.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    private var manualEnabled: Bool {
        !manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Data / actions

    private var hosts: [DiscoveredHostRow] {
        // One tile per physical Mac (collapses old/new LAN IPs + the relay sibling).
        hostsVM.displayHosts
    }

    private var remoteControlHosts: [DiscoveredHostRow] {
        hosts.filter { !$0.isTerminalOnlyHost }
    }

    private var terminalOnlyHosts: [DiscoveredHostRow] {
        hosts.filter(\.isTerminalOnlyHost)
    }

    private var connectingHost: DiscoveredHostRow? {
        guard let id = connectingHostID else { return nil }
        return hosts.first { $0.id == id }
    }

    private func tapTile(_ host: DiscoveredHostRow) {
        guard !host.isTerminalOnlyHost else {
            // A terminal-only host is intentionally visible so the user knows
            // it is installed, but it is not a valid remote-control target.
            // Do not start a doomed WebRTC attempt just to discover that fact.
            AppHaptics.warning()
            return
        }
        if !host.isAvailable && canWake(host) {
            // The host told us a magic packet can't wake it (Apple-Silicon on Wi-Fi). Don't burn a
            // doomed 40s wake attempt — steer the user to "Keep Mac Awake" / Ethernet first, with a
            // "Wake anyway" escape hatch for the case where a Sleep Proxy is actually present.
            if host.endpoint.metadata.magicWakeCapable == false {
                pendingUnwakeableHost = host
                return
            }
            wake(host)
            return
        }
        // Offline and only reachable over Tailscale: a wake signal can't travel over Tailscale,
        // so be honest instead of attempting a doomed connect to a sleeping Mac.
        if isWakeBlockedByRelay(host) {
            showWakeInfo("Can’t wake over Tailscale — a wake signal only travels on the same Wi-Fi. Wake this Mac from its local network, or keep it awake in Vamp Host → Settings.", isError: true)
            return
        }
        // Remind to enable the VPN before attempting a Tailscale/relay address —
        // it won't resolve without Tailscale connected.
        if isRelay(host) && sessionCoordinator.tailscaleVPNStatus == .inactive {
            pendingTailscaleHost = host
            return
        }
        startConnect(host)
    }

    private func isRelay(_ host: DiscoveredHostRow) -> Bool {
        host.endpoint.hostname.contains("ts.net") || host.endpoint.hostname.hasPrefix("100.")
    }

    private func openTailscaleApp() {
        #if canImport(UIKit) && !os(macOS)
        if let url = URL(string: "tailscale://") {
            UIApplication.shared.open(url)
        }
        #endif
    }

    private func startConnect(_ host: DiscoveredHostRow) {
        AppHaptics.impact(.medium)
        errorText = nil
        connectingHostID = host.id
        hostsVM.connect(to: host)
        // Do NOT persist the host here. Saving on tap wrote typo'd / unreachable / rejected
        // attempts to the saved list forever, and — because the tapped row carries no verified
        // fingerprint yet — created a duplicate tile once Bonjour later discovered the same Mac
        // with its real identity. Persistence now happens only after the host's signed answer is
        // verified (HostsListViewModel.recordVerifiedHostIdentity), keyed by the canonical
        // fingerprint, so it can never duplicate or save a failed attempt.
        Task {
            if sessionCoordinator.activeSessionID != nil {
                await sessionCoordinator.disconnect()
            }
            await sessionCoordinator.connect(
                to: host.endpoint,
                qualityPreset: environment.effectivePreferredQualityPreset
            )
        }
    }

    private func connectManualAddress() {
        guard let added = hostsVM.addManualHost(address: manualAddress), added.isAvailable else { return }
        showManualConnect = false
        if isRelay(added) && sessionCoordinator.tailscaleVPNStatus == .inactive {
            pendingTailscaleHost = added
            return
        }
        startConnect(added)
    }

    private func scan() async {
        guard !isScanning else { return }
        isScanning = true
        AppHaptics.selection()
        await hostsVM.refresh()
        isScanning = false
    }

    private func canWake(_ host: DiscoveredHostRow) -> Bool {
        // Wake-on-LAN is an L2 broadcast and Bonjour wake-on-resolve needs the Mac on the local
        // network — neither can traverse Tailscale/relay (100.x / ts.net) or a routed subnet. Only
        // offer wake when we have a LAN target AND the address isn't a Tailscale/relay one.
        !host.isAvailable
            && !isRelay(host)
            && (host.endpoint.metadata.macAddress != nil || host.endpoint.bonjourServiceName != nil)
    }

    /// True when an offline host has a wake target but is only reachable via Tailscale/relay,
    /// so wake can't work over this path (needs the same Wi-Fi).
    private func isWakeBlockedByRelay(_ host: DiscoveredHostRow) -> Bool {
        !host.isAvailable
            && isRelay(host)
            && (host.endpoint.metadata.macAddress != nil || host.endpoint.bonjourServiceName != nil)
    }

    private func wake(_ host: DiscoveredHostRow) {
        let mac = host.endpoint.metadata.macAddress
        let bonjourName = host.endpoint.bonjourServiceName
        guard mac != nil || bonjourName != nil else { return }
        AppHaptics.impact(.rigid)
        wakingHostID = host.id
        let targetHost = host.endpoint.hostname
        Task {
            // WakeCoordinator runs both wake paths, captures errors, and reports what was dispatched.
            let outcome = await WakeCoordinator().wake(
                macAddress: mac,
                bonjourServiceName: bonjourName,
                targetHost: targetHost,
                wakeSupported: host.endpoint.metadata.wakeSupported
            )
            showWakeFeedback(outcome)
            // If nothing was dispatched (error), just refresh once and stop.
            guard !outcome.isError else {
                if wakingHostID == host.id { wakingHostID = nil }
                await hostsVM.refresh()
                return
            }
            // The wake signals were sent — but the Mac takes ~5–30s to come up and re-advertise.
            // Previously we stopped here and the user had to keep tapping; nothing followed through.
            // Poll Bonjour and auto-connect the moment the host reappears. Bounded so a host that
            // can't actually be woken (Apple-Silicon on Wi-Fi without a Sleep Proxy, or "Wake for
            // network access" off) clears the spinner and leaves the honest wake-guidance toast.
            await pollAndConnectAfterWake(host)
        }
    }

    /// After a wake is dispatched, re-scan for the host and connect as soon as it's reachable.
    private func pollAndConnectAfterWake(_ host: DiscoveredHostRow) async {
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            // Bail if the user cancelled (the spinner was cleared elsewhere) or a session started.
            guard wakingHostID == host.id else { return }
            if sessionCoordinator.phase == .receiving { wakingHostID = nil; return }
            await hostsVM.refresh() // refresh() itself waits ~1.5s for Bonjour before returning
            if let live = wokenHostNowOnline(host) {
                wakingHostID = nil
                startConnect(live)
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
        if wakingHostID == host.id {
            wakingHostID = nil
            // The Mac never came back. Give actionable guidance instead of leaving a silent failure —
            // the usual cause is an Apple-Silicon Mac on Wi-Fi that can't be woken remotely.
            withAnimation(.easeOut(duration: 0.2)) {
                wakeFeedback = "Your Mac didn’t respond. Apple-Silicon Macs on Wi-Fi can’t be woken remotely — on the Mac, open Vamp Host → Settings → turn on “Keep Mac Awake & Reachable”, or connect it via Ethernet."
                wakeFeedbackIsError = true
            }
            let shown = wakeFeedback
            Task {
                try? await Task.sleep(for: .seconds(7))
                if wakeFeedback == shown {
                    withAnimation(.easeOut(duration: 0.25)) { wakeFeedback = nil }
                }
            }
        }
    }

    /// The now-online row for the same physical Mac as `host`, if it has come back. Matches on the
    /// stable id, then MAC, then display name, since a fresh Bonjour sighting may carry a different
    /// row id than the offline saved entry we woke.
    private func wokenHostNowOnline(_ host: DiscoveredHostRow) -> DiscoveredHostRow? {
        let mac = host.endpoint.metadata.macAddress?.lowercased()
        let name = host.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return hosts.first { row in
            guard row.isAvailable else { return false }
            if row.id == host.id { return true }
            if let mac, let rowMac = row.endpoint.metadata.macAddress?.lowercased(), mac == rowMac { return true }
            return !name.isEmpty && row.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name
        }
    }

    /// Show a transient wake-guidance toast (used for cases we short-circuit before dispatching).
    private func showWakeInfo(_ message: String, isError: Bool) {
        if isError { AppHaptics.warning() }
        withAnimation(.easeOut(duration: 0.2)) {
            wakeFeedback = message
            wakeFeedbackIsError = isError
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if wakeFeedback == message {
                withAnimation(.easeOut(duration: 0.25)) { wakeFeedback = nil }
            }
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

    private func signalLabel(for host: DiscoveredHostRow) -> String {
        if host.endpoint.hostname.contains("ts.net") || host.endpoint.hostname.hasPrefix("100.") { return "RELAY" }
        return "LAN"
    }

    private func signalTint(for host: DiscoveredHostRow) -> Color {
        if !host.isAvailable { return PR.err }
        return signalLabel(for: host) == "RELAY" ? PR.warn : PR.accent
    }
}

/// A discovered terminal-only host remains visible as an installed companion,
/// but is deliberately not a remote-control button. This prevents a product
/// mismatch from becoming a failed connection flow.
@available(iOS 16.1, *)
private struct TerminalOnlyHostTile: View {
    let title: String
    let hostname: String
    let isOnline: Bool

    private var statusColor: Color { isOnline ? PR.warn : PR.dim }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(statusColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(PR.fg)
                        .lineLimit(1)
                    Text(hostname)
                        .font(.caption2.monospaced())
                        .foregroundColor(PR.dim)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                Text("TERMINAL HOST")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(statusColor)
                    .multilineTextAlignment(.trailing)
            }

            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(isOnline ? "Use Vamp Terminal for terminal tabs" : "Terminal host offline")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(PR.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .leading)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background(PR.bg2.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: PR.r12, style: .continuous)
                .strokeBorder(statusColor.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), terminal-only host")
        .accessibilityHint("Open Vamp Terminal to use terminal tabs")
    }
}

@available(iOS 16.1, *)
private struct MirrorFullscreenStreamView: View {
    let environment: ClientAppEnvironment
    @ObservedObject var rendererVM: VideoRendererViewModel
    @ObservedObject var statsVM: SessionStatsViewModel
    let onClose: () -> Void

    @StateObject private var interactionVM: RemoteInteractionViewModel
    @StateObject private var multiDisplay: MultiDisplayRenderer
    @State private var multiActive = false
    @ObservedObject private var sessionCoordinator: ClientSessionCoordinator
    @ObservedObject private var displayLayoutViewModel: DisplayLayoutViewModel
    @State private var isKeyboardOverlayPresented = false
    @State private var keyboardOverlayBottomPad: CGFloat = 0
    @State private var viewportZoom: CGFloat = 1.0
    @State private var viewportOffset: CGSize = .zero
    /// View-only magnification of the modern Pointer-mode preview (the trackpad still drives the
    /// cursor; this only lets the user zoom in to read fine detail). Kept separate from
    /// `viewportZoom` (which is the absolute-mapping zoom used by Gestures-mode `videoLayer`) so the
    /// two clamp models never cross-contaminate.
    @State private var previewZoom: CGFloat = 1.0
    @State private var previewOffset: CGSize = .zero
    @State private var lastPreviewPinch: CGFloat = 1.0
    @State private var lastPreviewDrag: CGSize = .zero
    @State private var isStatsVisible = true
    @StateObject private var annotationStore = AnnotationOverlayStore()
    @StateObject private var bluetoothInput = BluetoothInputController()
    @StateObject private var audioRenderer = ClientAudioRenderer()
    @StateObject private var pictureInPicture = RemotePictureInPictureController()
    @State private var isControlsHidden = false
    @State private var isBluetoothStatusPresented = false
    @State private var isTerminalModePresented = false
    @State private var unlockPasswordText = ""
    @State private var isUnlockSubmitting = false
    @State private var screenshotStatus = ""
    @State private var showScreenAITools = false
    @StateObject private var terminalSession = ClientTerminalSessionManager()
    @StateObject private var clipboardSync = ClientClipboardSyncManager()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let screenshotService = SessionScreenshotService()
    /// "classic" (default) keeps this view's existing fullscreen UI; "modern" uses the portrait trackpad layout.
    @AppStorage("client.ui.streamingUITheme") private var streamingUITheme = "classic"
    @State private var modernInputMode: ModernInputMode = .pointer
    private enum ModernInputMode { case pointer, gestures }

    init(
        environment: ClientAppEnvironment,
        rendererVM: VideoRendererViewModel,
        statsVM: SessionStatsViewModel,
        onClose: @escaping () -> Void
    ) {
        self.environment = environment
        self.rendererVM = rendererVM
        self.statsVM = statsVM
        self.onClose = onClose
        self.sessionCoordinator = environment.sessionCoordinator
        self.displayLayoutViewModel = environment.displayLayoutViewModel
        _interactionVM = StateObject(
            wrappedValue: RemoteInteractionViewModel(
                webRTCSessionManager: environment.webRTCSessionManager,
                displayLayoutViewModel: environment.displayLayoutViewModel
            )
        )
        _multiDisplay = StateObject(wrappedValue: MultiDisplayRenderer(
            webRTCSessionManager: environment.webRTCSessionManager, primary: rendererVM
        ))
    }

    // MARK: - Multi-display (Tier 4a)

    // Anchored at the TOP, clear of the bottom session control bar (which is its own
    // `.overlay(alignment: .bottom)`). Two bottom overlays previously stacked, so this one
    // sat on top of the controls and ate their taps.
    @ViewBuilder private var multiDisplayBar: some View {
        if displayLayoutViewModel.displays.count > 1 {
            VStack(spacing: 8) {
                Button(action: toggleMultiDisplay) {
                    Label(multiActive ? "Showing All Displays" : "Show All Displays",
                          systemImage: multiActive ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                if multiActive {
                    MultiDisplayThumbnailStrip(multi: multiDisplay, onFocus: focusDisplay)
                }
            }
            .padding(.top, 52)
            .opacity(isControlsHidden ? 0 : 1)
            .allowsHitTesting(!isControlsHidden)
        }
    }

    private var currentPrimaryDisplayID: String? {
        displayLayoutViewModel.hostSelectedDisplayID
            ?? displayLayoutViewModel.primaryDisplay?.id
            ?? displayLayoutViewModel.displays.first?.id
    }

    private func toggleMultiDisplay() {
        let displays = displayLayoutViewModel.displays
        guard displays.count > 1, let primary = currentPrimaryDisplayID else { return }
        if multiActive {
            multiActive = false
            multiDisplay.setActive(count: 1)
            sessionCoordinator.setStreamedDisplays([primary])
        } else {
            let ordered = [primary] + displays.map(\.id).filter { $0 != primary }
            sessionCoordinator.setStreamedDisplays(ordered)
            multiDisplay.setActive(count: ordered.count)
            multiActive = true
        }
    }

    private func focusDisplay(_ wireID: UInt8) {
        multiDisplay.focus(wireID)
        sessionCoordinator.requestKeyframeRefresh(reason: "multi-display focus")
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if usesModernTheme(proxy.size) {
                    modernStreamContent(viewSize: proxy.size, safeAreaInsets: proxy.safeAreaInsets)
                } else {
                    classicStreamContent(viewSize: proxy.size, safeAreaInsets: proxy.safeAreaInsets)
                }
            }
            .overlay(alignment: .top) { multiDisplayBar }
            .onDisappear { multiDisplay.stopAll() }
            .onAppear {
                interactionVM.updateViewSize(DesktopSize(width: proxy.size.width, height: proxy.size.height))
            }
            .onChangeCompat(of: proxy.size) { newSize in
                interactionVM.updateViewSize(DesktopSize(width: newSize.width, height: newSize.height))
                // A rotation changes the fitted-video box, invalidating any pan/zoom offset that was
                // clamped against the old dimensions. Reset both zoom models so the picture
                // re-centers cleanly rather than rendering off-center until the user pinches again.
                resetModernZoom()
                viewportOffset = clampedViewportOffset(viewportOffset, zoom: viewportZoom, in: newSize)
                // A rotation flips the layout branch (and, with the modern theme, the video view's
                // identity), which dismantles the AVSampleBufferDisplayLayer and starts it empty.
                // The video channel is unreliable/unordered, so without nudging the host we'd show
                // black until the next natural keyframe. Request one proactively while streaming.
                if sessionCoordinator.phase == .receiving {
                    sessionCoordinator.requestKeyframeRefresh(reason: "orientation change")
                }
            }
        }
        .task {
            rendererVM.onNeedsKeyframe = { [weak sessionCoordinator = sessionCoordinator] in
                sessionCoordinator?.requestKeyframeRefresh(reason: "decode error")
            }
            multiDisplay.onNeedsKeyframe = { [weak sessionCoordinator = sessionCoordinator] in
                sessionCoordinator?.requestKeyframeRefresh(reason: "secondary display keyframe")
            }
            if !rendererVM.isReceiving {
                rendererVM.startReceiving()
            }
            interactionVM.sessionID = sessionCoordinator.activeSessionID
            interactionVM.sessionMode = effectiveSessionMode
            interactionVM.pointerSensitivity = bluetoothInput.mouseSensitivity
            interactionVM.updateForConnectionState(sessionCoordinator.phase == .receiving ? .connected : .disconnected)
            bluetoothInput.sink = interactionVM
            bluetoothInput.startObserving()
            audioRenderer.start()
            sessionCoordinator.onAudioFrame = { [weak audioRenderer = audioRenderer] msg in audioRenderer?.receive(msg) }
            if let sessionID = sessionCoordinator.activeSessionID {
                terminalSession.activate(sessionID: sessionID, send: { [weak sessionCoordinator = sessionCoordinator] env in
                    try sessionCoordinator?.sendTerminalEnvelope(env)
                })
                clipboardSync.activate(sessionID: sessionID, send: { [weak sessionCoordinator = sessionCoordinator] env in
                    sessionCoordinator?.sendClipboardEnvelope(env)
                })
            }
            sessionCoordinator.onTerminalReady = { [weak terminalSession = terminalSession] msg in terminalSession?.receiveReady(msg) }
            sessionCoordinator.onTerminalOutput = { [weak terminalSession = terminalSession] msg in terminalSession?.receiveOutput(msg) }
            sessionCoordinator.onTerminalClose = { [weak terminalSession = terminalSession] msg in terminalSession?.receiveClose(msg) }
            sessionCoordinator.onClipboardSync = { [weak clipboardSync = clipboardSync] msg in clipboardSync?.receive(msg) }
            for await state in environment.webRTCSessionManager.connectionStateUpdates() {
                interactionVM.updateForConnectionState(state)
            }
        }
        .onChangeCompat(of: sessionCoordinator.activeSessionID) { sessionID in
            interactionVM.sessionID = sessionID
            if let sessionID {
                terminalSession.activate(sessionID: sessionID, send: { [weak sessionCoordinator = sessionCoordinator] env in
                    try sessionCoordinator?.sendTerminalEnvelope(env)
                })
                clipboardSync.activate(sessionID: sessionID, send: { [weak sessionCoordinator = sessionCoordinator] env in
                    sessionCoordinator?.sendClipboardEnvelope(env)
                })
            } else {
                terminalSession.deactivate()
                clipboardSync.deactivate()
            }
        }
        .onChangeCompat(of: sessionCoordinator.sessionMode) { _ in
            interactionVM.sessionMode = effectiveSessionMode
        }
        .onChangeCompat(of: environment.prefersViewOnly) { _ in
            interactionVM.sessionMode = effectiveSessionMode
        }
        .onChangeCompat(of: bluetoothInput.mouseSensitivity) { newValue in
            interactionVM.pointerSensitivity = newValue
        }
        .onChangeCompat(of: rendererVM.frameSize) { frameSize in
            // New frame arriving after a display switch — clear the
            // `isSwitchingDisplay` flag so the switcher button re-enables.
            // Without this, the button greys out after the first switch and
            // can never return to the original display.
            guard frameSize != nil else { return }
            displayLayoutViewModel.noteFirstFrameAfterSwitch()
        }
        .onDisappear {
            isKeyboardOverlayPresented = false
            isStatsVisible = true
            isControlsHidden = false
            bluetoothInput.stopObserving()
            audioRenderer.stop()
            sessionCoordinator.onAudioFrame = nil
            terminalSession.deactivate()
            clipboardSync.deactivate()
            sessionCoordinator.onTerminalOutput = nil
            sessionCoordinator.onTerminalReady = nil
            sessionCoordinator.onTerminalClose = nil
            sessionCoordinator.onClipboardSync = nil
        }
        .prFullscreenCompat(isPresented: $isTerminalModePresented) {
            TerminalModeView(session: terminalSession)
        }
        .sheet(isPresented: $showScreenAITools) {
            ScreenAIToolsView(
                frameProvider: { rendererVM.latestPixelBuffer },
                onSendText: { interactionVM.sendText($0) },
                onSendKey: { keyCode in
                    interactionVM.sendKey(keyCode: keyCode, action: .down)
                    interactionVM.sendKey(keyCode: keyCode, action: .up)
                }
            )
        }
#if canImport(UIKit) && !os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.keyboardWillChangeFrameNotification)) { notif in
            guard let end = (notif.userInfo?[UIApplication.keyboardFrameEndUserInfoKey] as? CGRect) else { return }
            let screenH = UIScreen.main.bounds.height
            let kbH = max(0, screenH - end.origin.y)
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardOverlayBottomPad = kbH
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.22)) {
                keyboardOverlayBottomPad = 0
            }
        }
#endif
    }

    /// The modern theme now handles BOTH orientations (a dedicated landscape layout lives in
    /// `modernLandscapeChrome`); only the theme preference gates it. Keeping rotation inside the
    /// modern path — rather than swapping to the classic layout in landscape — also avoids a harder
    /// view-identity swap of the video layer on every rotation.
    private func usesModernTheme(_ viewSize: CGSize) -> Bool {
        streamingUITheme == "modern"
    }

    /// True hardware safe-area insets, read straight from the active window.
    ///
    /// This view is presented with `.ignoresSafeArea()` so the classic path can run the video
    /// edge-to-edge — which means the body's `GeometryReader` reports `safeAreaInsets == .zero`.
    /// The modern chrome still has to clear the Dynamic Island and the home indicator, so it reads
    /// the real insets here instead of trusting the zeroed proxy values.
    private var deviceSafeAreaInsets: EdgeInsets {
#if canImport(UIKit) && !os(macOS)
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        if let i = window?.safeAreaInsets {
            return EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
        }
#endif
        return EdgeInsets()
    }

    // MARK: - Classic content (verbatim — unchanged behavior)

    @ViewBuilder
    private func classicStreamContent(viewSize: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            videoLayer(viewSize: viewSize)

            if sessionCoordinator.hostLockState == .lockedOrLoginWindow {
                hostLockedOverlay
            }
        }
        .overlay(alignment: .bottom) {
            fullscreenBottomChrome(bottomInset: safeAreaInsets.bottom)
        }
        .overlay(alignment: .bottom) {
            if isKeyboardOverlayPresented {
                KeyboardOverlayView(
                    interactionVM: interactionVM,
                    onDismiss: { isKeyboardOverlayPresented = false }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, keyboardOverlayBottomPad)
            }
        }
    }

    // MARK: - Modern theme (portrait trackpad layout)

    private static let modernGreen = Color(red: 0.20, green: 0.84, blue: 0.45)
    private static let modernPanel = Color(red: 0.10, green: 0.11, blue: 0.12)

    @ViewBuilder
    private func modernStreamContent(viewSize: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        let isLandscape = viewSize.width > viewSize.height
        ZStack {
            Color.black.ignoresSafeArea()

            // Gestures mode: the video is the full-bleed, interactive layer (correct absolute
            // mapping) in BOTH orientations. Keep its taps from leaking through while the keyboard
            // overlay is up, and give the pinch-zoom the same interactive spring the classic dev
            // view uses — applied at this modern call site only, so the shared `videoLayer` stays
            // verbatim for the classic path.
            if modernInputMode == .gestures {
                videoLayer(viewSize: viewSize)
                    .allowsHitTesting(!isKeyboardOverlayPresented)
                    .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.9), value: viewportZoom)
                    .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.9), value: viewportOffset)
            }

            if isLandscape {
                modernLandscapeChrome(viewSize: viewSize, safeAreaInsets: safeAreaInsets)
            } else {
                modernPortraitChrome(viewSize: viewSize, safeAreaInsets: safeAreaInsets)
            }

            // Stats HUD parity with classic mode: the modern "More" menu Stats toggle previously
            // had no on-screen effect because the modern path never rendered MirrorHUD. Float it
            // top-trailing, below the top pill.
            if environment.showsStatsOverlay {
                VStack {
                    HStack {
                        Spacer()
                        MirrorHUD(
                            isDismissible: true,
                            fps: statsVM.fpsText,
                            latency: statsVM.latencyText,
                            bandwidth: statsVM.bitrateText,
                            onClose: { environment.showsStatsOverlay = false }
                        )
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, max(max(safeAreaInsets.top, deviceSafeAreaInsets.top), 12) + 70)
            }

            if sessionCoordinator.hostLockState == .lockedOrLoginWindow {
                hostLockedOverlay
            }
        }
        // The stream chrome reads as a dark "control deck" regardless of the system light/white mode.
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottom) {
            if isKeyboardOverlayPresented {
                KeyboardOverlayView(
                    interactionVM: interactionVM,
                    onDismiss: { isKeyboardOverlayPresented = false }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, keyboardOverlayBottomPad)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isKeyboardOverlayPresented)
        .animation(.easeInOut(duration: 0.2), value: modernInputMode)
    }

    /// Portrait modern layout: a vertical control deck — top pill, the display (an aspect-fit
    /// preview + trackpad in Pointer mode; the full-bleed `videoLayer` underneath in Gestures
    /// mode), then the bottom bar.
    @ViewBuilder
    private func modernPortraitChrome(viewSize: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        VStack(spacing: 12) {
            modernTopPill()
                .padding(.horizontal, 14)
                .padding(.top, max(max(safeAreaInsets.top, deviceSafeAreaInsets.top), 12))

            if modernInputMode == .pointer {
                // Let the video own all the space between the pill and the trackpad. modernVideo()
                // now centers a correctly-fitted picture, so filling the region maximizes the
                // picture instead of stranding it in a half-height band with empty space above.
                modernVideo()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)

                if !isKeyboardOverlayPresented {
                    TrackpadSurfaceView(interactionVM: interactionVM)
                        .frame(height: modernTrackpadHeight(viewSize))
                        .padding(.horizontal, 14)
                        .transition(.opacity)
                }
            } else {
                Spacer(minLength: 0)
            }

            if !isKeyboardOverlayPresented {
                modernBottomBar()
                    .padding(.horizontal, 14)
                    .padding(.bottom, max(max(safeAreaInsets.bottom, deviceSafeAreaInsets.bottom), 10))
            }
        }
    }

    /// Dedicated landscape modern layout: the chrome floats over the display rather than stacking.
    /// Pointer mode shows the aspect-fit preview filling the screen with a floating trackpad panel
    /// in the bottom-trailing corner; Gestures mode uses the full-bleed `videoLayer` rendered behind
    /// this chrome. The leading-edge notch safe-area is respected for the floating controls.
    @ViewBuilder
    private func modernLandscapeChrome(viewSize: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        let topPad = max(max(safeAreaInsets.top, deviceSafeAreaInsets.top), 8)
        let bottomPad = max(max(safeAreaInsets.bottom, deviceSafeAreaInsets.bottom), 10)
        let leadingPad = max(safeAreaInsets.leading, 16)
        let trailingPad = max(safeAreaInsets.trailing, 16)
        ZStack {
            if modernInputMode == .pointer {
                // Fill the whole region (minus safe areas) and let the floating pill / bottom bar /
                // trackpad overlay it — modernVideo() centers the largest fitted picture, so this
                // yields a centered video with symmetric margins instead of the small upper-left
                // picture + big black field the fixed +60/+56 pixel pads produced.
                modernVideo()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, topPad)
                    .padding(.bottom, bottomPad)
                    .padding(.leading, leadingPad)
                    .padding(.trailing, trailingPad)
            }

            // Floating top pill (cleared from the top and the leading/trailing notch).
            VStack {
                modernTopPill()
                    .frame(maxWidth: 540)
                    .padding(.top, topPad)
                    .padding(.leading, leadingPad)
                    .padding(.trailing, trailingPad)
                Spacer()
            }

            // Floating trackpad panel (Pointer only), bottom-trailing, above the bottom bar.
            if modernInputMode == .pointer, !isKeyboardOverlayPresented {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        TrackpadSurfaceView(interactionVM: interactionVM)
                            .frame(width: min(viewSize.width * 0.42, 460),
                                   height: min(viewSize.height * 0.55, 230))
                            .padding(.trailing, trailingPad)
                            .padding(.bottom, bottomPad + 58)
                            .transition(.opacity)
                    }
                }
            }

            // Floating bottom bar.
            if !isKeyboardOverlayPresented {
                VStack {
                    Spacer()
                    modernBottomBar()
                        .frame(maxWidth: 540)
                        .padding(.leading, leadingPad)
                        .padding(.trailing, trailingPad)
                        .padding(.bottom, bottomPad)
                }
            }
        }
    }

    @ViewBuilder
    private func modernVideo() -> some View {
#if canImport(UIKit) && !os(macOS)
        GeometryReader { geo in
            // Size the video to the LARGEST rectangle of the host's aspect ratio that fits the box,
            // then center it. The old code aspect-fit the renderer and THEN forced a full-box
            // `.frame(geo.size)`, which re-inflated the layout footprint so every pixel of the box
            // outside the fitted picture rendered as black filler — the large empty space seen in
            // both orientations. Now the bordered picture hugs the real video and the only black is
            // the ZStack background behind it.
            let host = rendererVM.frameSize.map {
                CGSize(width: max(CGFloat($0.width), 1), height: max(CGFloat($0.height), 1))
            } ?? CGSize(width: 16, height: 10)
            let scale = min(geo.size.width / host.width, geo.size.height / host.height)
            let fitted = CGSize(width: max(host.width * scale, 1), height: max(host.height * scale, 1))
            VideoFrameRendererView(
                pixelBuffer: rendererVM.latestPixelBuffer,
                displayMode: interactionVM.displayMode,
                renderer: rendererVM,
                pictureInPicture: pictureInPicture
            )
                .aspectRatio(host, contentMode: .fit)
                .frame(width: fitted.width, height: fitted.height)
                .scaleEffect(previewZoom, anchor: .center)
                .offset(previewOffset)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .contentShape(Rectangle())
                // View-only pinch-zoom + pan of the Pointer-mode preview so the user can read fine
                // detail. The trackpad still drives the cursor; this never touches `viewportZoom`
                // (Gestures-mode absolute mapping) or sends input. Clamp against the fitted picture.
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let delta = value / lastPreviewPinch
                                lastPreviewPinch = value
                                previewZoom = min(max(previewZoom * delta, 1.0), 4.0)
                                previewOffset = clampedPreviewOffset(previewOffset, zoom: previewZoom, in: fitted)
                            }
                            .onEnded { _ in lastPreviewPinch = 1.0 },
                        DragGesture()
                            .onChanged { g in
                                guard previewZoom > 1.0 else { return }
                                let dx = g.translation.width - lastPreviewDrag.width
                                let dy = g.translation.height - lastPreviewDrag.height
                                lastPreviewDrag = g.translation
                                previewOffset = clampedPreviewOffset(
                                    CGSize(width: previewOffset.width + dx, height: previewOffset.height + dy),
                                    zoom: previewZoom, in: fitted
                                )
                            }
                            .onEnded { _ in lastPreviewDrag = .zero }
                    )
                )
                .frame(width: geo.size.width, height: geo.size.height) // center the fitted picture
        }
#else
        Color.black
#endif
    }

    /// Clamp the Pointer-preview pan so the magnified content can't be dragged off its own box.
    private func clampedPreviewOffset(_ proposed: CGSize, zoom: CGFloat, in size: CGSize) -> CGSize {
        guard zoom > 1.0 else { return .zero }
        let maxX = (size.width * (zoom - 1)) / 2
        let maxY = (size.height * (zoom - 1)) / 2
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }

    /// Reset both zoom models (Gestures absolute-map zoom and Pointer-preview zoom) to identity.
    private func resetModernZoom() {
        viewportZoom = 1.0
        viewportOffset = .zero
        previewZoom = 1.0
        previewOffset = .zero
        lastPreviewPinch = 1.0
        lastPreviewDrag = .zero
    }

    private func modernTrackpadHeight(_ viewSize: CGSize) -> CGFloat {
        max(160, min(viewSize.height * 0.30, 290))
    }

    @ViewBuilder
    private func modernTopPill() -> some View {
        HStack(spacing: 4) {
            modernModeButton(icon: "keyboard", label: "Keyboard",
                             active: isKeyboardOverlayPresented) {
                isKeyboardOverlayPresented.toggle()
            }
            modernModeButton(icon: "cursorarrow", label: "Pointer",
                             active: modernInputMode == .pointer && !isKeyboardOverlayPresented) {
                isKeyboardOverlayPresented = false
                // Don't carry a zoom from one mode into the other (different clamp models).
                resetModernZoom()
                modernInputMode = .pointer
            }
            modernModeButton(icon: "hand.draw", label: "Gestures",
                             active: modernInputMode == .gestures && !isKeyboardOverlayPresented) {
                isKeyboardOverlayPresented = false
                resetModernZoom()
                modernInputMode = .gestures
            }
            modernMoreButton()
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Self.modernPanel.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }

    private func modernModeButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            AppHaptics.selection()
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18, weight: .regular))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(active ? Self.modernGreen : Color.white.opacity(0.82))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(active ? Self.modernGreen.opacity(0.15) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func modernMoreButton() -> some View {
        Menu {
            Button { AppHaptics.selection(); captureScreenshot() } label: { Label("Screenshot", systemImage: "camera") }
            Button { AppHaptics.selection(); isBluetoothStatusPresented = true } label: { Label("Bluetooth", systemImage: "magicmouse") }
            Button { AppHaptics.selection(); annotationStore.isVisible.toggle() } label: {
                Label(annotationStore.isVisible ? "Hide Markup" : "Annotate", systemImage: annotationStore.isVisible ? "pencil.slash" : "pencil.tip")
            }
            Button { AppHaptics.selection(); isTerminalModePresented = true } label: { Label("Terminal", systemImage: "terminal.fill") }
            Button { AppHaptics.selection(); showScreenAITools = true } label: { Label("Screen AI", systemImage: "sparkles") }
            Button { AppHaptics.selection(); clipboardSync.pushToHost() } label: { Label("Send Clipboard to Mac", systemImage: "doc.on.clipboard") }
            Button { AppHaptics.selection(); clipboardSync.requestFromHost() } label: {
                Label(clipboardSync.isSyncing ? "Getting Clipboard…" : "Get Clipboard from Mac", systemImage: "arrow.down.doc")
            }
            Button { AppHaptics.selection(); sendCommandTab() } label: {
                Label("Switch Remote App (⌘Tab)", systemImage: "command")
            }
            Button { AppHaptics.selection(); pictureInPicture.toggle() } label: {
                Label(
                    pictureInPicture.isActive ? "Stop Picture in Picture" : "Picture in Picture",
                    systemImage: pictureInPicture.isActive ? "pip.exit" : "pip.enter"
                )
            }
            Menu("Display Size") {
                displayModeButton(.fitDisplay, label: "Fit Display", systemImage: "rectangle.arrowtriangle.2.inward")
                displayModeButton(.fillScreen, label: "Fill Screen", systemImage: "rectangle.arrowtriangle.2.outward")
            }
            if displayLayoutViewModel.displays.count > 1 {
                Menu("Switch Display") {
                    ForEach(displayLayoutViewModel.displays) { display in
                        Button { AppHaptics.selection(); requestDisplaySwitch(to: display.id) } label: {
                            Label(display.name, systemImage: displayLayoutViewModel.selectedDisplayID == display.id ? "checkmark" : "display")
                        }
                    }
                }
            }
            Button { AppHaptics.selection(); environment.showsStatsOverlay.toggle() } label: {
                Label(environment.showsStatsOverlay ? "Hide Stats" : "Stats", systemImage: "chart.bar")
            }
            Divider()
            Button(role: .destructive) { AppHaptics.selection(); onClose() } label: { Label("Disconnect", systemImage: "xmark.circle") }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .regular))
                Text("More").font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(Color.white.opacity(0.82))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func modernBottomBar() -> some View {
        HStack(spacing: 6) {
            // Reset-zoom affordance — appears only when zoomed (either zoom model).
            if viewportZoom > 1.05 || previewZoom > 1.05 {
                modernBarButton(icon: "arrow.down.right.and.arrow.up.left") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { resetModernZoom() }
                }
            }
            modernBarButton(icon: "camera") { captureScreenshot() }
            modernBarButton(
                icon: pictureInPicture.isActive ? "pip.exit" : "pip.enter",
                active: pictureInPicture.isActive
            ) { pictureInPicture.toggle() }
            modernBarButton(
                icon: bluetoothInput.isMouseConnected || bluetoothInput.isKeyboardConnected ? "magicmouse.fill" : "magicmouse",
                active: bluetoothInput.isMouseConnected || bluetoothInput.isKeyboardConnected
            ) { isBluetoothStatusPresented = true }
            modernBarButton(
                icon: audioRenderer.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                active: audioRenderer.isActive && !audioRenderer.isMuted
            ) { audioRenderer.isMuted.toggle() }
            modernBarButton(
                icon: "display",
                active: displayLayoutViewModel.isSwitchingDisplay
            ) {
                if displayLayoutViewModel.displays.count > 1 { cycleModernDisplay() }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Self.modernPanel.opacity(0.94))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    private func modernBarButton(icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            AppHaptics.selection()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(active ? Self.modernGreen : Color.white.opacity(0.82))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cycleModernDisplay() {
        let displays = displayLayoutViewModel.displays
        guard displays.count > 1 else { return }
        // Mirror the classic switcher's in-flight guard so a second tap can't race the switch,
        // and route through requestDisplaySwitch (which messages the host + drives the switching
        // banner) rather than selectDisplay alone, which only updates local mapping.
        guard !displayLayoutViewModel.isSwitchingDisplay else { return }
        if let currentID = displayLayoutViewModel.selectedDisplayID,
           let idx = displays.firstIndex(where: { $0.id == currentID }) {
            requestDisplaySwitch(to: displays[(idx + 1) % displays.count].id)
        } else if let first = displays.first {
            requestDisplaySwitch(to: first.id)
        }
    }

    private var effectiveSessionMode: SessionControlMode {
        environment.prefersViewOnly || sessionCoordinator.sessionMode == .viewOnly ? .viewOnly : .fullControl
    }

    private var hostLockedOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                Text("Mac is locked")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("Enter your Mac login password to unlock remotely.")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                SecureField("Password", text: $unlockPasswordText)
                    .font(.system(size: 15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .frame(maxWidth: 280)
                    .onSubmit { submitUnlock() }
                HStack(spacing: 12) {
                    Button("Unlock") { submitUnlock() }
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            Color.accentColor.opacity(unlockPasswordText.isEmpty || isUnlockSubmitting ? 0.4 : 1.0),
                            in: Capsule()
                        )
                        .disabled(unlockPasswordText.isEmpty || isUnlockSubmitting)
                    Button("Refresh") { sessionCoordinator.sendConnectionProbe() }
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(32)
        }
        .onChangeCompat(of: sessionCoordinator.hostLockState) { newState in
            if newState == .unlockedActiveSession {
                unlockPasswordText = ""
                isUnlockSubmitting = false
            }
        }
    }

    private func submitUnlock() {
        guard !unlockPasswordText.isEmpty, !isUnlockSubmitting else { return }
        isUnlockSubmitting = true
        let password = unlockPasswordText
        unlockPasswordText = ""
        sessionCoordinator.sendUnlockPassword(password)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            isUnlockSubmitting = false
        }
    }

    private func captureScreenshot() {
        guard let pixelBuffer = rendererVM.latestPixelBuffer else {
            screenshotStatus = "no frame"
            return
        }
        do {
            let url = try screenshotService.capture(pixelBuffer: pixelBuffer)
            screenshotStatus = "saved: \(url.lastPathComponent)"
        } catch {
            screenshotStatus = "failed"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { screenshotStatus = "" }
    }

    @ViewBuilder
    private func videoLayer(viewSize: CGSize) -> some View {
#if canImport(UIKit) && !os(macOS)
        ZStack {
            VideoFrameRendererView(
                pixelBuffer: rendererVM.latestPixelBuffer,
                displayMode: interactionVM.displayMode,
                renderer: rendererVM,
                pictureInPicture: pictureInPicture
            )
                .scaleEffect(viewportZoom, anchor: .center)
                .offset(viewportOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            MirrorFullscreenGestureView(
                viewportZoom: viewportZoom,
                viewportOffset: viewportOffset,
                viewSize: viewSize,
                onTap: { pt in
                    interactionVM.handleTap(at: DesktopPoint(x: pt.x, y: pt.y))
                },
                onDoubleTap: { pt in
                    interactionVM.handleDoubleTap(at: DesktopPoint(x: pt.x, y: pt.y))
                },
                onRightClick: { pt in
                    interactionVM.handleTwoFingerTap(at: DesktopPoint(x: pt.x, y: pt.y))
                },
                onMiddleClick: { pt in
                    interactionVM.handleThreeFingerTap(at: DesktopPoint(x: pt.x, y: pt.y))
                },
                onDragChanged: { delta, loc in
                    interactionVM.handleDragChanged(
                        translation: DesktopPoint(x: delta.width, y: delta.height),
                        currentViewPoint: DesktopPoint(x: loc.x, y: loc.y)
                    )
                },
                onDragEnded: {
                    interactionVM.handleDragEnded()
                },
                onScroll: { dx, dy in
                    interactionVM.handleScroll(deltaX: dx, deltaY: dy)
                },
                onViewportPan: { delta in
                    let newOffset = CGSize(
                        width: viewportOffset.width + delta.width,
                        height: viewportOffset.height + delta.height
                    )
                    viewportOffset = clampedViewportOffset(newOffset, zoom: viewportZoom, in: viewSize)
                },
                onPinchChanged: { scale, focalPoint in
                    let oldZoom = viewportZoom
                    let newZoom = min(max(viewportZoom * scale, 1.0), 5.0)
                    viewportZoom = newZoom
                    if newZoom <= 1.0 {
                        viewportOffset = .zero
                    } else {
                        // Preserve the remote pixel under the user's fingers instead
                        // of zooming around the center of the phone.
                        let ratio = newZoom / max(oldZoom, 0.001)
                        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                        let anchoredOffset = CGSize(
                            width: viewportOffset.width
                                + (1 - ratio) * (focalPoint.x - center.x - viewportOffset.width),
                            height: viewportOffset.height
                                + (1 - ratio) * (focalPoint.y - center.y - viewportOffset.height)
                        )
                        viewportOffset = clampedViewportOffset(anchoredOffset, zoom: newZoom, in: viewSize)
                    }
                },
                onPinchEnded: {
                    if viewportZoom < 1.15 {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                            viewportZoom = 1.0
                            viewportOffset = .zero
                        }
                    }
                },
                onLongPress: { pt in
                    interactionVM.toggleDragLock(at: DesktopPoint(x: pt.x, y: pt.y))
                },
                onPointerDelta: { delta in
                    interactionVM.sendRelativePointerMove(
                        deltaX: Double(delta.width) * bluetoothInput.mouseSensitivity,
                        deltaY: Double(delta.height) * bluetoothInput.mouseSensitivity
                    )
                }
            )

            if annotationStore.isVisible {
                AnnotationCanvasOverlay(store: annotationStore)
            }
        }
#else
        MirrorVideoPlaceholder(
            frameSize: nil,
            mapper: interactionVM.mapper
        )
#endif
    }

    @ViewBuilder
    private func fullscreenBottomChrome(bottomInset: CGFloat) -> some View {
        if isControlsHidden {
            // Minimal reveal hint: small eye pill anchored to bottom-trailing
            HStack {
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        isControlsHidden = false
                    }
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.22), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, max(bottomInset, 0) + 14)
        } else {
            VStack(spacing: 10) {
                if environment.showsStatsOverlay && isStatsVisible {
                    HStack {
                        Spacer()
                        MirrorHUD(
                            isDismissible: true,
                            fps: statsVM.fpsText,
                            latency: statsVM.latencyText,
                            bandwidth: statsVM.bitrateText,
                            onClose: {
                                isStatsVisible = false
                            }
                        )
                    }
                }

                chromePill
            }
            .padding(.horizontal, 14)
            .padding(.bottom, max(bottomInset, 0) + 12)
            .sheet(isPresented: $isBluetoothStatusPresented) {
                BluetoothInputStatusView(
                    controller: bluetoothInput,
                    onDismiss: { isBluetoothStatusPresented = false }
                )
            }
        }
    }

    private var chromePill: some View {
        HStack(spacing: 0) {
            chromeIconButton(
                systemName: "xmark",
                isDestructive: true
            ) {
                onClose()
            }

            let bleActive = bluetoothInput.isKeyboardConnected || bluetoothInput.isMouseConnected
            chromeIconButton(
                systemName: bleActive ? "magicmouse.fill" : "magicmouse",
                isActive: bleActive,
                accent: Color(red: 0.204, green: 0.827, blue: 0.612)
            ) {
                AppHaptics.selection()
                isBluetoothStatusPresented = true
            }

            chromeIconButton(
                systemName: annotationStore.isVisible ? "pencil.slash" : "pencil.tip",
                isActive: annotationStore.isVisible,
                accent: PR.accent
            ) {
                AppHaptics.selection()
                annotationStore.isVisible.toggle()
            }

            if displayVMRequiresKeyboard {
                chromeIconButton(
                    systemName: isKeyboardOverlayPresented ? "keyboard.chevron.compact.down" : "keyboard",
                    isActive: isKeyboardOverlayPresented,
                    accent: PR.accent
                ) {
                    AppHaptics.selection()
                    isKeyboardOverlayPresented.toggle()
                }
            }

            if displayLayoutViewModel.displays.count > 1 {
                Menu {
                    ForEach(displayLayoutViewModel.displays) { display in
                        Button {
                            AppHaptics.selection()
                            requestDisplaySwitch(to: display.id)
                        } label: {
                            let isCurrent = displayLayoutViewModel.selectedDisplayID == display.id
                            let label = "\(display.name) — \(Int(display.pixelSize.width))×\(Int(display.pixelSize.height))"
                            if isCurrent {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                        .disabled(displayLayoutViewModel.selectedDisplayID == display.id)
                    }
                } label: {
                    chromeIconLabel(
                        systemName: displayLayoutViewModel.isSwitchingDisplay ? "rectangle.on.rectangle.angled" : "display.2",
                        isActive: false,
                        isDimmed: displayLayoutViewModel.isSwitchingDisplay,
                        accent: PR.accent,
                        isDestructive: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(displayLayoutViewModel.isSwitchingDisplay)
            }

            chromeIconButton(
                systemName: "terminal.fill",
                accent: PR.accent
            ) {
                AppHaptics.selection()
                isTerminalModePresented = true
            }

            chromeIconButton(
                systemName: audioRenderer.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                isDimmed: audioRenderer.isMuted
            ) {
                AppHaptics.selection()
                audioRenderer.isMuted.toggle()
            }

            chromeIconButton(
                systemName: pictureInPicture.isActive ? "pip.exit" : "pip.enter",
                isActive: pictureInPicture.isActive,
                accent: PR.accent
            ) {
                AppHaptics.selection()
                pictureInPicture.toggle()
            }

            Menu {
                displayModeButton(.fitDisplay, label: "Fit Display", systemImage: "rectangle.arrowtriangle.2.inward")
                displayModeButton(.fillScreen, label: "Fill Screen", systemImage: "rectangle.arrowtriangle.2.outward")
            } label: {
                chromeIconLabel(
                    systemName: interactionVM.displayMode == .fillScreen
                        ? "rectangle.arrowtriangle.2.outward"
                        : "rectangle.arrowtriangle.2.inward",
                    isActive: interactionVM.displayMode == .fillScreen,
                    isDimmed: false,
                    accent: PR.accent,
                    isDestructive: false
                )
            }
            .buttonStyle(.plain)

            if environment.showsStatsOverlay && !isStatsVisible {
                chromeIconButton(
                    systemName: "chart.bar",
                    isActive: true,
                    accent: PR.accent
                ) {
                    isStatsVisible = true
                }
            }

            chromeDivider

            chromeIconButton(systemName: "eye.slash", isDimmed: true) {
                AppHaptics.selection()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    isControlsHidden = true
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .liquidGlassPill()
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var chromeDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func chromeIconButton(
        systemName: String,
        isActive: Bool = false,
        isDimmed: Bool = false,
        accent: Color = .white,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            chromeIconLabel(
                systemName: systemName,
                isActive: isActive,
                isDimmed: isDimmed,
                accent: accent,
                isDestructive: isDestructive
            )
        }
        .buttonStyle(.plain)
    }

    private func chromeIconLabel(
        systemName: String,
        isActive: Bool,
        isDimmed: Bool,
        accent: Color,
        isDestructive: Bool
    ) -> some View {
        ZStack {
            if isDestructive {
                Circle()
                    .fill(Color.red.opacity(0.95))
                    .frame(width: 30, height: 30)
            }
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(chromeIconForeground(
                    isActive: isActive,
                    isDimmed: isDimmed,
                    accent: accent,
                    isDestructive: isDestructive
                ))
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }

    private func chromeIconForeground(
        isActive: Bool,
        isDimmed: Bool,
        accent: Color,
        isDestructive: Bool
    ) -> Color {
        if isDestructive { return .white }
        if isDimmed { return .white.opacity(0.38) }
        if isActive { return accent }
        return .white.opacity(0.82)
    }

    private var displayVMRequiresKeyboard: Bool {
        switch sessionCoordinator.phase {
        case .receiving, .waitingForMedia:
            return true
        default:
            return false
        }
    }

    private func requestDisplaySwitch(to displayID: String) {
        guard let sessionID = sessionCoordinator.activeSessionID else { return }
        guard sessionCoordinator.phase == .receiving || sessionCoordinator.phase == .waitingForMedia else { return }
        displayLayoutViewModel.beginDisplaySwitch(to: displayID)
        let message = DisplaySwitchRequestMessage(
            sessionID: sessionID,
            targetDisplayID: displayID,
            senderDeviceID: environment.clientIdentity.id
        )
        do {
            try environment.webRTCSessionManager.sendDataMessage(try DataChannelEnvelope.displaySwitch(message))
        } catch {
            displayLayoutViewModel.failDisplaySwitch(
                reason: "Could not request the display change.",
                fallbackID: displayLayoutViewModel.hostSelectedDisplayID
            )
        }
    }

    private func displayModeButton(
        _ mode: DisplayMappingEngine.DisplayMode,
        label: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        Button {
            AppHaptics.selection()
            resetModernZoom()
            interactionVM.displayMode = mode
        } label: {
            Label(label, systemImage: interactionVM.displayMode == mode ? "checkmark" : systemImage)
        }
        .disabled(interactionVM.displayMode == mode)
    }

    private func clampedViewportOffset(_ proposed: CGSize, zoom: CGFloat, in viewSize: CGSize) -> CGSize {
        guard zoom > 1.0 else { return .zero }
        let fitted = interactionVM.mapper?.fittedContentRect
        let content = CGRect(
            x: CGFloat(fitted?.origin.x ?? 0),
            y: CGFloat(fitted?.origin.y ?? 0),
            width: fitted.map { CGFloat($0.size.width) } ?? viewSize.width,
            height: fitted.map { CGFloat($0.size.height) } ?? viewSize.height
        )
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)

        func clampAxis(
            _ value: CGFloat,
            contentMin: CGFloat,
            contentMax: CGFloat,
            viewportLength: CGFloat,
            center: CGFloat
        ) -> CGFloat {
            let scaledMin = center + (contentMin - center) * zoom
            let scaledMax = center + (contentMax - center) * zoom
            if scaledMax - scaledMin <= viewportLength {
                return viewportLength / 2 - (scaledMin + scaledMax) / 2
            }
            return min(max(value, viewportLength - scaledMax), -scaledMin)
        }
        return CGSize(
            width: clampAxis(
                proposed.width,
                contentMin: content.minX,
                contentMax: content.maxX,
                viewportLength: viewSize.width,
                center: center.x
            ),
            height: clampAxis(
                proposed.height,
                contentMin: content.minY,
                contentMax: content.maxY,
                viewportLength: viewSize.height,
                center: center.y
            )
        )
    }

    private func sendCommandTab() {
        interactionVM.sendKey(keyCode: 48, action: .down, modifiers: [.command])
        interactionVM.sendKey(keyCode: 48, action: .up, modifiers: [.command])
    }
}

#if !canImport(UIKit) || os(macOS)
private struct MirrorVideoPlaceholder: View {
    let frameSize: DesktopSize?
    let mapper: ViewportCoordinateMapper?

    var body: some View {
        GeometryReader { _ in
            if let mapper {
                let fitted = mapper.fittedContentRect
                Rectangle()
                    .fill(Color(white: 0.08))
                    .frame(width: fitted.size.width, height: fitted.size.height)
                    .position(
                        x: fitted.origin.x + fitted.size.width / 2,
                        y: fitted.origin.y + fitted.size.height / 2
                    )
                    .overlay {
                        if let sz = frameSize {
                            Text("\(Int(sz.width))×\(Int(sz.height))")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
            } else {
                Rectangle()
                    .fill(Color(white: 0.05))
            }
        }
    }
}
#endif

private struct MirrorStreamDiagPanel: View {
    let framesReceived: UInt64
    let bytesReceived: UInt64
    let framesDecoded: UInt64
    var decodeErrors: UInt64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            diagRow("rx", "\(framesReceived)f · \(formattedBytes(bytesReceived))")
            diagRow("decoded", "\(framesDecoded)")
            if decodeErrors > 0 {
                diagRow("err", "\(decodeErrors) (no keyframe)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func diagRow(_ key: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .foregroundColor(PR.dim)
            Text(value)
                .foregroundColor(PR.accent)
        }
        .font(.system(size: 9, design: .monospaced))
    }

    private func formattedBytes(_ b: UInt64) -> String {
        if b < 1024 { return "\(b)B" }
        if b < 1024 * 1024 { return "\(b / 1024)KB" }
        return "\(b / (1024 * 1024))MB"
    }
}

private struct MirrorHUD: View {
    let isDismissible: Bool
    let fps: String
    let latency: String
    let bandwidth: String
    let onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("stats")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(PR.dim)
                Spacer(minLength: 0)
                if isDismissible, let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(PR.dim)
                            .frame(width: 16, height: 16)
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            hudLine("fps", fps)
            hudLine("latency", latency)
            hudLine("bw", bandwidth)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: PR.r6))
    }

    private func hudLine(_ key: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(PR.dim)
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.accent)
                .monospacedDigit()
        }
    }
}

#if canImport(UIKit) && !os(macOS)
private struct MirrorFullscreenGestureView: UIViewRepresentable {
    var viewportZoom: CGFloat
    var viewportOffset: CGSize
    var viewSize: CGSize

    var onTap: (CGPoint) -> Void
    var onDoubleTap: (CGPoint) -> Void
    var onRightClick: (CGPoint) -> Void
    var onMiddleClick: (CGPoint) -> Void = { _ in }
    var onDragChanged: (CGSize, CGPoint) -> Void
    var onDragEnded: () -> Void
    var onScroll: (Double, Double) -> Void
    var onViewportPan: (CGSize) -> Void
    var onPinchChanged: (CGFloat, CGPoint) -> Void
    var onPinchEnded: () -> Void
    var onLongPress: (CGPoint) -> Void
    var onPointerDelta: (CGSize) -> Void = { _ in }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        context.coordinator.setup(on: view)
        return view
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.teardown(from: uiView)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.viewportZoom = viewportZoom
        coordinator.viewportOffset = viewportOffset
        coordinator.viewSize = viewSize
        coordinator.onTap = onTap
        coordinator.onDoubleTap = onDoubleTap
        coordinator.onRightClick = onRightClick
        coordinator.onMiddleClick = onMiddleClick
        coordinator.onDragChanged = onDragChanged
        coordinator.onDragEnded = onDragEnded
        coordinator.onScroll = onScroll
        coordinator.onViewportPan = onViewportPan
        coordinator.onPinchChanged = onPinchChanged
        coordinator.onPinchEnded = onPinchEnded
        coordinator.onLongPress = onLongPress
        coordinator.onPointerDelta = onPointerDelta
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var viewportZoom: CGFloat = 1
        var viewportOffset: CGSize = .zero
        var viewSize: CGSize = .zero

        var onTap: (CGPoint) -> Void = { _ in }
        var onDoubleTap: (CGPoint) -> Void = { _ in }
        var onRightClick: (CGPoint) -> Void = { _ in }
        var onMiddleClick: (CGPoint) -> Void = { _ in }
        var onDragChanged: (CGSize, CGPoint) -> Void = { _, _ in }
        var onDragEnded: () -> Void = {}
        var onScroll: (Double, Double) -> Void = { _, _ in }
        var onViewportPan: (CGSize) -> Void = { _ in }
        var onPinchChanged: (CGFloat, CGPoint) -> Void = { _, _ in }
        var onPinchEnded: () -> Void = {}
        var onLongPress: (CGPoint) -> Void = { _ in }
        var onPointerDelta: (CGSize) -> Void = { _ in }

        private var lastOneFingerTranslation: CGSize = .zero
        private var lastTwoFingerTranslation: CGSize = .zero
        private var twoFingerPansViewport: Bool = false
        private var scrollVelocity: CGSize = .zero
        private var momentumLink: CADisplayLink?
        private var lastHoverLocation: CGPoint?
        private weak var pinchRecognizer: UIPinchGestureRecognizer?

        func setup(on view: UIView) {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTouchesRequired = 1
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self

            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            singleTap.numberOfTouchesRequired = 1
            singleTap.numberOfTapsRequired = 1
            singleTap.require(toFail: doubleTap)
            singleTap.delegate = self

            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.numberOfTapsRequired = 1
            twoFingerTap.delegate = self

            let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
            threeFingerTap.numberOfTouchesRequired = 3
            threeFingerTap.numberOfTapsRequired = 1
            threeFingerTap.delegate = self

            let oneFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
            oneFingerPan.minimumNumberOfTouches = 1
            oneFingerPan.maximumNumberOfTouches = 1
            oneFingerPan.delegate = self

            let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            twoFingerPan.delegate = self

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            pinchRecognizer = pinch

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.5
            longPress.numberOfTouchesRequired = 1
            longPress.delegate = self

            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            hover.delegate = self

            for recognizer in [singleTap, doubleTap, twoFingerTap, threeFingerTap, oneFingerPan, twoFingerPan, pinch, longPress, hover] {
                view.addGestureRecognizer(recognizer)
            }
        }

        func teardown(from view: UIView) {
            for recognizer in view.gestureRecognizers ?? [] {
                recognizer.delegate = nil
                view.removeGestureRecognizer(recognizer)
            }
            cancelMomentum()
        }

        private func adjustedPoint(_ point: CGPoint) -> CGPoint {
            guard viewportZoom != 1 || viewportOffset != .zero else {
                return point
            }

            let centerX = viewSize.width / 2
            let centerY = viewSize.height / 2

            return CGPoint(
                x: centerX + (point.x - centerX - viewportOffset.width) / viewportZoom,
                y: centerY + (point.y - centerY - viewportOffset.height) / viewportZoom
            )
        }

        @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            cancelMomentum()   // a tap stops an in-progress fling
            onTap(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            onDoubleTap(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            onRightClick(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func handleThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            onMiddleClick(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func handleOneFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }

            switch recognizer.state {
            case .began:
                cancelMomentum()   // moving the cursor stops an in-progress fling
                lastOneFingerTranslation = .zero
            case .changed:
                let translation = recognizer.translation(in: view)
                let deltaX = translation.x - lastOneFingerTranslation.width
                let deltaY = translation.y - lastOneFingerTranslation.height
                lastOneFingerTranslation = CGSize(width: translation.x, height: translation.y)

                let scaledDelta = CGSize(width: deltaX / viewportZoom, height: deltaY / viewportZoom)
                onDragChanged(scaledDelta, adjustedPoint(recognizer.location(in: view)))
            case .ended, .cancelled, .failed:
                lastOneFingerTranslation = .zero
                onDragEnded()
            default:
                break
            }
        }

        @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }

            switch recognizer.state {
            case .began:
                cancelMomentum()
                lastTwoFingerTranslation = .zero
                scrollVelocity = .zero
                // Latch pan-vs-scroll at gesture start so a concurrent pinch
                // crossing the zoom threshold mid-gesture can't flip the mode.
                twoFingerPansViewport = viewportZoom > 1.05 || isPinching
            case .changed:
                let translation = recognizer.translation(in: view)
                let deltaX = translation.x - lastTwoFingerTranslation.width
                let deltaY = translation.y - lastTwoFingerTranslation.height
                lastTwoFingerTranslation = CGSize(width: translation.x, height: translation.y)

                if isPinching { twoFingerPansViewport = true }
                if twoFingerPansViewport {
                    onViewportPan(CGSize(width: deltaX, height: deltaY))
                } else {
                    // 1:1 finger-to-view-point gain; the coordinate mapper multiplies
                    // by the view→display ratio downstream. The old /3 divisor meant a
                    // full-screen swipe scrolled barely a third of a screen and the
                    // momentum fling threshold was almost never reached.
                    let sx = Double(-deltaX)
                    let sy = Double(deltaY)
                    onScroll(sx, sy)
                    // Track the most recent scroll velocity for inertial fling.
                    scrollVelocity = CGSize(width: sx, height: sy)
                }
            case .ended:
                lastTwoFingerTranslation = .zero
                if !twoFingerPansViewport { startMomentum() }
            case .cancelled, .failed:
                lastTwoFingerTranslation = .zero
            default:
                break
            }
        }

        // MARK: Inertial (momentum) scroll

        private func startMomentum() {
            let speed = (scrollVelocity.width * scrollVelocity.width
                         + scrollVelocity.height * scrollVelocity.height).squareRoot()
            guard speed > 1.5 else { return }
            momentumLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(momentumTick))
            link.add(to: .main, forMode: .common)
            momentumLink = link
        }

        private func cancelMomentum() {
            momentumLink?.invalidate()
            momentumLink = nil
            scrollVelocity = .zero
        }

        @objc private func momentumTick() {
            onScroll(Double(scrollVelocity.width), Double(scrollVelocity.height))
            scrollVelocity = CGSize(width: scrollVelocity.width * 0.92,
                                    height: scrollVelocity.height * 0.92)
            let speed = (scrollVelocity.width * scrollVelocity.width
                         + scrollVelocity.height * scrollVelocity.height).squareRoot()
            if speed < 0.4 { cancelMomentum() }
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                cancelMomentum()
                twoFingerPansViewport = true
            case .changed:
                guard let view = recognizer.view else { return }
                onPinchChanged(recognizer.scale, recognizer.location(in: view))
                recognizer.scale = 1
            case .ended, .cancelled:
                onPinchEnded()
            default:
                break
            }
        }

        private var isPinching: Bool {
            guard let pinchRecognizer else { return false }
            return pinchRecognizer.state == .began || pinchRecognizer.state == .changed
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view else { return }
            onLongPress(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                lastHoverLocation = location
            case .changed:
                guard let last = lastHoverLocation else {
                    lastHoverLocation = location
                    return
                }
                let dx = location.x - last.x
                let dy = location.y - last.y
                lastHoverLocation = location
                if dx != 0 || dy != 0 {
                    onPointerDelta(CGSize(width: dx, height: dy))
                }
            case .ended, .cancelled, .failed:
                lastHoverLocation = nil
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer is UIHoverGestureRecognizer || other is UIHoverGestureRecognizer {
                return true
            }
            let isPinch = gestureRecognizer is UIPinchGestureRecognizer
            let otherIsPinch = other is UIPinchGestureRecognizer
            let isTwoFingerPan = (gestureRecognizer as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2
            let otherIsTwoFingerPan = (other as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2

            return (isPinch && otherIsTwoFingerPan) || (otherIsPinch && isTwoFingerPan)
        }
    }
}
#endif

private struct MirrorControlButton: View {
    let icon: String
    let label: String
    let combo: String
    let action: () -> Void

    private var accent: Color {
        switch label {
        case "hosts":
            return Color(hex: 0x39E0C4)
        case "keys":
            return Color(hex: 0x5E9BFF)
        case "screens":
            return Color(hex: 0xC983FF)
        case "capture":
            return Color(hex: 0xFF6C93)
        case "stats":
            return Color(hex: 0x2DE3F2)
        case "switch":
            return Color(hex: 0xD4EF58)
        default:
            return Color(hex: 0x39E0C4)
        }
    }

    private var borderAccent: Color {
        Color(hex: 0x39E0C4)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                PRKeycap(combo: combo, tint: accent)
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(accent)
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(PR.bg2)
            .overlay(
                RoundedRectangle(cornerRadius: PR.r8)
                    .strokeBorder(borderAccent.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: PR.r8))
        }
        .buttonStyle(.plain)
    }
}

private extension Color {
    func mix(with other: Color, by amount: CGFloat) -> Color {
        let t = max(0, min(1, amount))
#if canImport(UIKit)
        let a = UIColor(self)
        let b = UIColor(other)
        var ar: CGFloat = 0
        var ag: CGFloat = 0
        var ab: CGFloat = 0
        var aa: CGFloat = 0
        var br: CGFloat = 0
        var bg: CGFloat = 0
        var bb: CGFloat = 0
        var ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return Color(
            .sRGB,
            red: Double(ar + (br - ar) * t),
            green: Double(ag + (bg - ag) * t),
            blue: Double(ab + (bb - ab) * t),
            opacity: Double(aa + (ba - aa) * t)
        )
#else
        return self
#endif
    }
}

#Preview("MirrorScreen") {
    if #available(iOS 16.1, *) {
        MirrorScreen(environment: ClientAppEnvironment.makeDefault(clientName: "Vamp Control"))
    }
}
