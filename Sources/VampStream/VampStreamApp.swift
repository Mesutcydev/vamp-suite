import SwiftUI
import SharedModels
import SharedUI

/// Vamp Stream — a focused iPhone streaming client. Vamp Sync connections open the Mac app
/// browser, while a paired Vamp Assistant Mac offers two explicit experiences: the original
/// whole-display Remote Control surface or a separate app/window stream picker.
@main
struct VampStreamApp: App {
    @UIApplicationDelegateAdaptor(VampStreamAppDelegate.self) private var appDelegate
    @StateObject private var environment: ClientAppEnvironment
    @StateObject private var appStream: AppStreamViewModel
    @StateObject private var vampAssistant: BeetCodeRemoteSessionViewModel

    init() {
        VampStreamStreamingQualityPolicy.migrateAssistantResolution()
        let env = ClientAppEnvironment.makeDefault(clientName: "Vamp Stream")
        switch UserDefaults.standard.string(forKey: "vampstream.qualityMode") {
        case "performance": env.preferredQualityPreset = .performance
        case "quality": env.preferredQualityPreset = env.isUltraQualityEntitled ? .ultra : .quality
        case "auto": env.preferredQualityPreset = .balanced
        default:
            env.preferredQualityPreset = VampStreamStreamingQualityPolicy.preferredPreset(
                current: env.preferredQualityPreset, supportsUltra: env.isUltraQualityEntitled)
        }
        _environment = StateObject(wrappedValue: env)
        _appStream = StateObject(wrappedValue: AppStreamViewModel(environment: env))
        _vampAssistant = StateObject(wrappedValue: BeetCodeRemoteSessionViewModel())
    }

    var body: some Scene {
        WindowGroup {
            VampStreamRootView(environment: environment, appStream: appStream, vampAssistant: vampAssistant)
                .vampStreamAnimatedSplash()
                .preferredColorScheme(.dark)
        }
    }
}

/// Focused root state machine. There is no tab bar: the app is either choosing a saved Mac,
/// connecting, or selecting and streaming one of its app windows.
///
/// There is deliberately no whole-display destination here. Vamp Stream is the app-window
/// client; controlling an entire Mac desktop is Vamp Control's job. The Assistant surface
/// still falls back to `BeetCodeRemoteView` for the locked/permission states, but a paired
/// Mac always lands in the app browser.
struct VampStreamRootView: View {
    let environment: ClientAppEnvironment
    @ObservedObject var appStream: AppStreamViewModel
    @ObservedObject var vampAssistant: BeetCodeRemoteSessionViewModel
    @ObservedObject private var sessionCoordinator: ClientSessionCoordinator
    @State private var connectingName: String?
    @State private var lastSyncHost: DiscoveredHostRow?
    @State private var lastAssistant: BeetCodeRemoteSessionViewModel.SavedAssistant?
    @State private var forgetChoice: BeetCodeRemoteSessionViewModel.SavedAssistant?
    @State private var assistantTask: Task<Void, Never>?
    @State private var syncTask: Task<Void, Never>?
    @State private var showVampAssistantPairing = false
    @State private var showVampHostScanner = false
    @State private var hostScannerError: String?

    init(
        environment: ClientAppEnvironment,
        appStream: AppStreamViewModel,
        vampAssistant: BeetCodeRemoteSessionViewModel
    ) {
        self.environment = environment
        self.appStream = appStream
        self.vampAssistant = vampAssistant
        self.sessionCoordinator = environment.sessionCoordinator
    }

    static func shouldPresentSession(sessionID: UUID?, phase: ClientSessionCoordinator.SessionPhase) -> Bool {
        // The coordinator allocates an ID before negotiation. A failed attempt
        // can still have that ID, so it must not hide the connection error.
        sessionID != nil && phase != .error && phase != .idle
    }

    private var isConnected: Bool {
        Self.shouldPresentSession(sessionID: sessionCoordinator.activeSessionID, phase: sessionCoordinator.phase)
    }
    private var isConnecting: Bool {
        connectingName != nil && !isConnected && sessionCoordinator.phase != .error
    }
    private var isStreamingApp: Bool {
        if case .streaming = appStream.status { return true }
        return false
    }

