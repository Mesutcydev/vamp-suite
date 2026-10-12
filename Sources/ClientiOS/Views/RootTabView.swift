import SwiftUI
import Discovery
import SharedModels

/// The app now ships a single front-end: the friendly Simple Mode home (laptop grid →
/// tap to connect → fullscreen stream, with everything else behind the gear). The old
/// tabbed "developer" UI and its first-run mode chooser were retired. First launch shows
/// a one-screen welcome that explains how Vamp Control works and points to Vamp Host, then drops
/// straight into the home — no mode question, no fake terminal pairing.
@available(iOS 16.1, *)
struct RootTabView: View {
    @ObservedObject var environment: ClientAppEnvironment
    let appLock: AppLockService
    @ObservedObject private var paletteManager = PaletteManager.shared
    @AppStorage("client.ui.whiteMode") private var whiteModeEnabled = false
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var showWelcome = false

    var body: some View {
        ZStack {
            SimpleHomeView(environment: environment, appLock: appLock)

            if showWelcome {
                WelcomeStep(
                    knownHostCount: environment.sharedHostsViewModel.savedHosts.count,
                    start: { finishWelcome() },
                    skip: { finishWelcome() }
                )
                .background { PRAppBackground() }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .preferredColorScheme(whiteModeEnabled ? .light : .dark)
        // The chosen palette repaints the whole tree: PR.accent resolves from
        // the observed manager on every access, and this tint keeps native
        // controls (switches, links, spinners) in the same color.
        .tint(paletteManager.selected.color)
        .environmentObject(paletteManager)
        .task {
            CrashSafeStartupDiagnostics.mark("root.startup.begin")
            if !hasOnboarded {
                withAnimation(.linear(duration: 0.2)) { showWelcome = true }
            }
            await environment.sharedHostsViewModel.start()
            CrashSafeStartupDiagnostics.mark("root.startup.end")
        }
    }

    private func finishWelcome() {
        hasOnboarded = true
        AppHaptics.selection()
        withAnimation(.linear(duration: 0.2)) { showWelcome = false }
    }
}

extension Notification.Name {
    static let prRequestTabChange = Notification.Name("pr.request.tab.change")
}

#Preview("RootTabView") {
    if #available(iOS 16.1, *) {
        RootTabView(
            environment: ClientAppEnvironment.makeDefault(clientName: "Vamp Control"),
            appLock: AppLockService()
        )
    }
}
