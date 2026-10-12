import SwiftUI

#if os(macOS)
import AppKit
#endif

#if VAMP_TERMINAL_HOST && os(macOS)
@main
struct VampTerminalHostApp: App {
    /// SwiftUI may initialize the `App` value more than once while preserving
    /// its state storage. Constructing the host environment inline therefore
    /// created two independent signaling/browser runtimes in one process: the
    /// app delegate started the most recently assigned static environment and
    /// the window started the retained StateObject. Keep one process-wide
    /// environment so the UI, pairing code, and listeners share one owner.
    private static let terminalHostEnvironment = HostAppEnvironment.placeholder(mode: .terminalOnly)
    @StateObject private var environment = terminalHostEnvironment
    @StateObject private var closeBehaviorController = HostWindowCloseBehaviorController.shared
    @NSApplicationDelegateAdaptor(VampTerminalHostAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Vamp Terminal Host", id: "main") {
            VampTerminalHostShellView(environment: environment)
                .background {
                    VampTerminalHostWindowAccessor { window in
                        closeBehaviorController.attach(to: window)
                    }
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 700)

        // The window is the workspace; the menu-bar popover is the compact
        // always-available control surface. It keeps the host recognizable
        // after the dashboard is closed or the app is launched at login.
        MenuBarExtra {
            VampTerminalHostMenuBarContent(
                environment: environment,
                closeBehaviorController: closeBehaviorController
            )
        } label: {
            VampTerminalHostTrayLabel(environment: environment)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class VampTerminalHostAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        startRuntimeWhenReady(attempt: 0)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if HostWindowCloseBehaviorController.shared.bringExistingWindowFront() {
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        HostAppEnvironment.shared?.publishWidgetOffline(snapshotNamespace: "Vamp Terminal Host")
    }

    private func startRuntimeWhenReady(attempt: Int) {
        if let environment = HostAppEnvironment.shared {
            // Keep the terminal-only host's trust request and status isolated
            // from the full Vamp Host when both apps are installed. This is
            // also the file consumed by the light host's bundled `vamp` CLI,
            // so pairing approval does not silently target the wrong product.
            environment.activateWidgetBridge(
                hostName: environment.hostIdentity.displayName,
                snapshotNamespace: "Vamp Terminal Host"
            )
            // The retained scene environment owns runtime startup from its
            // `.task`. Starting through this static app-delegate lookup as
            // well can target a transient environment created during SwiftUI
            // app initialization, producing two pairing-code owners and a
            // self-inflicted port conflict in one process.
            return
        }

        guard attempt < 50 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.startRuntimeWhenReady(attempt: attempt + 1)
        }
    }
}

private struct VampTerminalHostMenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var environment: HostAppEnvironment
    @ObservedObject var closeBehaviorController: HostWindowCloseBehaviorController

    @State private var tailscaleInfo: TailscaleConnectionInfo?
    @State private var tailscaleInstalled = false
    @State private var copiedValue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            connectionSummary

