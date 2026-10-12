#if DEBUG
import AppKit
import SwiftUI
import SharedModels
import SharedUtilities

/// Local, network-free manual regression fixture. Enabled only in a copied Debug
/// app with VampUXAudit=true in its Info.plist; never present in Release builds.
struct MacSessionUXPreview: View {
    @StateObject private var input = MacPreviewInput()
    @State private var viewOnly = false
    @State private var isCompactToolbar = true
    @State private var receiving = true
    @State private var focused = false
    @State private var showsStats = true
    @State private var showsHelp = false
    @State private var showDetails = false
    @State private var localText = "Local field"
    @State private var preferences = MacConnectionPreferences()
    @State private var lastTool = "None"
    private var readiness: MacInputReadiness {
        .resolve(connected: true, locked: false, choosingApp: false,
                 receivingVideo: receiving, viewOnly: viewOnly)
    }
    private var actions: [MacSessionAction] {
        [.init(id: "screenshot", title: "Save Screenshot…", symbol: "camera", enabled: receiving,
               shortcut: "s", perform: { lastTool = "Screenshot" })]
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Local field", text: $localText)
                Toggle("Video available", isOn: $receiving)
            }.padding(12)
            ZStack {
                MacPreviewSurface(input: input, enabled: readiness.canSendInput,
                                  keepsDisplayShortcutsLocal: preferences.keepsDisplayShortcutsLocal,
                                  focusChanged: { focused = $0 })
                VStack(spacing: 12) {
                    MacKeyboardFocusHint(readiness: readiness, keyboardFocused: focused)
                    Spacer()
                    Text("Local keyboard test").font(.title)
                    Text("Arrow events: \(input.arrowEvents)").font(.title2)
                    Text("Position: \(input.x), \(input.y)")
                    Text("Last key: \(input.lastKey)")
                    Text("Keyboard: \(focused ? "remote surface" : "this Mac")")
                    Text("Tool: \(lastTool)")
                    Spacer()
                }.padding().foregroundStyle(.white).allowsHitTesting(false)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .modifier(MacSessionWidthReader(isCompact: $isCompactToolbar))
        .toolbar { previewToolbar.compactSessionChrome() }
        .sheet(isPresented: $showsHelp) { MacKeyboardHelp(keepsDisplayShortcutsLocal: $preferences.keepsDisplayShortcutsLocal) }
        .overlay(alignment: .bottomLeading) {
            if showsStats {
                SessionToolbarLiveStats(framesPerSecond: 60, latencyMs: 8, bitrateKbps: 20000)
                    .padding(12).allowsHitTesting(false)
            }
        }
        .background(MacClientWindowConfigurator(extendsUnderTitleBar: false, hidesNativeTitle: true))
        .navigationTitle("Design Studio — Vamp Control")
        .preferredColorScheme(.dark)
    }

    @ToolbarContentBuilder
    private var previewToolbar: some ToolbarContent {
            ToolbarItem(placement: .navigation) {
                Button { showDetails.toggle() } label: {
                    SessionToolbarStatusPill(hostName: "Design Studio — Long Host Name", qualityColor: .green,
                        qualityLabel: "Local test", differentiateWithoutColor: false).frame(maxWidth: isCompactToolbar ? 170 : 220)
                }.buttonStyle(.plain)
                    .popover(isPresented: $showDetails) {
                        MacConnectionDetails(hostName: "Local test", transportConnected: true,
                            receivingVideo: receiving, readiness: readiness, keyboardFocused: focused,
                            unavailable: ["Clipboard", "File transfer", "Terminal", "Remote audio"])
                    }
            }
            ToolbarItem(placement: .primaryAction) { Menu("Desktop") { Button("Built-in Display") {}
                Button("Choose an app…") {} } }
            ToolbarItem(placement: .primaryAction) {
                Menu(isCompactToolbar ? "Fit" : "Fit Display") {
                    Button("Fit Display") { preferences.displayModeRaw = DisplayMappingEngine.DisplayMode.fitDisplay.rawValue }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                MacSessionAccessButton(viewOnly: $viewOnly, readiness: readiness, keyboardFocused: focused)
            }
            ToolbarItem(placement: .primaryAction) {
                MacSessionToolsMenu(actions: actions, canSendInput: readiness.canSendInput,
                    sendKey: { input.note(keyCode: $0.keyCode) }, showKeyboardHelp: { showsHelp = true },
                    showsStats: $showsStats, quickActionID: $preferences.quickActionID)
            }
            if !isCompactToolbar, let quick = actions.first(where: { $0.id == preferences.quickActionID }) {
                ToolbarItem(placement: .primaryAction) { MacSessionQuickAction(action: quick) }
            }
            ToolbarItem(placement: .primaryAction) { SessionToolbarDisconnectButton { receiving = false } }
        }

}

@MainActor
private final class MacPreviewInput: ObservableObject, MacRemoteInputHandling {
    var isEnabled = true
    @Published var arrowEvents = 0
    @Published var x = 0
    @Published var y = 0
    @Published var lastKey = "None"
    func updateViewGeometry(size: CGSize, pixelScale: Double) {}
    func updateDisplayMode(_ displayMode: DisplayMappingEngine.DisplayMode) {}
    func containsRemoteContent(_ point: CGPoint) -> Bool { true }
    func remoteContentRect(in viewSize: CGSize) -> CGRect? { CGRect(origin: .zero, size: viewSize) }
    func pointerMoved(to viewPoint: CGPoint) {}
    func pointerButton(_ button: MouseButton, action: ButtonAction, at viewPoint: CGPoint) {}
    func scrolled(deltaX: Double, deltaY: Double, isPrecise: Bool) {}
    func keyEvent(_ event: NSEvent, action: KeyAction) {
        guard isEnabled, action == .down else { return }
        note(keyCode: event.keyCode)
    }
    func note(keyCode: UInt16) {
        lastKey = "\(keyCode) / \(MacAssistantKeyMapping.name(for: keyCode) ?? "text")"
        guard (123...126).contains(keyCode) else { return }
        arrowEvents += 1
        if keyCode == 123 { x -= 1 }
        if keyCode == 124 { x += 1 }
        if keyCode == 125 { y += 1 }
        if keyCode == 126 { y -= 1 }
    }
}

private struct MacPreviewSurface: NSViewRepresentable {
    let input: MacPreviewInput
    let enabled: Bool
    let keepsDisplayShortcutsLocal: Bool
    let focusChanged: (Bool) -> Void
    func makeNSView(context: Context) -> RemoteStreamNSView {
        let view = RemoteStreamNSView()
        configure(view)
        return view
    }
    func updateNSView(_ view: RemoteStreamNSView, context: Context) { configure(view) }
    private func configure(_ view: RemoteStreamNSView) {
        view.input = input
        view.usesLocalCursor = true
        view.isInputEnabled = enabled
        view.keepsDisplayShortcutsLocal = keepsDisplayShortcutsLocal
        view.onKeyboardFocusChange = focusChanged
        input.isEnabled = enabled
    }
    static func dismantleNSView(_ view: RemoteStreamNSView, coordinator: ()) { view.stopInputCapture() }
}
#endif
