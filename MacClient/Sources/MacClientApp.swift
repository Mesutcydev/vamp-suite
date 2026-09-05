import AppKit
import SwiftUI
import SharedModels
import SharedUtilities

/// Whether the optional menu-bar status item is shown.
///
/// This used to be an either/or: "Window Toolbar" **or** "Menu Bar Item". That
/// framing was a trap — choosing the menu bar removed the session toolbar
/// entirely and left a two-item menu, so display sizing, clipboard, screenshot,
/// file transfer, terminal, Screen AI, audio, view-only and stats all silently
/// disappeared. The toolbar is now always present and the menu bar item is a
/// supplement. The storage key and values are unchanged so anyone who had
/// picked "Menu Bar Item" keeps their status item.
enum MacMenuBarPreference {
    static let storageKey = "client.connectionControls.presentation"
    static let enabledValue = "menuBarItem"
    static let disabledValue = "floatingPill"

    static func isEnabled(_ storedValue: String) -> Bool {
        storedValue == enabledValue
    }

    static func storedValue(enabled: Bool) -> String {
        enabled ? enabledValue : disabledValue
    }
}

@main
struct MacClientApp: App {
    @StateObject private var environment = MacClientEnvironmentFactory.make()
    @StateObject private var menuBarController = MacMenuBarController()
    @AppStorage(MacMenuBarPreference.storageKey)
    private var menuBarPreference = MacMenuBarPreference.disabledValue

    private static var versionString: String {
        "Version " + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if Bundle.main.object(forInfoDictionaryKey: "VampUXAudit") as? Bool == true {
                MacSessionUXPreview()
            } else {
                clientWindow
            }
            #else
            clientWindow
            #endif
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 600)
        .commands {
            CommandMenu("Session") {
                MacRefreshCommand(environment: environment)
                Divider()
                MacDisconnectCommand(environment: environment)
            }
            CommandGroup(after: .toolbar) { MacDisplayModeCommands() }
        }
        Settings { MacSettingsScreen(environment: environment) }
    }

    private var clientWindow: some View {
        MacShellView(environment: environment)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    menuBarController.configure(environment: environment)
                    menuBarController.setEnabled(MacMenuBarPreference.isEnabled(menuBarPreference))
                }
                .onChange(of: menuBarPreference) { newValue in
                    menuBarController.setEnabled(MacMenuBarPreference.isEnabled(newValue))
                }
                .vampSplashWindow(.macClient(version: Self.versionString))
    }
}

/// Extends the Vamp backdrop up through the title bar and keeps the window's
/// own surface opaque.
///
/// Two separate things were wrong before. The window was forced fully
/// transparent, so the desktop wallpaper — not the app — decided the contrast
/// behind every label. And the title bar stayed opaque on top of that, leaving a
/// hard seam across the top of the window. The window is now opaque and painted
/// with the product's backdrop art, while the title bar is transparent so that
/// art runs behind the toolbar as one continuous glass surface.
struct MacClientWindowConfigurator: NSViewRepresentable {
    /// True on the host list, where the backdrop art should run behind the
    /// toolbar as one continuous glass surface. False during a session: a
    /// full-size content view would push the remote video under the title bar,
    /// putting the top of the remote screen behind the controls and floating
    /// those controls over whatever the remote Mac happens to be showing.
    let extendsUnderTitleBar: Bool
    /// The host list draws its own centred wordmark, so AppKit's title — which
    /// it wedges in beside the leading toolbar items — is hidden there. Sessions
    /// also hide it because the status control already names the remote Mac.
    let hidesNativeTitle: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window, isFirstConfiguration: true) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window, isFirstConfiguration: false) }
    }

    private func configure(_ window: NSWindow?, isFirstConfiguration: Bool) {
        guard let window else { return }
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = extendsUnderTitleBar
        if extendsUnderTitleBar {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
        window.toolbarStyle = .unifiedCompact
        window.toolbar?.showsBaselineSeparator = !extendsUnderTitleBar
        window.titleVisibility = hidesNativeTitle ? .hidden : .visible

        guard isFirstConfiguration else { return }
        // AppKit makes the first text field in the window key on launch. The only
        // one here is "Add a Mac by IP", so the app opened with a blue focus ring
        // shouting for attention before the user had any intent to type.
        window.initialFirstResponder = nil
        if window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
        }
    }
}

/// Menu command to rescan the local network for hosts (⌘R). Disabled while a
/// session is live, where the hosts list isn't on screen.
private struct MacRefreshCommand: View {
    @ObservedObject var environment: ClientAppEnvironment
    @ObservedObject private var coordinator: ClientSessionCoordinator
    @FocusedObject private var assistant: MacAssistantSession?

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        self.coordinator = environment.sessionCoordinator
    }

    var body: some View {
        Button("Refresh Hosts") {
            Task { await environment.sharedHostsViewModel.refresh() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled((coordinator.phase != .idle && coordinator.phase != .error) || assistant?.connected != nil)
    }
}

/// Menu command to end the active session (⇧⌘D).
private struct MacDisconnectCommand: View {
    @ObservedObject var environment: ClientAppEnvironment
    @ObservedObject private var coordinator: ClientSessionCoordinator
    @FocusedObject private var assistant: MacAssistantSession?

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        self.coordinator = environment.sessionCoordinator
    }

    var body: some View {
        Button("Disconnect from Host") {
            if let assistant, assistant.connected != nil {
                assistant.disconnect()
            } else {
                Task { await coordinator.endSession() }
            }
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(coordinator.phase == .idle && assistant?.connected == nil)
    }
}

/// Commands edit only the active connection; two windows never share sizing.
private struct MacDisplayModeCommands: View {
    @FocusedBinding(\.remoteDisplayMode) private var displayModeRaw: String?
    @FocusedValue(\.keepsDisplayShortcutsLocal) private var keepsDisplayShortcutsLocal

    var body: some View {
        Group {
            Button("Fit Display") { displayModeRaw = DisplayMappingEngine.DisplayMode.fitDisplay.rawValue }
                .keyboardShortcut(keepsDisplayShortcutsLocal == false ? nil : KeyboardShortcut("0", modifiers: .command))
            Button("Fill Window") { displayModeRaw = DisplayMappingEngine.DisplayMode.fillScreen.rawValue }
                .keyboardShortcut(keepsDisplayShortcutsLocal == false ? nil : KeyboardShortcut("1", modifiers: .command))
            Button("Actual Size") { displayModeRaw = DisplayMappingEngine.DisplayMode.actualSize.rawValue }
                .keyboardShortcut(keepsDisplayShortcutsLocal == false ? nil : KeyboardShortcut("2", modifiers: .command))
        }
        .disabled(displayModeRaw == nil)
    }
}
