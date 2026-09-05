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
                .vampSplash(.vampStream(), minimumDuration: 1.7)
        }
    }
}

/// Focused root state machine. There is no tab bar: the app is either choosing a saved Mac,
/// connecting, controlling its display, or selecting and streaming one of its app windows.
struct VampStreamRootView: View {
    private enum AssistantExperience {
        case remoteControl
        case appStream
    }

    let environment: ClientAppEnvironment
    @ObservedObject var appStream: AppStreamViewModel
    @ObservedObject var vampAssistant: BeetCodeRemoteSessionViewModel
    @ObservedObject private var sessionCoordinator: ClientSessionCoordinator
    @State private var connectingName: String?
    @State private var showVampAssistantPairing = false
    @State private var showVampHostScanner = false
    @State private var hostScannerError: String?
    @State private var assistantExperience: AssistantExperience = .remoteControl

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
            PRAppBackground()
            content
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChangeCompat(of: isConnected) { connected in
            if connected { connectingName = nil }
        }
        .onChangeCompat(of: sessionCoordinator.phase) { phase in
            if phase == .error { connectingName = nil }
        }
        .sheet(isPresented: $showVampAssistantPairing) {
            BeetCodePairingView(model: vampAssistant)
                .presentationDetents([.large])
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
            switch assistantExperience {
            case .remoteControl:
                BeetCodeRemoteView(
                    session: session,
                    onClose: { vampAssistant.disconnect() },
                    onRefresh: { await vampAssistant.refreshStatus() }
                )
            case .appStream:
                VampAssistantAppStreamView(
                    session: session,
                    onClose: { vampAssistant.disconnect() },
                    onRefreshStatus: { await vampAssistant.refreshStatus() }
                )
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
                VampStreamConnectingView(name: sessionCoordinator.connectedHostName ?? connectingName ?? "Mac") {
                    Task { await sessionCoordinator.disconnect() }
                }
            }
        } else if isConnecting {
            VampStreamConnectingView(name: connectingName ?? "Mac") {
                connectingName = nil
                Task { await sessionCoordinator.disconnect() }
            }
        } else {
            VampStreamConnectView(
                environment: environment,
                onConnect: { host in
                    connectingName = host.title
                    environment.sharedHostsViewModel.connect(to: host)
                    Task {
                        if sessionCoordinator.activeSessionID != nil { await sessionCoordinator.disconnect() }
                        await sessionCoordinator.connect(
                            to: host.endpoint,
                            qualityPreset: environment.effectivePreferredQualityPreset
                        )
                    }
                },
                onPairVampAssistant: {
                    // Pairing must land on the same destination the picker offers. Remote
                    // Control is gated off in this build, and sending a freshly paired Mac
                    // there opened the whole desktop instead of the app browser.
                    assistantExperience = .appStream
                    showVampAssistantPairing = true
                },
                onScanVampHost: { showVampHostScanner = true },
                pairedVampAssistants: vampAssistant.savedAssistants,
                vampAssistantAvailability: vampAssistant.availabilityByAddress,
                vampAssistantError: vampAssistant.lastError ?? sessionCoordinator.errorMessage,
                onRemoteControl: { saved in
                    assistantExperience = .remoteControl
                    Task { await vampAssistant.reconnect(saved) }
                },
                onAppStream: { saved in
                    assistantExperience = .appStream
                    Task { await vampAssistant.reconnect(saved) }
                },
                onForgetVampAssistant: { saved in
                    vampAssistant.forget(saved)
                }
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
        connectingName = pairing.displayName ?? host.title
        connect(to: host)
    }

    private func connect(to host: DiscoveredHostRow) {
        environment.sharedHostsViewModel.connect(to: host)
        Task {
            if sessionCoordinator.activeSessionID != nil { await sessionCoordinator.disconnect() }
            await sessionCoordinator.connect(
                to: host.endpoint,
                qualityPreset: environment.effectivePreferredQualityPreset
            )
        }
    }
}
