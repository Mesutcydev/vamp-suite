#if canImport(UIKit)
import SwiftUI
import UIKit
import SwiftTerm
import Diagnostics
import SharedProtocol
import TransportWebRTC

private enum LegacyTerminalPresentation: String, CaseIterable, Identifiable {
    case stream
    case raw

    var id: String { rawValue }
    var title: String { self == .stream ? "Task chat" : "Raw terminal" }
    var icon: String { self == .stream ? "bubble.left.and.bubble.right" : "terminal" }
}

/// A bounded, readable transcript for the original Vamp remote client. The
/// PTY remains mounted underneath it, but the default presentation is a stable
/// task stream instead of a black rectangle that moves whenever the keyboard
/// changes the available height.
@MainActor
private final class LegacyTerminalChatStore: ObservableObject {
    enum Role: Equatable { case system, command, output, error }
    struct Block: Identifiable, Equatable {
        let id: UUID
        let role: Role
        var text: String
        var isStreaming: Bool
    }

    @Published private(set) var blocks: [Block] = []
    private var inputBuffer = Data()
    private var lastSequence: UInt64 = 0
    private var activeOutputID: UUID?
    private let maxBlocks = 160
    private let maxCharacters = 14_000

    func reset() {
        blocks = [Block(id: UUID(), role: .system, text: "Opening shell…", isStreaming: true)]
        inputBuffer.removeAll(keepingCapacity: true)
        lastSequence = 0
        activeOutputID = nil
    }

    func ingest(_ messages: [TerminalOutputMessage]) {
        for message in messages where message.sequence > lastSequence {
            lastSequence = message.sequence
            appendOutput(message.data)
        }
    }

    func recordInput(_ data: Data) {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0D || byte == 0x0A {
                submitCommand(String(decoding: inputBuffer, as: UTF8.self))
                inputBuffer.removeAll(keepingCapacity: true)
            } else if byte == 0x08 || byte == 0x7F {
                var text = String(decoding: inputBuffer, as: UTF8.self)
                if !text.isEmpty { text.removeLast() }
                inputBuffer = Data(text.utf8)
            } else if byte == 0x1B {
                index += 1
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) {
                    index += 1
                }
            } else if byte >= 0x20 {
                inputBuffer.append(byte)
            }
            index += 1
        }
    }

    func submitCommand(_ command: String) {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        finishOpening()
        append(Block(id: UUID(), role: .command, text: "$ \(value)", isStreaming: false))
        activeOutputID = nil
    }

    func appendFailure(_ message: String) {
        finishOpening()
        append(Block(id: UUID(), role: .error, text: message, isStreaming: false))
    }

    func update(state: ClientTerminalSessionManager.State) {
        switch state {
        case .open:
            finishOpening()
            if !blocks.contains(where: { $0.role == .system && $0.text == "Terminal is connected." }) {
                append(Block(id: UUID(), role: .system, text: "Terminal is connected.", isStreaming: false))
            }
        case .closed(_, _, let reason):
            finishOpening()
            let message: String
            if reason == "terminal-disabled" {
                message = "Terminal Mode is disabled on the Mac. Enable it in Vamp Host settings, then retry."
            } else if reason == "terminal-capacity" {
                message = "The Mac has reached its 8-terminal limit. Close a tab before retrying."
            } else if let reason, !reason.isEmpty {
                message = "Terminal closed · \(reason)"
            } else {
                message = "Terminal closed."
            }
            append(Block(id: UUID(), role: .error, text: message, isStreaming: false))
        case .idle, .opening:
            break
        }
    }

    var latestText: String {
        blocks.suffix(20).map(\.text).joined(separator: "\n")
    }

    private func appendOutput(_ data: Data) {
        let clean = Self.clean(data)
        guard !clean.isEmpty else { return }
        let normalized = clean.replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if let activeOutputID,
               let index = blocks.firstIndex(where: { $0.id == activeOutputID }),
               blocks[index].text.count + value.count < maxCharacters {
                blocks[index].text += "\n\(value)"
                blocks[index].isStreaming = true
            } else {
                let block = Block(id: UUID(), role: .output, text: value, isStreaming: true)
                activeOutputID = block.id
                append(block)
            }
        }
    }

    private func finishOpening() {
        for index in blocks.indices where blocks[index].role == .system && blocks[index].isStreaming {
            blocks[index].isStreaming = false
        }
    }

    private func append(_ block: Block) {
        blocks.append(block)
        if blocks.count > maxBlocks { blocks.removeFirst(blocks.count - maxBlocks) }
    }

    private static func clean(_ data: Data) -> String {
        let scalars = String(decoding: data, as: UTF8.self).unicodeScalars
        var result = String.UnicodeScalarView()
        var index = scalars.startIndex
        var skippingCSI = false
        var skippingOSC = false

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if skippingOSC {
                if scalar.value == 7 { skippingOSC = false }
                index = scalars.index(after: index)
                continue
            }
            if skippingCSI {
                if (0x40...0x7E).contains(scalar.value) { skippingCSI = false }
                index = scalars.index(after: index)
                continue
            }
            if scalar.value == 0x1B {
                let next = scalars.index(after: index)
                if next < scalars.endIndex {
                    if scalars[next].value == 0x5B {
                        skippingCSI = true
                        index = scalars.index(after: next)
                        continue
                    }
                    if scalars[next].value == 0x5D {
                        skippingOSC = true
                        index = scalars.index(after: next)
                        continue
                    }
                }
                index = next
                continue
            }
            if scalar.value == 0x08 || scalar.value == 0x7F {
                index = scalars.index(after: index)
                continue
            }
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D || scalar.value >= 0x20 {
                result.append(scalar)
            }
            index = scalars.index(after: index)
        }
        return String(result)
    }
}