            Button {
                closeBehaviorController.showMainWindow(using: openWindow)
            } label: {
                Label("Open Dashboard", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 8) {
                if isRunning {
                    Button(role: .destructive) {
                        Task { await environment.stopRuntime() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await environment.startRuntimeIfNeeded() }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    Task {
                        await environment.stopRuntime()
                        await environment.startRuntimeIfNeeded()
                    }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if let browserURL {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("Safari control", systemImage: "safari")
                            .font(.callout.weight(.semibold))
                        Spacer(minLength: 0)
                        Text("READY")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                    }

                    HStack(spacing: 8) {
                        Text(browserURL)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            copy(browserURL)
                        } label: {
                            Image(systemName: copiedValue == browserURL ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy Safari address")
                    }

                    if !environment.browserControlStatus.pairingCode.isEmpty {
                        HStack {
                            Text("Pairing code")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(environment.browserControlStatus.pairingCode)
                                .font(.caption.monospaced().weight(.semibold))
                                .textSelection(.enabled)
                        }
                    }

                    if let pairingURL = browserPairingURL {
                        VStack(alignment: .leading, spacing: 9) {
                            HostBrowserPairingQRCode(pairingURL: pairingURL)
                                .frame(maxWidth: .infinity, alignment: .center)
                            Label("Scan to pair", systemImage: "qrcode")
                                .font(.callout.weight(.semibold))
                            Text("Opens Safari on the private Tailscale address and fills the current code.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Rotate code") {
                                environment.rotateBrowserPairingCode()
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Divider()

            Toggle("Start at Login", isOn: Binding(
                get: { environment.startAtLoginEnabled },
                set: { environment.setStartAtLogin($0) }
            ))

            HStack {
                Button {
                    NSApp.hide(nil)
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 318)
        .task {
            await refreshTailscale()
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            VampTerminalHostMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Vamp Terminal Host")
                    .font(.headline)
                Text("Up to 8 terminal tabs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VampTerminalHostMenuStatusBadge(text: statusTitle, color: statusColor)
        }
    }

    private var connectionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusDescription)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Host")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(environment.hostIdentity.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if let tailscaleInfo {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Tailscale")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(tailscaleInfo.connectAddress)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button {
                        copy(tailscaleInfo.connectAddress)
                    } label: {
                        Image(systemName: copiedValue == tailscaleInfo.connectAddress ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy Tailscale address")
                }
            } else {
                HStack(spacing: 7) {
                    Image(systemName: tailscaleInstalled ? "network.slash" : "network")
                    Text(tailscaleInstalled ? "Tailscale is installed but offline" : "Tailscale not detected")
                }
                .font(.caption)
                .foregroundStyle(tailscaleInstalled ? .orange : .secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var browserURL: String? {
        guard environment.browserControlStatus.running,
              let port = environment.browserControlStatus.port else { return nil }
        if let tailscaleInfo {
            return tailscaleInfo.browserControlURL(port: port)
        }
        return nil
    }

    private var browserPairingURL: String? {
        guard let browserURL,
              !environment.browserControlStatus.pairingCode.isEmpty else { return nil }
        return HostBrowserPairingLink.make(baseURL: browserURL)
    }

    private var isRunning: Bool {
        environment.sessionCoordinator.phase != .idle
    }

    private var statusTitle: String {
        if environment.browserControlStatus.running,
           environment.sessionCoordinator.phase == .error {
            return "READY"
        }
        switch environment.sessionCoordinator.phase {
        case .streaming: return "LIVE"
        case .advertising, .awaitingClient: return "READY"
        case .idle: return "OFFLINE"
        case .error: return "ERROR"
        default: return "CONNECTING"
        }
    }

    private var statusDescription: String {
        if environment.browserControlStatus.running,
           environment.sessionCoordinator.phase == .error {
            return "Ready for terminal clients"
        }
        switch environment.sessionCoordinator.phase {
        case .streaming:
            return "A terminal client is connected"
        case .advertising, .awaitingClient:
            return "Ready for terminal clients"
        case .idle:
            return "Host runtime is stopped"
        case .error:
            return "Host runtime needs attention"
        default:
            return "Preparing secure session"
        }
    }

    private var statusColor: Color {
        if environment.browserControlStatus.running,
           environment.sessionCoordinator.phase == .error {
            return .green
        }
        switch environment.sessionCoordinator.phase {
        case .streaming: return .blue
        case .advertising, .awaitingClient: return .green
        case .error: return .orange
        default: return .secondary
        }
    }

    private func refreshTailscale() async {
        let snapshot = await Task.detached(priority: .utility) {
            getTailscaleDetectionSnapshot()
        }.value
        guard !Task.isCancelled else { return }
        tailscaleInfo = snapshot.info
        tailscaleInstalled = snapshot.installed
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedValue = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedValue == value { copiedValue = nil }
        }
    }
}

private struct VampTerminalHostTrayLabel: View {
    @ObservedObject var environment: HostAppEnvironment

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: makeVampTerminalHostMenuBarTemplateIcon())
                .frame(width: 18, height: 18)
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
                .overlay {
                    Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1)
                }
                .offset(x: 1, y: 1)
        }
        .frame(width: 19, height: 19)
        .help("Vamp Terminal Host · \(statusTitle)")
        .accessibilityLabel("Vamp Terminal Host, \(statusTitle)")
    }

    private var statusTitle: String {
        if environment.browserControlStatus.running,
           environment.sessionCoordinator.phase == .error {
            return "ready"
        }
        switch environment.sessionCoordinator.phase {
        case .streaming: return "connected"
        case .advertising, .awaitingClient: return "ready"
        case .idle: return "offline"
        case .error: return "error"
        default: return "connecting"
        }
    }

    private var statusColor: Color {
        if environment.browserControlStatus.running,
           environment.sessionCoordinator.phase == .error {
            return .green
        }
        switch environment.sessionCoordinator.phase {
        case .streaming: return .blue
        case .advertising, .awaitingClient: return .green
        case .error: return .orange
        default: return .secondary
        }
    }
}

private struct VampTerminalHostMenuStatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.11), in: Capsule())
            .overlay { Capsule().stroke(color.opacity(0.25), lineWidth: 0.5) }
    }
}

private struct VampTerminalHostWindowAccessor: NSViewRepresentable {
    let onResolveWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolveWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolveWindow(window)
            }
        }
    }
}
#endif
