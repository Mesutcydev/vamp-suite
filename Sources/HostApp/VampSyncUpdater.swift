#if VAMP_MINI_HOST && os(macOS)
import Combine
#if !VAMP_APP_STORE && canImport(Sparkle)
import Sparkle
#endif
import AppKit

/// One updater for the lifetime of the menu-bar app. ObservableObject keeps
/// the update controls compatible with Vamp Sync's macOS 13 minimum.
@MainActor
final class VampSyncUpdater: ObservableObject {
    static var usesStoreUpdates: Bool {
        #if VAMP_APP_STORE
        true
        #else
        false
        #endif
    }

    #if !VAMP_APP_STORE && canImport(Sparkle)
    let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    init() {
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    func start() {
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
    #else
    @Published private(set) var canCheckForUpdates = true
    @Published private(set) var automaticallyChecksForUpdates = false

    func start() {}
    func checkForUpdates() {
        if let url = URL(string: "macappstore://showUpdatesPage") { NSWorkspace.shared.open(url) }
    }
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {}
    #endif
}
#endif