/// Full-screen Terminal Mode for the original Vamp remote client. A SwiftTerm
/// PTY remains mounted for compatibility, while the default task stream keeps
/// commands and output readable on iPhone and iPad.
struct TerminalModeView: View {
    @ObservedObject var session: ClientTerminalSessionManager
    @StateObject private var input = TerminalInputController()
    @StateObject private var transcript = LegacyTerminalChatStore()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentation: LegacyTerminalPresentation = .stream
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var aiResult: String?
    @State private var aiThinking = false
    @State private var showAI = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            presentationBar
            ZStack {
                // Keep SwiftTerm mounted while switching presentation modes so
                // the PTY and its scrollback never close/reopen.
                SwiftTermContainer(
                    session: session,
                    controller: input,
                    onInput: { data in transcript.recordInput(data) }
                )
                // SwiftTerm is the authoritative VT screen buffer for both
                // presentation modes. The old stream overlay sanitized and
                // appended PTY chunks, which corrupted cursor movement and
                // ANSI TUIs before they reached the user.
                .opacity(1)
                .allowsHitTesting(true)
                .background(Color.black)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if presentation == .stream { commandComposer }
                specialKeysBar
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationBarHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            input.isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            input.isKeyboardVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalViewControlModifierReset)) { _ in
            input.ctrlActive = false
        }
        .onReceive(session.$output) { messages in
            transcript.ingest(messages)
        }
        .onChange(of: session.state) { _, state in
            transcript.update(state: state)
        }
        .onAppear {
            transcript.reset()
            let canOpen: Bool
            switch session.state {
            case .idle, .closed(_, _, _):
                canOpen = true
            case .opening, .open:
                canOpen = false
            }
            if canOpen {
                let didSend = session.open(cols: 80, rows: 24)
                if !didSend {
                    transcript.appendFailure("The terminal channel is not ready. Return to the host screen and reconnect.")
                }
            }
        }
        .onDisappear {
            session.close(reason: "view-dismissed")
        }
        .sheet(isPresented: $showAI) {
            NavigationStack {
                ScrollView {
                    if aiThinking {
                        ProgressView("Thinking…").padding()
                    } else if let aiResult {
                        Text(aiResult)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
                .navigationTitle("Terminal AI")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAI = false } } }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Close terminal")

            VStack(alignment: .leading, spacing: 2) {
                Text("Task chat")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)

            Spacer(minLength: 4)

            Menu {
                Button { presentation = .stream } label: { Label("Task chat", systemImage: "bubble.left.and.bubble.right") }
                Button { presentation = .raw } label: { Label("Raw terminal", systemImage: "terminal") }
                Button { copyTranscript() } label: { Label("Copy transcript", systemImage: "doc.on.doc") }
                Button { terminalExplain() } label: { Label("Explain output", systemImage: "sparkles") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .accessibilityLabel("Terminal actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.055))
    }

    private var presentationBar: some View {
        HStack(spacing: 6) {
            Text("SESSION")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 4)
            ForEach(LegacyTerminalPresentation.allCases) { mode in
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        presentation = mode
                    }
                } label: {
                    Label(mode.title, systemImage: mode.icon)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(presentation == mode ? .white : .white.opacity(0.55))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 32)
                        .background(
                            presentation == mode ? Color.white.opacity(0.15) : .clear,
                            in: Capsule(style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color(white: 0.08))
    }

    private var commandComposer: some View {
        HStack(spacing: 8) {
            Button {
                composerFocused.toggle()
            } label: {
                Image(systemName: composerFocused ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .accessibilityLabel(composerFocused ? "Hide keyboard" : "Show keyboard")

            TextField("Type a command…", text: $draft, axis: .vertical)
                .focused($composerFocused)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit(sendDraft)

            Button { pasteIntoComposer() } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 38, height: 40)
            }
            .accessibilityLabel("Paste from iPhone clipboard")

            Button { sendDraft() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 40, height: 40)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.canSendInput)
            .opacity(session.canSendInput ? 1 : 0.45)
            .accessibilityLabel("Send command")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(white: 0.10))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5) }
    }

    private var specialKeysBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                specialKey("ctrl", isOn: input.ctrlActive) { input.toggleCtrl() }
                specialKey("esc") { send(bytes: [0x1B]) }
                specialKey("tab") { send(bytes: [0x09]) }
                specialKey("⌃C") { send(bytes: [0x03]) }
                specialKey("↑") { send(bytes: [0x1B, 0x5B, 0x41]) }
                specialKey("↓") { send(bytes: [0x1B, 0x5B, 0x42]) }
                specialKey("←") { send(bytes: [0x1B, 0x5B, 0x44]) }
                specialKey("→") { send(bytes: [0x1B, 0x5B, 0x43]) }
                specialKey("⌃D") { send(bytes: [0x04]) }
                specialKey("⌃Z") { send(bytes: [0x1A]) }
                specialKey("paste", system: "doc.on.clipboard") { paste() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(Color(white: 0.075))
    }

    private func specialKey(
        _ title: String,
        system: String? = nil,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 4) {
                if let system { Image(systemName: system).font(.system(size: 11, weight: .semibold)) }
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(isOn ? .black : .white.opacity(0.9))
            .padding(.horizontal, 11)
            .frame(minWidth: 40, minHeight: 38)
            .background(isOn ? Color.white : Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var statusText: String {
        switch session.state {
        case .idle: return "Waiting to start"
        case .opening: return "Opening shell…"
        case .open: return "Connected"
        case .closed(let exit, let signal, let reason):
            if reason == "terminal-disabled" { return "Terminal Mode off" }
            if let signal { return "Signal \(signal)" }
            if let exit { return "Exited \(exit)" }
            return "Closed"
        }
    }

    private var statusColor: SwiftUI.Color {
        switch session.state {
        case .open: return .green
        case .opening: return .orange
        case .closed: return .red
        case .idle: return .white.opacity(0.45)
        }
    }

    private func send(bytes: [UInt8]) {
        let data = Data(bytes)
        transcript.recordInput(data)
        session.sendInput(data)
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        let data = Data(text.utf8)
        transcript.recordInput(data)
        session.sendInput(data)
    }

    private func pasteIntoComposer() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        draft += text
        composerFocused = true
    }

    private func sendDraft() {
        let command = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, session.canSendInput else { return }
        transcript.submitCommand(command)
        session.sendInput(Data((command + "\r").utf8))
        draft = ""
        composerFocused = true
    }

    private func copyTranscript() {
        UIPasteboard.general.string = transcript.latestText
    }

    private func terminalExplain() {
        let text = transcript.latestText
        guard !text.isEmpty else {
            aiResult = "No terminal output yet — run a command first."
            showAI = true
            return
        }
        aiThinking = true
        aiResult = nil
        showAI = true
        Task {
            let result = await TerminalAssistant.explain(output: text)
            await MainActor.run {
                aiResult = result ?? "On-device AI isn’t available (turn on Apple Intelligence in Settings)."
                aiThinking = false
            }
        }
    }
}

