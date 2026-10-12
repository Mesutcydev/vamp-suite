import Combine
import SwiftUI
import SharedUI

private struct OnChangeCompatModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value) -> Void

    @State private var previousValue: Value?

    func body(content: Content) -> some View {
        content.onReceive(Just(value)) { newValue in
            guard let previousValue else {
                self.previousValue = newValue
                return
            }
            guard previousValue != newValue else { return }
            self.previousValue = newValue
            action(newValue)
        }
    }
}

extension View {
    func onChangeCompat<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        modifier(OnChangeCompatModifier(value: value, action: action))
    }
}

/// Opaque cover shown over the window while App Lock is enabled and the scene is not active, so the
/// streamed desktop never lands in the iOS app-switcher snapshot.
private struct AppLockPrivacyCover: View {
    var body: some View {
        ZStack {
            PR.bg.ignoresSafeArea()
            Image(systemName: "lock.fill")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundColor(PR.accent)
        }
    }
}

@main
struct ClientiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var environment = ClientAppEnvironment.makeDefault(clientName: "Vamp Control")
    @StateObject private var keepaliveService = BackgroundKeepaliveService()
    @StateObject private var appLock = AppLockService()
    @State private var observersInstalled = false

    init() {
        CrashSafeStartupDiagnostics.mark("app.init.begin")
        CrashSafeStartupDiagnostics.mark("app.init.end")
    }

    var body: some Scene {
        WindowGroup {
            // Deployment target is iOS 18, so the legacy ClientShellView/RemoteDesktopView
            // fallback (the `if #available(iOS 16.1, *)` else-branch) was statically dead and
            // was removed along with those files. RootTabView is the sole live UI path.
            RootTabView(environment: environment, appLock: appLock)
            .overlay {
                if appLock.isLocked {
                    AppLockView(lockService: appLock)
                        .transition(.opacity)
                } else if appLock.isEnabled && scenePhase != .active {
                    // Privacy cover so the streamed desktop isn't captured into the iOS
                    // app-switcher snapshot (taken on .inactive) while App Lock is enabled.
                    // Independent of isLocked so handleSceneActive's 15s grace is preserved.
                    // No transition/animation: it must be on screen synchronously before the
                    // snapshot, or an unobscured frame could still be captured mid-fade.
                    AppLockPrivacyCover()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: appLock.isLocked)
            .task {
                CrashSafeStartupDiagnostics.mark("app.scene.task.started")
                if !observersInstalled {
                    observersInstalled = true
                    keepaliveService.installObservers()
                    keepaliveService.onWakeRequested = { [weak environment = environment] in
                        guard let environment else { return }
                        Task { @MainActor in
                            await environment.sessionCoordinator.reconnectLast()
                        }
                    }
                }
            }
            .onChangeCompat(of: scenePhase) { phase in
                CrashSafeStartupDiagnostics.mark("app.scene.phase", details: "\(phase)")
                switch phase {
                case .background:
                    appLock.handleSceneBackground()
                    if environment.sessionCoordinator.lastEndpoint != nil {
                        // Checkpoint, don't fight suspension: flush the local
                        // journal baseline inside iOS's short background
                        // window. The remote session keeps running on the Mac
                        // regardless — the socket is a view, not the session.
                        environment.sessionCoordinator.checkpointForBackground()
                        keepaliveService.begin()
                    }
                case .inactive:
                    if environment.sessionCoordinator.lastEndpoint != nil {
                        keepaliveService.begin()
                    }
                case .active:
                    appLock.handleSceneActive()
                    keepaliveService.end()
                    Task { @MainActor in
                        await environment.sessionCoordinator.reconnectLast()
                    }
                @unknown default:
                    break
                }
            }
            // Slightly longer than the Mac default so the front-loaded gleam/wink/twinkle
            // beats in iosClient() finish before the cross-fade.
            .vampSplash(.iosClient(), minimumDuration: 2.2)
        }
    }

}
