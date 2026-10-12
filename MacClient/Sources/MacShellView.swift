import SwiftUI
import SharedModels

/// Root view of the Mac client window. Shows the hosts list while idle and
/// swaps to the streaming session view once a connection is underway.
///
/// The `ClientReconnectCoordinator` is owned here (not in the session view) so
/// it survives a transient `.error` phase: the session view stays mounted for
/// the whole reconnect window, and only unmounts once the session is genuinely
/// over (`.idle`). Otherwise unmounting the session view on `.error` would tear
/// down the very coordinator responsible for recovering the connection.
struct MacShellView: View {
    @ObservedObject var environment: ClientAppEnvironment
    @ObservedObject private var coordinator: ClientSessionCoordinator
    @StateObject private var reconnectCoordinator: ClientReconnectCoordinator
    @StateObject private var assistant = MacAssistantSession()
    @ObservedObject private var nicknames = MacHostNicknameStore.shared

    /// Latches once a session reaches `.receiving`, so a subsequent transient
    /// `.error`/`.connecting`/`.negotiating` keeps showing the session view
    /// (with the reconnect overlay) instead of flickering back to the hosts list.
    /// Cleared when the session ends (`.idle`).
    @State private var hasStreamedThisSession = false

    @AppStorage("client.onboarding.completed") private var onboardingCompleted = false
    @State private var showOnboarding = false

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        self.coordinator = environment.sessionCoordinator
        _reconnectCoordinator = StateObject(wrappedValue: ClientReconnectCoordinator(
            webRTCSessionManager: environment.webRTCSessionManager,
            signalingService: environment.signalingService,
            displayLayoutViewModel: environment.displayLayoutViewModel,
            isMacClient: true
        ))
    }

    /// Whether to show the live session view rather than the hosts list.
    private var showsSession: Bool {
        switch coordinator.phase {
        case .receiving, .waitingForMedia:
            return true
        case .connecting, .signalingConnected, .negotiating, .error:
            // Mid-reconnect after a session that already streamed: stay put.
            return hasStreamedThisSession
        case .idle:
            // Reconnect rebuilds the transport by calling disconnect(), which
            // briefly publishes `.idle`. Keep this view mounted so its reconnect
            // observers and callbacks survive that implementation detail.
            return hasStreamedThisSession && reconnectIsActive
        }
    }

    private var reconnectIsActive: Bool {
        reconnectCoordinator.isReconnecting || coordinator.isReconnectInProgress
    }

    /// A live stream fills the window with black video. The title bar sits
    /// directly above it, so it has to switch to the dark appearance too —
    /// otherwise the session's own dark toolbar chrome sits under a bright
    /// system title bar and the top of the window reads as a seam.
    private var showsStreamChrome: Bool {
        assistant.connected != nil || showsSession
    }

    var body: some View {
        Group {
            if assistant.connected != nil {
                MacAssistantRemoteView(model: assistant)
            } else if showsSession {
                MacRemoteSessionView(
                    environment: environment,
                    reconnectCoordinator: reconnectCoordinator
                )
            } else {
                MacHostsScreen(environment: environment, assistant: assistant)
            }
        }
        .tint(MacBrand.accent)
        .focusedSceneObject(assistant)
        .background(MacClientWindowConfigurator(
            extendsUnderTitleBar: !showsStreamChrome,
            hidesNativeTitle: true
        ))
        .preferredColorScheme(showsStreamChrome ? .dark : nil)
        // Keep the title for Window menus and accessibility. The toolbar's host
        // status already names the remote Mac, so do not repeat it in the bar.
        .navigationTitle(showsStreamChrome ? windowTitle : "")
        .onChange(of: coordinator.phase) { phase in
            switch phase {
            case .receiving:
                hasStreamedThisSession = true
            case .idle:
                if !reconnectIsActive {
                    hasStreamedThisSession = false
                }
            default:
                break
            }
        }
        .onChange(of: reconnectCoordinator.isReconnecting) { isReconnecting in
            if !isReconnecting,
               !coordinator.isReconnectInProgress,
               coordinator.phase == .idle {
                hasStreamedThisSession = false
            }
        }
        .onChange(of: coordinator.isReconnectInProgress) { isReconnecting in
            if !isReconnecting,
               !reconnectCoordinator.isReconnecting,
               coordinator.phase == .idle || coordinator.phase == .error {
                hasStreamedThisSession = false
            }
        }
        .sheet(isPresented: $showOnboarding) {
            MacOnboardingView {
                onboardingCompleted = true
                showOnboarding = false
            }
            .interactiveDismissDisabled()
        }
        .onAppear {
            if !onboardingCompleted { showOnboarding = true }
        }
    }

    /// A Mac the user renamed must stay renamed once connected, not revert to
    /// whatever the host advertises.
    private var connectedHostDisplayName: String? {
        if let endpoint = coordinator.lastEndpoint {
            return nicknames.displayName(for: endpoint)
        }
        return coordinator.connectedHostName
    }

    private var windowTitle: String {
        if let session = assistant.connected {
            return "\(session.displayName) — Vamp Control"
        }
        switch coordinator.phase {
        case .receiving:
            if let name = connectedHostDisplayName {
                return "\(name) — Vamp Control"
            }
            return "Vamp Control"
        case .connecting, .signalingConnected, .negotiating, .waitingForMedia:
            return "Connecting… — Vamp Control"
        case .idle, .error:
            return "Vamp Control"
        }
    }
}