private struct LegacyTerminalStreamView: View {
    @ObservedObject var transcript: LegacyTerminalChatStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(transcript.blocks) { block in
                        LegacyTerminalBlockView(block: block)
                            .id(block.id)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
            .onChange(of: transcript.blocks) { _, _ in
                withAnimation(.easeOut(duration: 0.14)) {
                    proxy.scrollTo("latest", anchor: .bottom)
                }
            }
        }
        .background(Color.black)
    }
}

private struct LegacyTerminalBlockView: View {
    let block: LegacyTerminalChatStore.Block

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.56))
                if block.isStreaming {
                    ProgressView().controlSize(.mini).tint(accent)
                }
            }
            Text(block.text)
                .font(.system(size: 14, weight: block.role == .command ? .medium : .regular, design: .monospaced))
                .foregroundStyle(block.role == .command ? .white : .white.opacity(0.86))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 3)
                .padding(.vertical, 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent.opacity(0.24), lineWidth: 0.7)
        }
    }

    private var label: String {
        switch block.role {
        case .system: return "SYSTEM"
        case .command: return "YOU"
        case .output: return "TERMINAL OUTPUT"
        case .error: return "ATTENTION"
        }
    }

    private var icon: String {
        switch block.role {
        case .system: return "circle.fill"
        case .command: return "arrow.turn.down.right"
        case .output: return "chevron.right"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var accent: SwiftUI.Color {
        switch block.role {
        case .system: return .white.opacity(0.5)
        case .command: return .white
        case .output: return .cyan
        case .error: return .orange
        }
    }

    private var background: SwiftUI.Color {
        switch block.role {
        case .system: return Color.white.opacity(0.045)
        case .command: return Color.white.opacity(0.10)
        case .output: return Color(red: 0.025, green: 0.06, blue: 0.07)
        case .error: return Color.orange.opacity(0.10)
        }
    }
}

// MARK: - Terminal input controller

/// Bridges SwiftUI controls to the imperative `TerminalView` keyboard API.
/// Holds a weak reference to the live terminal view so the toolbar can show or
/// hide the software keyboard and arm the sticky Ctrl modifier.
@MainActor
final class TerminalInputController: ObservableObject {
    /// Whether the software keyboard is currently on screen. Driven by keyboard
    /// notifications so it stays accurate regardless of how it was dismissed.
    @Published var isKeyboardVisible = true
    /// Whether the sticky Ctrl modifier is armed for the next keypress.
    @Published var ctrlActive = false

    fileprivate weak var terminalView: TerminalView?

    fileprivate func attach(_ view: TerminalView) {
        terminalView = view
    }

    func toggleKeyboard() {
        guard let terminalView else { return }
        if isKeyboardVisible {
            _ = terminalView.resignFirstResponder()
            isKeyboardVisible = false
        } else {
            _ = terminalView.becomeFirstResponder()
            isKeyboardVisible = true
        }
    }

    func toggleCtrl() {
        let next = !ctrlActive
        ctrlActive = next
        terminalView?.controlModifier = next
        // Arming Ctrl only matters while typing, so make sure the keyboard is up.
        if next, !isKeyboardVisible {
            _ = terminalView?.becomeFirstResponder()
            isKeyboardVisible = true
        }
    }
}

// MARK: - SwiftTerm bridge

private struct SwiftTermContainer {
    @ObservedObject var session: ClientTerminalSessionManager
    let controller: TerminalInputController
    let onInput: ((Data) -> Void)?
}

extension SwiftTermContainer: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, onInput: onInput)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView()
        view.terminalDelegate = context.coordinator
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .black
        view.nativeForegroundColor = .white
        view.nativeBackgroundColor = .black
        context.coordinator.attach(view: view)
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.deliverPendingOutput(to: uiView)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: ClientTerminalSessionManager
        private let onInput: ((Data) -> Void)?
        /// Track delivery by the host's monotonic per-chunk `sequence`, NOT by array position.
        /// `session.output` is front-trimmed to a backlog cap (256), so an absolute index points at
        /// the wrong (or already-dropped) element after trimming and permanently stalls once the
        /// cap is hit — which froze terminal output after 256 chunks.
        private var lastDeliveredSequence: UInt64 = 0
        private weak var view: TerminalView?
        private var resizeTask: Task<Void, Never>?

        init(session: ClientTerminalSessionManager, onInput: ((Data) -> Void)?) {
            self.session = session
            self.onInput = onInput
        }

        @MainActor
        func attach(view: TerminalView) {
            self.view = view
            lastDeliveredSequence = 0
        }

        @MainActor
        func deliverPendingOutput(to view: TerminalView) {
            for message in session.output where message.sequence > lastDeliveredSequence {
                let bytes = [UInt8](message.data)
                view.feed(byteArray: bytes[...])
                lastDeliveredSequence = message.sequence
            }
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let input = Data(data)
            onInput?(input)
            Task { @MainActor [session] in
                session.sendInput(input)
            }
        }

        func scrolled(source: TerminalView, position: Double) { /* no-op */ }

        func setTerminalTitle(source: TerminalView, title: String) { /* no-op */ }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let cols = UInt16(clamping: newCols)
            let rows = UInt16(clamping: newRows)
            resizeTask?.cancel()
            resizeTask = Task { @MainActor [session] in
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                session.requestResize(cols: cols, rows: rows)
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { /* no-op */ }

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            Task { @MainActor in
                UIPasteboard.general.string = text
            }
        }

        func itermContent(source: TerminalView, content: ArraySlice<UInt8>) { /* no-op */ }

        func bell(source: TerminalView) { /* no-op */ }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            Task { @MainActor in
                UIApplication.shared.open(url)
            }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) { /* no-op */ }
    }
}
#else
import SwiftUI

struct TerminalModeView: View {
    @ObservedObject var session: ClientTerminalSessionManager
    var body: some View {
        EmptyView()
    }
}
#endif
