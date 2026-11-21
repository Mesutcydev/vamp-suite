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

    var body: some View {
        ControlHomeView(environment: environment, appLock: appLock)
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