    var body: some View {
        ZStack {
            VampStreamAppBackground()
            content
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChangeCompat(of: isConnected) { connected in
            if connected { connectingName = nil }
        }
        .onChangeCompat(of: sessionCoordinator.phase) { phase in
            if phase == .error { connectingName = nil }
        }
        .fullScreenCover(isPresented: $showVampAssistantPairing) {
            BeetCodePairingView(model: vampAssistant)
        }
        .sheet(isPresented: $showVampHostScanner) {
            NavigationStack {
                BeetCodeQRScannerView(source: .sync, onPayload: handleVampHostPayload)
                    .navigationTitle("Scan Vamp Sync")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showVampHostScanner = false }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        .confirmationDialog(
            "Forget \(forgetChoice?.displayName ?? "this Mac")?",
            isPresented: Binding(get: { forgetChoice != nil }, set: { if !$0 { forgetChoice = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget Mac", role: .destructive) {
                if let saved = forgetChoice {
                    vampAssistant.forget(saved)
                    if lastAssistant?.id == saved.id { lastAssistant = nil }
                }
                forgetChoice = nil
            }
            Button("Cancel", role: .cancel) { forgetChoice = nil }
        } message: {
            Text("This removes the saved connection from this device. You will need to pair with this Mac again.")
        }
        .alert("QR code not recognised", isPresented: Binding(
            get: { hostScannerError != nil },
            set: { if !$0 { hostScannerError = nil } }
        )) {
            Button("OK", role: .cancel) { hostScannerError = nil }
        } message: {
            Text(hostScannerError ?? "Scan the QR shown by Vamp Sync.")
        }
    }

    @ViewBuilder private var content: some View {
        if let session = vampAssistant.session {
            VampAssistantAppStreamView(
                session: session,
                onClose: { vampAssistant.disconnect() },
                onRefreshStatus: { await vampAssistant.refreshStatus() }
            )
        } else if vampAssistant.isPairing && !showVampAssistantPairing {
            VampStreamConnectingView(name: lastAssistant?.displayName ?? "Mac", detail: "Checking your saved connection and loading apps.") {
                assistantTask?.cancel()
                vampAssistant.cancelConnectionAttempt()
            }
        } else if isConnected {
            if let caps = sessionCoordinator.negotiatedCapabilities {
                if caps.supportsAppStreaming {
                    AppStreamBrowserView(environment: environment, vm: appStream) {
                        appStream.forgetSelection()
                        Task { await sessionCoordinator.disconnect() }
                    }
                } else {
                    VampStreamMessageView(
                        icon: "macwindow.badge.plus",
                        title: "App Streaming Unavailable",
                        message: "This Mac's Vamp Sync doesn't support App Streaming yet. It needs to be updated (macOS 14 or newer).",
                        actionTitle: "Disconnect"
                    ) { Task { await sessionCoordinator.disconnect() } }
                }
            } else {
                // Connected, but capabilities aren't negotiated yet — keep waiting, don't
                // misreport as unsupported.
                VampStreamConnectingView(name: sessionCoordinator.connectedHostName ?? connectingName ?? "Mac", detail: connectionDetail) {
                    syncTask?.cancel()
                    Task { await sessionCoordinator.disconnect() }
                }
            }
        } else if isConnecting {
            VampStreamConnectingView(name: connectingName ?? "Mac", detail: connectionDetail) {
                syncTask?.cancel()
                connectingName = nil
                Task { await sessionCoordinator.disconnect() }
            }
        } else {
            VampStreamConnectView(
                environment: environment,
                onConnect: { host in connect(to: host) },
                onPairVampAssistant: { showVampAssistantPairing = true },
                onScanVampHost: { showVampHostScanner = true },
                pairedVampAssistants: vampAssistant.savedAssistants,
                vampAssistantAvailability: vampAssistant.availabilityByAddress,
                // Keep the two providers' failures separate. Merging the coordinator's message
                // into the Assistant slot is what labelled a Vamp Sync failure as an Assistant one.
                vampAssistantError: vampAssistant.lastError,
                vampSyncError: sessionCoordinator.errorMessage,
                // The host-busy rejection is per-host: `connectedHostName` survives that path, so
                // it names exactly which Mac refused and only that row shows "In use".
                busyHostName: VampStreamHostBusy.isHostBusy(sessionCoordinator.errorMessage)
                    ? sessionCoordinator.connectedHostName
                    : nil,
                onAppStream: { saved in reconnectAssistant(saved) },
                onForgetVampAssistant: { saved in forgetChoice = saved },
                onRetrySync: lastSyncHost.map { host in { connect(to: host) } },
                onRetryAssistant: lastAssistant.map { saved in { reconnectAssistant(saved) } }
            )
            .task(id: vampAssistant.savedAssistants) {
                await vampAssistant.refreshAvailability()
            }
        }
    }

    private func handleVampHostPayload(_ payload: String) {
        guard let pairing = VampHostPairingLink.parse(payload),
              let host = environment.sharedHostsViewModel.addManualHost(address: pairing.address) else {
            hostScannerError = "Scan the QR shown by Vamp Sync, then try again."
            showVampHostScanner = false
            return
        }
        showVampHostScanner = false
        connect(to: host)
    }

    private func reconnectAssistant(_ saved: BeetCodeRemoteSessionViewModel.SavedAssistant) {
        lastAssistant = saved
        assistantTask?.cancel()
        assistantTask = Task { await vampAssistant.reconnect(saved) }
    }

    private var connectionDetail: String {
        switch sessionCoordinator.phase {
        case .idle, .connecting: return "Contacting your Mac. Keep Vamp Sync open and stay on the same private network."
        case .signalingConnected: return "Mac reached. Preparing the secure connection."
        case .negotiating: return "Establishing the session. If your Mac requests approval, review the device there."
        case .waitingForMedia, .receiving: return "Connected. Loading apps from your Mac."
        case .error: return "The connection could not be completed. Return to your Macs to try again."
        }
    }

    private func connect(to host: DiscoveredHostRow) {
        lastSyncHost = host
        connectingName = host.title
        syncTask?.cancel()
        environment.sharedHostsViewModel.connect(to: host)
        syncTask = Task {
            if sessionCoordinator.activeSessionID != nil { await sessionCoordinator.disconnect() }
            guard !Task.isCancelled else { return }
            await sessionCoordinator.connect(
                to: host.endpoint,
                qualityPreset: environment.effectivePreferredQualityPreset
            )
        }
    }
}

struct VampStreamAppBackground: View {
    var body: some View {
        VampStreamEnvironmentBackdrop()
    }
}
