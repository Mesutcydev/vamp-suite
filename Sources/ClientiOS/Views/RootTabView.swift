import SwiftUI
import Discovery
import SharedModels

/// A single native home for Sync and Companion. Setup lives beside the empty state,
/// so first launch and everyday use share the same navigation.
@available(iOS 16.1, *)
struct RootTabView: View {
    @ObservedObject var environment: ClientAppEnvironment
    let appLock: AppLockService
    @ObservedObject private var paletteManager = PaletteManager.shared
    @AppStorage(ControlAppearance.storageKey) private var appearance = ControlAppearance.system
    @AppStorage("control.appearance.migrated") private var migratedAppearance = false
    /// One copy each for every tab: Home, Trusted and Settings read the same pairing and Pro state.
    @StateObject private var companion = BeetCodeRemoteSessionViewModel()
    @StateObject private var usage = DailyStreamingUsage()
    @StateObject private var unlock = StreamingUnlockStore()

    var body: some View {
        // The system tab bar: Liquid Glass on iOS 26, the standard bar before it.
        TabView {
            Tab("Macs", systemImage: "display") {
                ControlHomeView(environment: environment, appLock: appLock, companion: companion,
                                usage: usage, unlock: unlock)
            }
            Tab("Trusted", systemImage: "checkmark.shield") {
                ControlTrustedTab(environment: environment, companion: companion)
            }
            .accessibilityIdentifier("control.trusted")
            Tab("Settings", systemImage: "gearshape") {
                ControlSettingsView(environment: environment, appLock: appLock, companion: companion,
                                    unlock: unlock, usage: usage)
            }
            .accessibilityIdentifier("control.settings")
        }
        .preferredColorScheme(appearance.colorScheme)
        .tint(ControlDesign.accent)
        .environmentObject(paletteManager)
        .task {
            CrashSafeStartupDiagnostics.mark("root.startup.begin")
            // Legacy session tools share this palette; keep them consistent with Control.
            if paletteManager.selected != .glass { paletteManager.selected = .glass }
            if !migratedAppearance {
                if UserDefaults.standard.object(forKey: ControlAppearance.storageKey) == nil,
                   let oldLightMode = UserDefaults.standard.object(forKey: "client.ui.whiteMode") as? Bool {
                    appearance = oldLightMode ? .light : .dark
                }
                migratedAppearance = true
            }
            await environment.sharedHostsViewModel.start()
            CrashSafeStartupDiagnostics.mark("root.startup.end")
        }
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
