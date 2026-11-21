#if !VAMP_APP_STORE && canImport(Sparkle)
import Combine
import Sparkle
import SwiftUI

/// Website builds update in place through Sparkle. The Mac App Store build compiles this
/// out, because the store delivers its updates.
@MainActor
final class MacUpdater: ObservableObject {
    static let shared = MacUpdater()

    @Published private(set) var canCheckForUpdates = false
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var observation: AnyCancellable?

    private init() {
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// "Check for Updates…" in the application menu.
struct MacUpdateCommands: View {
    @ObservedObject private var updater = MacUpdater.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
#else
import SwiftUI

/// The App Store build has no in-app updater.
struct MacUpdateCommands: View {
    var body: some View {
        EmptyView()
    }
}
#endif
