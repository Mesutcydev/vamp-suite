import SwiftUI

@main
struct VampTerminalApp: App {
    @StateObject private var environment: ClientAppEnvironment
    @AppStorage("vampTerminal.appearance") private var appearance = "light"

    init() {
        _environment = StateObject(
            wrappedValue: ClientAppEnvironment.makeDefault(
                clientName: "Vamp Terminal",
                supportsTerminalOnlyHosts: true,
                clientProductRole: .terminal
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            VampTerminalHomeView(environment: environment)
                .preferredColorScheme(preferredColorScheme)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}
