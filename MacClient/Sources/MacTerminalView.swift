import AppKit
import SwiftUI
import SwiftTerm

/// Full-window Terminal Mode for the Mac client: a SwiftTerm AppKit terminal
/// wired to the shared `ClientTerminalSessionManager` (a remote PTY streamed
/// over the WebRTC data channel). The Mac has a hardware keyboard, so — unlike
/// the iOS terminal — there's no software keyboard or modifier-key accessory bar.
struct MacTerminalScreen: View {
    @ObservedObject var session: ClientTerminalSessionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("w", modifiers: .command)

                Spacer()
                Text(statusText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                // Balances the Close button so the status stays centered.
                Color.clear.frame(width: 64, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(white: 0.06))

            MacSwiftTermView(session: session)
        }
        .frame(minWidth: 680, minHeight: 420)
        .background(Color.black)
        .onAppear { session.open(cols: 80, rows: 24) }
        .onDisappear { session.close(reason: "view-dismissed") }
    }

    private var statusText: String {
        switch session.state {
        case .idle: return "Terminal"
        case .opening: return "Opening terminal…"
        case .open: return "Terminal — connected"
        case .closed(let exitCode, _, let reason):
            if let reason, !reason.isEmpty { return "Closed — \(reason)" }
            if let exitCode { return "Closed — exit \(exitCode)" }
            return "Closed"
        }
    }
}

// MARK: - SwiftTerm bridge

/// Wraps SwiftTerm's AppKit `TerminalView` and stitches the emulator to the
/// shared session manager: emulator keystrokes → `sendInput`, host output →
/// `feed(byteArray:)`, layout changes → `requestResize`.
private struct MacSwiftTermView: NSViewRepresentable {
    @ObservedObject var session: ClientTerminalSessionManager

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView()
        view.terminalDelegate = context.coordinator
        view.nativeForegroundColor = .white
        view.nativeBackgroundColor = .black
        context.coordinator.reset()
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.deliverPendingOutput(to: nsView)
        // Grab keyboard focus once the terminal is in a window.
        if let window = nsView.window, window.firstResponder !== nsView, !context.coordinator.hasFocused {
            window.makeFirstResponder(nsView)
            context.coordinator.hasFocused = true
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: ClientTerminalSessionManager
        private var deliveredCount = 0
        var hasFocused = false

        init(session: ClientTerminalSessionManager) {
            self.session = session
        }

        @MainActor
        func reset() {
            deliveredCount = 0
            hasFocused = false
        }

        @MainActor
        func deliverPendingOutput(to view: TerminalView) {
            let outputs = session.output
            guard outputs.count > deliveredCount else { return }
            for i in deliveredCount..<outputs.count {
                let bytes = [UInt8](outputs[i].data)
                view.feed(byteArray: bytes[...])
            }
            deliveredCount = outputs.count
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let input = Data(data)
            Task { @MainActor [session] in session.sendInput(input) }
        }

        func scrolled(source: TerminalView, position: Double) { /* no-op */ }

        func setTerminalTitle(source: TerminalView, title: String) { /* no-op */ }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let cols = UInt16(clamping: newCols)
            let rows = UInt16(clamping: newRows)
            Task { @MainActor [session] in session.requestResize(cols: cols, rows: rows) }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { /* no-op */ }

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            Task { @MainActor in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }

        func bell(source: TerminalView) {
            NSSound.beep()
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { /* no-op */ }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { /* no-op */ }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) { /* no-op */ }
    }
}
