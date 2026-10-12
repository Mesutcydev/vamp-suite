import Combine
import CryptoKit
import Foundation
import SharedProtocol
import TransportWebRTC

/// Provider launch profiles are shared with the package-level workspace model
/// so tests can validate stable tab identity without importing the app target's
/// SwiftUI-only visual layer.
enum VampAgentProvider: String, CaseIterable, Identifiable {
    case openCode
    case pi
    case commandCode
    case chatGPT
    case claude
    case kimi
    case qwen
    case codex
    case aider
    case grok
    case gemini

    var id: String { rawValue }

    var sessionDisplayName: String {
        switch self {
        case .openCode: return "OpenCode"
        case .pi: return "Pi"
        case .commandCode: return "CommandCode"
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        case .kimi: return "Kimi"
        case .qwen: return "Qwen"
        case .codex: return "Codex"
        case .aider: return "Aider"
        case .grok: return "Grok"
        case .gemini: return "Gemini"
        }
    }

    var semanticProvider: AgentProviderKind? {
        switch self {
        case .grok: return .grok
        case .openCode: return .openCode
        case .claude: return .claude
        case .codex, .chatGPT: return .codex
        case .pi: return .pi
        case .commandCode: return .commandCode
        case .kimi: return .kimi
        case .qwen: return .qwen
        case .aider: return .aider
        case .gemini: return .gemini
        }
    }
}

/// Input origins keep semantic chat events separate from raw terminal bytes.
/// A VT screen can echo, repaint, and reorder bytes; it is never a source of
/// truth for what the user submitted in Chat.
enum TerminalInputOrigin {
    case chatComposer
    case rawTerminalKeyboard
    case launcher
    case system
    case permissionResponse
}

enum AgentSemanticEvent {
    case message(String)
    case thinking(String?)
    case taskPlan(SessionTaskEvent)
    case permissionRequested(String?)
    case completed
}

/// Adapter input is a stable semantic block supplied by an agent integration,
/// never a VT screen snapshot. Providers can replace this conservative
/// fallback with a native protocol adapter without changing the UI.
protocol AgentSessionAdapter {
    var provider: VampAgentProvider? { get }
    func consume(semanticText: String, sessionID: UUID, terminalID: UUID) -> [AgentSemanticEvent]
}

struct ConservativeAgentSessionAdapter: AgentSessionAdapter {
    let provider: VampAgentProvider?

    func consume(semanticText: String, sessionID: UUID, terminalID: UUID) -> [AgentSemanticEvent] {
        guard let plan = SessionTaskPlanDetector.infer(
            from: semanticText,
            sessionID: sessionID,
            terminalID: terminalID,
            title: "Inferred plan"
        ) else { return [] }
        return [.taskPlan(.planCreated(plan))]
    }
}

/// The task-chat projection of one terminal session. It deliberately stores
/// only events Vamp knows semantically. PTY output belongs to SwiftTerm's VT
/// screen buffer and must never be scraped back into this transcript.
@MainActor
final class TerminalChatStore: ObservableObject {
    enum ApprovalChoice: Equatable {
        case once
        case always
        case deny
    }

    struct PendingApproval: Identifiable, Equatable {
        let id: UUID
        let command: String
        let identity: String
    }
    enum Role: Equatable {
        case system
        case command
        case output
        case success
        case warning
        case error
        case progress
    }

    struct Block: Identifiable, Equatable {
        let id: UUID
        var role: Role
        var title: String?
        var text: String
        var isStreaming: Bool

        init(
            id: UUID = UUID(),
            role: Role,
            title: String? = nil,
            text: String,
            isStreaming: Bool = false
        ) {
            self.id = id
            self.role = role
            self.title = title
            self.text = text
            self.isStreaming = isStreaming
        }
    }

    struct ActivityEvent: Identifiable, Equatable {
        let id: UUID
        let date: Date
        let text: String

        init(id: UUID = UUID(), date: Date = .now, text: String) {
            self.id = id
            self.date = date
            self.text = text
        }
    }

    @Published private(set) var blocks: [Block]
    @Published private(set) var activityEvents: [ActivityEvent] = []
    @Published private(set) var taskPlan: SessionTaskPlan?
    @Published private(set) var pendingApproval: PendingApproval?

    private let tabTitle: String
    private let semanticSessionID: UUID?
    private let taskPlanPersistenceKey: String?
    private var taskPlanCoordinator: SessionTaskCoordinator
    private var didMarkReady = false
    private var didMarkClosed = false
    private let maxBlocks = 180
    private let maxActivityEvents = 120
    private var alwaysAllowedCommands: Set<String> = []
    private var semanticStream = TerminalSemanticStreamDecoder()
    /// A command-scoped projection used only after an exact Chat composer
    /// submission. Interactive applications can repaint or clear text that
    /// existed before submission, so slicing a lifetime transcript at a
    /// String index is not a stable response boundary.
    private var responseSemanticStream: TerminalSemanticStreamDecoder?
    private var latestSemanticText = ""
    private var hasChatSubmission = false
    private var lastSubmittedCommand: String?

    init(tabTitle: String, sessionID: UUID? = nil) {
        self.tabTitle = tabTitle
        self.semanticSessionID = sessionID
        self.taskPlanPersistenceKey = sessionID.map { "com.mesutcy.vamp-terminal.task-plan.\($0.uuidString)" }
        if let key = self.taskPlanPersistenceKey,
           let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(SessionTaskCoordinator.self, from: data) {
            self.taskPlanCoordinator = saved
            self.taskPlan = saved.plan
        } else {
            self.taskPlanCoordinator = SessionTaskCoordinator()
            self.taskPlan = nil
        }
        self.blocks = [
            Block(
                role: .system,
                title: "System",
                text: "\(tabTitle) is opening a shell…",
                isStreaming: true
            )
        ]
    }

    func recordStartupCommand(_ command: String) {
        recordActivity("Launcher started · \(command)")
    }

    /// Compatibility hook for raw-terminal input. Raw key events are sent to
    /// the PTY only; they are intentionally not reconstructed as Chat cards.
    func recordInput(_ data: Data) {
        guard !data.isEmpty else { return }
        recordActivity("Terminal input · \(data.count) bytes")
    }

    /// Converts the process byte stream into a semantic, append-only Chat
    /// projection. This happens before VT rendering and never reads the
    /// terminal screen. ANSI/OSC controls are consumed incrementally so split
    /// packets cannot leak escape fragments into cards.
    func appendOutput(_ data: Data, provider: VampAgentProvider? = nil) {
        guard !data.isEmpty else { return }
        let text = semanticStream.consume(data) ?? ""
        if !text.isEmpty { latestSemanticText = text }
        finishOpeningMessage()
        // Supported providers have a machine-readable semantic channel. Their
        // PTY remains mounted for Terminal mode, but its cursor repaints and
        // echoes must never be projected into Chat or task cards.
        if provider?.semanticProvider != nil { return }
        // A PTY startup banner or alternate-screen repaint is not an agent
        // message. Keep it in the mounted VT terminal and start Chat output
        // only at the exact boundary created by a composer submission.
        guard hasChatSubmission else {
            if taskPlan == nil, let semanticSessionID {
                consumeSemanticAgentOutput(
                    text,
                    provider: provider,
                    sessionID: semanticSessionID,
                    terminalID: semanticSessionID
                )
            }
            return
        }
        guard var responseDecoder = responseSemanticStream,
              let decodedResponse = responseDecoder.consume(data) else { return }
        responseSemanticStream = responseDecoder
        var response = decodedResponse
        if provider == nil {
            response = Self.removingLeadingShellEcho(
                from: response,
                command: lastSubmittedCommand
            )
            response = Self.removingTrailingShellPrompt(from: response)
        }
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        blocks.removeAll { $0.role == .progress && $0.isStreaming }
        let identity = provider?.sessionDisplayName ?? tabTitle
        if let index = blocks.lastIndex(where: { $0.role == .output && $0.isStreaming }) {
            blocks[index].title = identity
            blocks[index].text = response
        } else {
            append(Block(role: .output, title: identity, text: response, isStreaming: true))
        }
        if taskPlan == nil, let semanticSessionID {
            consumeSemanticAgentOutput(
                text,
                provider: provider,
                sessionID: semanticSessionID,
                terminalID: semanticSessionID
            )
        }
    }

    func requestApproval(for command: String, provider: VampAgentProvider?) -> Bool {
        if alwaysAllowedCommands.contains(command) { return false }
        pendingApproval = PendingApproval(
            id: UUID(),
            command: command,
            identity: provider?.sessionDisplayName ?? "Shell"
        )
        recordActivity("Approval requested")
        return true
    }

    func resolveApproval(_ choice: ApprovalChoice) -> String? {
        guard let approval = pendingApproval else { return nil }
        pendingApproval = nil
        switch choice {
        case .deny:
            append(Block(role: .warning, title: "Denied", text: approval.command))
            recordActivity("Command denied")
            return nil
        case .always:
            alwaysAllowedCommands.insert(approval.command)
            return approval.command
        case .once:
            return approval.command
        }
    }

    func markReady() {
        guard !didMarkReady, !didMarkClosed else { return }
        didMarkReady = true
        finishOpeningMessage()
        recordActivity("PTY ready")
    }

    func markClosed(reason: String?) {
        guard !didMarkClosed else { return }
        let hadReady = didMarkReady
        didMarkClosed = true
        finishOpeningMessage()
        let normalizedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFailure = !hadReady || normalizedReason == "terminal-start-timeout"
            || normalizedReason == "terminal-disabled"
            || normalizedReason == "terminal-capacity"
            || normalizedReason == "workspace-unavailable"
            || normalizedReason == "workspace-mismatch"
            || normalizedReason == "eof"
            || normalizedReason == "shell-exited"
            || normalizedReason?.hasPrefix("forkpty failed") == true
            || normalizedReason?.hasPrefix("read-error") == true
            || normalizedReason?.hasSuffix("-not-installed") == true
        let text: String
        if normalizedReason == "terminal-disabled" {
            text = "Terminal Mode is disabled on the host. Enable it in Vamp Host settings and retry."
        } else if normalizedReason == "terminal-capacity" {
            text = "The host has reached its 8-terminal limit. Close another tab before opening one."
        } else if normalizedReason == "terminal-start-timeout" {
            text = "The shell did not start. Check Terminal Mode on the host, then retry this tab."
        } else if normalizedReason == "workspace-unavailable" {
            text = "That workspace is no longer available on the Mac. Refresh workspaces and choose another folder."
        } else if normalizedReason == "workspace-mismatch" {
            text = "The selected workspace changed before launch. Refresh workspaces and try again."
        } else if !hadReady && (normalizedReason == "eof" || normalizedReason == "shell-exited") {
            text = "The host shell exited before it became ready. Check Terminal Mode and retry this tab."
        } else if normalizedReason?.hasPrefix("forkpty failed") == true {
            text = "The host could not create a shell. Check macOS permissions, then retry this tab."
        } else if normalizedReason?.hasPrefix("read-error") == true {
            text = "The host shell stopped reading before it became ready. Retry this tab."
        } else if let normalizedReason, normalizedReason.hasSuffix("-not-installed") {
            // The host reports a launcher whose CLI is missing as
            // "<tool>-not-installed" (e.g. "opencode-not-installed"). Surface a
            // plain, actionable message instead of the raw reason token. Agent
            // presets also run inside tmux, so name it as a likely prerequisite.
            let tool = String(normalizedReason.dropLast("-not-installed".count))
            let toolName = tool.isEmpty ? tabTitle : tool
            text = "\(toolName) isn't installed on the Mac. Install it (and tmux, which the agent launchers use) on the host, then retry this tab."
        } else if let normalizedReason, !normalizedReason.isEmpty {
            text = "\(tabTitle) closed · \(normalizedReason)"
        } else {
            text = "\(tabTitle) closed."
        }
        recordActivity(text)
        if isFailure {
            append(Block(role: .error, title: "Terminal unavailable", text: text))
        }
    }

    func prepareForRetry() {
        guard didMarkClosed else { return }
        didMarkClosed = false
        didMarkReady = false
        append(
            Block(
                role: .system,
                title: "System",
                text: "\(tabTitle) is trying again…",
                isStreaming: true
            )
        )
    }

    /// Records the exact immutable value submitted by the Chat composer.
    /// Whitespace inside the message is preserved; only an empty outer value
    /// is rejected. The same value is then sent to the PTY by the workspace.
    func recordChatSubmission(_ rawCommand: String, provider: VampAgentProvider?) {
        let command = rawCommand.replacingOccurrences(of: "\u{0}", with: "")
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        finishOpeningMessage()
        // Start a fresh byte-stream decoder at the canonical submit boundary.
        // Never reconstruct a response by slicing mutable terminal state.
        responseSemanticStream = TerminalSemanticStreamDecoder()
        hasChatSubmission = true
        lastSubmittedCommand = command
        blocks.removeAll { $0.role == .output && $0.isStreaming }
        let identity = provider?.sessionDisplayName ?? "Shell"
        append(
            Block(
                role: .command,
                title: "You · \(identity)",
                text: provider == nil ? "$ \(command)" : command,
                isStreaming: false
            )
        )
        recordActivity("Input submitted · \(identity)")
    }

    private func finishOpeningMessage() {
        // Opening is a transient lifecycle state, not a transcript event.
        // Removing it keeps the task-chat surface focused on the connected
        // session instead of leaving a stale "opening shell" prompt above
        // the ready card and streamed output.
        blocks.removeAll {
            $0.role == .system && $0.isStreaming
        }
    }

    /// Shell prompts are terminal chrome, not command output. Remove only a
    /// short final prompt-shaped line and only for plain shells; agent output
    /// is never guessed or rewritten by this heuristic.
    private static func removingTrailingShellPrompt(from value: String) -> String {
        var lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 1, let last = lines.last else { return value }
        let trimmed = last.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= 80,
              trimmed.range(of: #"^\S{0,80}(?:[%$#]|❯|>)\s*$"#, options: .regularExpression) != nil else {
            return value
        }
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// Interactive shells normally echo the submitted command before its
    /// output. Chat already owns the exact canonical submission, so showing
    /// that echo again makes one action look duplicated. Remove only the
    /// first non-empty prompt line when it contains the exact command.
    private static func removingLeadingShellEcho(from value: String, command: String?) -> String {
        guard let command, !command.isEmpty else { return value }
        var lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let index = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return value }
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard line.contains(command) else { return value }
        if line == command {
            lines.remove(at: index)
            return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        }
        let prefix = line.replacingOccurrences(of: command, with: "")
        guard prefix.count <= 80,
              prefix.range(of: #"[%$#❯>]\s*$"#, options: .regularExpression) != nil else {
            return value
        }
        lines.remove(at: index)
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    func markWorking(provider: VampAgentProvider?) {
        let identity = provider?.sessionDisplayName ?? tabTitle
        if !blocks.contains(where: { $0.role == .progress && $0.text == "\(identity) is working…" }) {
            append(Block(role: .progress, title: identity, text: "\(identity) is working…", isStreaming: true))
        }
    }

    /// Applies an authenticated semantic event to this tab. The reducer keeps
    /// stable task IDs and persists the latest plan without involving VT.
    func applyTaskPlanEvent(_ event: SessionTaskEvent) {
        taskPlan = taskPlanCoordinator.apply(event)
        persistTaskPlan()
        if let taskPlan {
            recordActivity("Task plan · \(taskPlan.progressLabel)")
        }
    }

    func applyProviderSemanticEvent(_ event: ProviderSemanticEvent, provider: VampAgentProvider?) {
        let identity = provider?.sessionDisplayName ?? tabTitle
        switch event {
        case .messageDelta(let text):
            guard !text.isEmpty else { return }
            blocks.removeAll { $0.role == .progress && $0.isStreaming }
            if let index = blocks.lastIndex(where: { $0.role == .output && $0.isStreaming }) {
                blocks[index].title = identity
                blocks[index].text += text
            } else {
                append(Block(role: .output, title: identity, text: text, isStreaming: true))
            }
        case .thinkingDelta(let text):
            // Surface the agent's reasoning live so the user sees the process,
            // not just the final answer. It streams into the working block and
            // is replaced by the response once the answer starts.
            guard !text.isEmpty else { markWorking(provider: provider); return }
            if let index = blocks.lastIndex(where: { $0.role == .progress && $0.isStreaming }) {
                let base = blocks[index].text == "\(identity) is working…" ? "" : blocks[index].text
                blocks[index].title = "\(identity) · thinking"
                blocks[index].text = String((base + text).suffix(800))
            } else {
                append(Block(role: .progress, title: "\(identity) · thinking", text: String(text.suffix(800)), isStreaming: true))
            }
        case .taskPlan(let taskEvent):
            applyTaskPlanEvent(taskEvent)
        case .permissionRequested(let command):
            _ = requestApproval(for: command ?? "Agent action", provider: provider)
        case .sessionIdentifier(let id):
            recordActivity("\(identity) session · \(id.prefix(8))")
        case .completed:
            blocks.removeAll { $0.role == .progress && $0.isStreaming }
            if let index = blocks.lastIndex(where: { $0.role == .output && $0.isStreaming }) {
                blocks[index].isStreaming = false
            }
            recordActivity("\(identity) completed")
        case .failed(let reason):
            blocks.removeAll { $0.role == .progress && $0.isStreaming }
            append(Block(role: .error, title: "\(identity) stopped", text: reason ?? "The provider request failed."))
        }
    }

    /// Entry point for a future native provider adapter or the conservative
    /// fallback. It accepts only a stable semantic block and is never called
    /// from `appendOutput` or a terminal screen renderer.
    func consumeSemanticAgentOutput(
        _ semanticText: String,
        provider: VampAgentProvider?,
        sessionID: UUID,
        terminalID: UUID
    ) {
        let adapter = ConservativeAgentSessionAdapter(provider: provider)
        for event in adapter.consume(semanticText: semanticText, sessionID: sessionID, terminalID: terminalID) {
            if case .taskPlan(let taskEvent) = event, taskPlan == nil {
                applyTaskPlanEvent(taskEvent)
            }
        }
    }

    private func persistTaskPlan() {
        guard let key = taskPlanPersistenceKey else { return }
        if let data = try? JSONEncoder().encode(taskPlanCoordinator) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func recordActivity(_ text: String) {
        guard !text.isEmpty else { return }
        activityEvents.append(ActivityEvent(text: text))
        if activityEvents.count > maxActivityEvents {
            activityEvents.removeFirst(activityEvents.count - maxActivityEvents)
        }
    }

    private func append(_ block: Block) {
        blocks.append(block)
        if blocks.count > maxBlocks {
            blocks.removeFirst(blocks.count - maxBlocks)
        }
    }

}

/// A small incremental control-sequence consumer for the semantic Chat
/// projection. SwiftTerm remains the authoritative VT emulator; this reducer
/// only creates readable streaming cards and deliberately ignores cursor and
/// styling instructions.
private struct TerminalSemanticStreamDecoder {
    private enum ControlState { case text, escape, csi, osc, oscEscape }
    private var state: ControlState = .text
    private var utf8Remainder = Data()
    private var rendered = ""
    private var pendingCarriageReturn = false

    mutating func consume(_ data: Data) -> String? {
        utf8Remainder.append(data)
        var decoded: String?
        var retained = 0
        for suffix in 0...min(3, utf8Remainder.count) {
            let prefixCount = utf8Remainder.count - suffix
            guard prefixCount > 0 else { continue }
            if let value = String(data: utf8Remainder.prefix(prefixCount), encoding: .utf8) {
                decoded = value
                retained = suffix
                break
            }
        }
        guard let decoded else {
            if utf8Remainder.count > 8_192 { utf8Remainder.removeAll(keepingCapacity: true) }
            return nil
        }
        utf8Remainder = retained == 0 ? Data() : Data(utf8Remainder.suffix(retained))

        for scalar in decoded.unicodeScalars {
            if pendingCarriageReturn {
                pendingCarriageReturn = false
                if scalar.value == 0x0A {
                    rendered.append("\n")
                    continue
                }
                if let newline = rendered.lastIndex(of: "\n") {
                    rendered.removeSubrange(rendered.index(after: newline)..<rendered.endIndex)
                } else {
                    rendered.removeAll(keepingCapacity: true)
                }
            }
            switch state {
            case .text:
                switch scalar.value {
                case 0x1B: state = .escape
                case 0x0D: pendingCarriageReturn = true
                case 0x0A: rendered.append("\n")
                case 0x08: if !rendered.isEmpty { rendered.removeLast() }
                case 0x09: rendered.append("    ")
                case 0x20...0x10FFFF: rendered.unicodeScalars.append(scalar)
                default: break
                }
            case .escape:
                if scalar == "[" { state = .csi }
                else if scalar == "]" { state = .osc }
                else { state = .text }
            case .csi:
                if (0x40...0x7E).contains(scalar.value) { state = .text }
            case .osc:
                if scalar.value == 0x07 { state = .text }
                else if scalar.value == 0x1B { state = .oscEscape }
            case .oscEscape:
                state = scalar == "\\" ? .text : .osc
            }
        }
        if rendered.count > 16_000 { rendered = String(rendered.suffix(16_000)) }
        return rendered.trimmingCharacters(in: .newlines)
    }
}

/// Keeps the host-backed workspace catalog separate from live PTY tabs. The
/// catalog is persisted locally by host identity, while availability and Git
/// metadata always come from the connected host.
@MainActor
final class VampWorkspaceStore: ObservableObject {
    @Published private(set) var workspaces: [RemoteWorkspace] = []
    @Published private(set) var roots: [WorkspaceBrowseRoot] = []
    @Published private(set) var directoryEntries: [WorkspaceDirectoryEntry] = []
    @Published private(set) var browsePath: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isBrowsing = false
    @Published private(set) var isRequestingFolderAccess = false
    @Published private(set) var errorMessage: String?

    private let coordinator: ClientSessionCoordinator
    private var hostID: UUID?
    private var persistenceKey: String?
    private var persistedWorkspaces: [RemoteWorkspace] = []
    private var pendingListRequestID: UUID?
    private var pendingDirectoryRequestID: UUID?
    private var directoryTimeoutTask: Task<Void, Never>?
    private var pendingAccessRequestID: UUID?

    init(coordinator: ClientSessionCoordinator) {
        self.coordinator = coordinator
        coordinator.onWorkspaceListResponse = { [weak self] response in
            self?.receive(response)
        }
        coordinator.onWorkspaceDirectoryResponse = { [weak self] response in
            self?.receive(response)
        }
        coordinator.onWorkspaceAccessResponse = { [weak self] response in
            self?.receive(response)
        }
    }

    func activate() {
        isLoading = true
        errorMessage = nil
        do {
            pendingListRequestID = try coordinator.requestWorkspaces(refresh: false)
        } catch {
            isLoading = false
            errorMessage = "Reconnect to the Mac to browse its workspaces."
        }
    }

    func retryWhenTransportIsReady() {
        guard coordinator.activeSessionID != nil else { return }
        do {
            pendingListRequestID = try coordinator.requestWorkspaces(refresh: false)
            isLoading = true
            errorMessage = nil
        } catch {
            // The data channel can transition to open before this callback is
            // scheduled. A later open notification will retry without turning
            // a transient transport race into a permanent empty state.
        }
    }

    func refresh() {
        isLoading = true
        errorMessage = nil
        do {
            pendingListRequestID = try coordinator.requestWorkspaces(refresh: true)
        } catch {
            isLoading = false
            errorMessage = "Reconnect to the Mac to refresh workspaces."
        }
    }

    /// Asks the connected Mac to present its native folder picker. No path is
    /// selected or transmitted by iOS; the Mac owner remains in control.
    func requestAdditionalFolder() {
        guard !isRequestingFolderAccess else { return }
        isRequestingFolderAccess = true
        errorMessage = nil
        do {
            pendingAccessRequestID = try coordinator.requestAdditionalWorkspaceFolder()
        } catch {
            isRequestingFolderAccess = false
            errorMessage = "Reconnect to the Mac before adding a folder."
        }
    }

    func browse(path: String) {
        directoryTimeoutTask?.cancel()
        isBrowsing = true
        errorMessage = nil
        do {
            let requestID = try coordinator.requestWorkspaceDirectory(path: path)
            pendingDirectoryRequestID = requestID
            directoryTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.pendingDirectoryRequestID == requestID else { return }
                self.pendingDirectoryRequestID = nil
                self.isBrowsing = false
                self.errorMessage = "The Mac did not answer the folder request. Reconnect and try again."
            }
        } catch {
            isBrowsing = false
            errorMessage = "Reconnect to the Mac to browse this folder."
        }
    }

    func browseParent() {
        guard let browsePath else { return }
        let parent = URL(fileURLWithPath: browsePath).deletingLastPathComponent().path
        guard parent != browsePath else { return }
        browse(path: parent)
    }

    func toggleFavorite(_ workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].isFavorite.toggle()
        persist()
    }

    /// Adds a folder selected from the host browser to this host's local
    /// recents without inventing any metadata. The next refresh replaces the
    /// lightweight browser entry with the host's full Git/project record.
    func adopt(_ workspace: RemoteWorkspace) {
        guard workspace.hostID == hostID || hostID == nil else { return }
        if let index = workspaces.firstIndex(where: { $0.path == workspace.path }) {
            workspaces[index].isAvailable = workspace.isAvailable
            if workspaces[index].gitInfo?.projectHints.isEmpty != false {
                workspaces[index].gitInfo = workspace.gitInfo
            }
        } else {
            workspaces.append(workspace)
        }
        hostID = workspace.hostID
        persistenceKey = "com.mesutcy.vamp-terminal.workspaces.\(workspace.hostID.uuidString)"
        persist()
    }

    func markOpened(_ workspace: RemoteWorkspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index].lastOpenedAt = Date()
        persist()
    }

    func workspace(for entry: WorkspaceDirectoryEntry) -> RemoteWorkspace? {
        guard let hostID else { return nil }
        return RemoteWorkspace(
            id: stableWorkspaceID(path: entry.path, hostID: hostID),
            hostID: hostID,
            name: entry.name,
            path: entry.path,
            kind: entry.isGitRepository ? .gitRepository : .folder,
            gitInfo: GitWorkspaceInfo(projectHints: entry.projectHints),
            isAvailable: entry.isReadable
        )
    }

    private func receive(_ response: WorkspaceListResponseMessage) {
        guard response.sessionID == coordinator.activeSessionID,
              pendingListRequestID == nil || pendingListRequestID == response.requestID else { return }
        hostID = response.hostID
        persistenceKey = "com.mesutcy.vamp-terminal.workspaces.\(response.hostID.uuidString)"
        loadPersisted()
        roots = response.roots
        // The host intentionally sends roots first, then the discovered
        // projects with the same request ID. Keep the lightweight loading
        // state while still exposing Home/Desktop immediately.
        let isRootsOnlyResponse = response.workspaces.isEmpty && response.errorMessage == nil
        if !isRootsOnlyResponse || roots.isEmpty {
            pendingListRequestID = nil
            workspaces = merge(server: response.workspaces)
        }
        isLoading = isRootsOnlyResponse && !roots.isEmpty
        errorMessage = response.errorMessage
        if !isRootsOnlyResponse { persist() }
    }

    private func receive(_ response: WorkspaceDirectoryResponseMessage) {
        guard response.sessionID == coordinator.activeSessionID,
              pendingDirectoryRequestID == nil || pendingDirectoryRequestID == response.requestID else { return }
        pendingDirectoryRequestID = nil
        directoryTimeoutTask?.cancel()
        directoryTimeoutTask = nil
        browsePath = response.path
        directoryEntries = response.entries
        isBrowsing = false
        errorMessage = response.errorMessage
    }

    private func receive(_ response: WorkspaceAccessResponseMessage) {
        guard response.sessionID == coordinator.activeSessionID,
              pendingAccessRequestID == response.requestID else { return }
        pendingAccessRequestID = nil
        isRequestingFolderAccess = false
        if response.approved {
            refresh()
        } else {
            errorMessage = response.errorMessage
        }
    }

    private func merge(server: [RemoteWorkspace]) -> [RemoteWorkspace] {
        let byPath = Dictionary(uniqueKeysWithValues: persistedWorkspaces.map { ($0.path, $0) })
        var merged = server.map { remote in
            var value = remote
            if let saved = byPath[remote.path] {
                value.lastOpenedAt = saved.lastOpenedAt
                value.isFavorite = saved.isFavorite
            }
            return value
        }
        let knownPaths = Set(server.map(\.path))
        merged.append(contentsOf: persistedWorkspaces.filter { !knownPaths.contains($0.path) }.map {
            var stale = $0
            stale.isAvailable = false
            return stale
        })
        return merged.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            let leftDate = lhs.lastOpenedAt ?? .distantPast
            let rightDate = rhs.lastOpenedAt ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func loadPersisted() {
        persistedWorkspaces = []
        guard let persistenceKey,
              let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([RemoteWorkspace].self, from: data) else { return }
        persistedWorkspaces = decoded
    }

    private func persist() {
        guard let persistenceKey,
              let data = try? JSONEncoder().encode(workspaces) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
        persistedWorkspaces = workspaces
    }

    private func stableWorkspaceID(path: String, hostID: UUID) -> UUID {
        var digest = Array(SHA256.hash(data: Data((hostID.uuidString + "\n" + path).utf8)))
        digest[6] = (digest[6] & 0x0f) | 0x50
        digest[8] = (digest[8] & 0x3f) | 0x80
        let bytes = digest.prefix(16)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted) ?? UUID()
    }
}

/// Coordinates the terminal tabs that share one authenticated WebRTC session.
/// Each tab owns one ClientTerminalSessionManager, so shell state and output
/// stay independent while the SwiftUI panes remain mounted.
@MainActor
final class TerminalWorkspaceViewModel: ObservableObject {
    static let maxTabs = 8

    struct Tab: Identifiable {
        let id: UUID
        var title: String
        let session: ClientTerminalSessionManager
        let chat: TerminalChatStore
        var provider: VampAgentProvider?
        var workspaceID: UUID?
        var workingDirectory: String?
        var launchRequest: SessionLaunchRequest?
        var hasUnreadOutput = false
        var draft = ""

        @MainActor var state: ClientTerminalSessionManager.State { session.state }
    }

    @Published private(set) var tabs: [Tab] = []
    @Published var selectedTabID: UUID?
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var lastTerminalError: String?
    @Published private(set) var clipboardStatusMessage: String?
    /// Session ID the mounted tabs belonged to when the transport suspended.
    /// If a reconnect presents the same ID, tabs reattach instead of starting
    /// a fresh workspace.
    private var suspendedSessionID: UUID?

    private let coordinator: ClientSessionCoordinator
    let workspaceStore: VampWorkspaceStore
    private let clipboardSync = ClientClipboardSyncManager()
    private var sessionObservations: [UUID: AnyCancellable] = [:]
    private var chatObservations: [UUID: AnyCancellable] = [:]
    private var phaseObservation: AnyCancellable?
    private var dataChannelObservation: Task<Void, Never>?
    private var viewUpdateTask: Task<Void, Never>?
    private var lastActivityOutputSequence: [UUID: UInt64] = [:]
    private var pendingOutputActivityCounts: [UUID: Int] = [:]
    private var activityFlushTasks: [UUID: Task<Void, Never>] = [:]
    private var openingRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var clipboardStatusTask: Task<Void, Never>?

    init(coordinator: ClientSessionCoordinator) {
        self.coordinator = coordinator
        self.workspaceStore = VampWorkspaceStore(coordinator: coordinator)

        coordinator.onTerminalReady = { [weak self] message in
            self?.receiveReady(message)
        }
        coordinator.onTerminalOutput = { [weak self] message in
            self?.receiveOutput(message)
        }
        coordinator.onTerminalClose = { [weak self] message in
            self?.receiveClose(message)
        }
        coordinator.onTaskPlanEvent = { [weak self] message in
            self?.receiveTaskPlanEvent(message)
        }
        coordinator.onProviderSemanticEvent = { [weak self] message in
            self?.receiveProviderSemanticEvent(message)
        }
        coordinator.onSessionSnapshot = { [weak self] message in
            self?.receiveSessionSnapshot(message)
        }
        coordinator.onSessionSyncEvent = { [weak self] message in
            self?.receiveSessionSyncEvent(message)
        }
        coordinator.onClipboardSync = { [weak self] message in
            self?.receiveClipboard(message)
        }
        phaseObservation = coordinator.$phase.sink { [weak self] phase in
            self?.retryOpeningTabs(for: phase)
        }
        dataChannelObservation = Task { [weak self] in
            guard let self else { return }
            for await state in coordinator.terminalDataChannelStateUpdates() {
                guard !Task.isCancelled else { return }
                guard state == .open else { continue }
                self.retryOpeningTabs(for: coordinator.phase)
                self.workspaceStore.retryWhenTransportIsReady()
            }
        }
    }

    deinit {
        phaseObservation?.cancel()
        dataChannelObservation?.cancel()
        clipboardStatusTask?.cancel()
        sessionObservations.values.forEach { $0.cancel() }
        chatObservations.values.forEach { $0.cancel() }
        openingRetryTasks.values.forEach { $0.cancel() }
        clipboardStatusTask?.cancel()
        clipboardStatusTask = nil
    }

    var selectedTab: Tab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    var canCreateTab: Bool {
        activeSessionID != nil && tabs.count < Self.maxTabs
    }

    var tabCountLabel: String {
        "\(tabs.count)/\(Self.maxTabs)"
    }

    var hasStalledTab: Bool {
        tabs.contains { tab in
            if case .closed(_, _, let reason) = tab.state {
                return Self.isRetryableOpeningFailure(reason)
            }
            return false
        }
    }

    /// True while the transport is away but the remote session is NOT over:
    /// tabs stay mounted, shells keep running on the Mac. The UI shows a
    /// quiet "Reconnecting…" state instead of declaring the session dead.
    var isConnectionSuspended: Bool {
        if case .suspended = coordinator.terminalSessionLifecycle { return true }
        return coordinator.isReconnectInProgress
    }

    func activate(sessionID: UUID) {
        guard activeSessionID != sessionID else {
            retryOpeningTabs(for: coordinator.phase)
            return
        }

        // Reattach branch: tabs survived a transport loss and this is the same
        // session coming back. Reopen each tab against its preserved terminal
        // ID — the host re-acknowledges the existing PTY and replays its
        // bounded output tail instead of spawning a new shell.
        if suspendedSessionID == sessionID, !tabs.isEmpty {
            suspendedSessionID = nil
            activeSessionID = sessionID
            lastTerminalError = nil
            clipboardStatusMessage = nil
            clipboardSync.activate(sessionID: sessionID) { [weak self] envelope in
                guard let self else { throw WebRTCSessionError.dataChannelUnavailable }
                try self.coordinator.sendTerminalEnvelope(envelope)
            }
            workspaceStore.activate()
            for tab in tabs {
                _ = tab.session.reattach(sessionID: sessionID) { [weak coordinator] envelope in
                    guard let coordinator else { throw WebRTCSessionError.dataChannelUnavailable }
                    try coordinator.sendTerminalEnvelope(envelope)
                }
                scheduleOpeningRetry(for: tab.id)
            }
            return
        }

        stop()
        activeSessionID = sessionID
        lastTerminalError = nil
        clipboardStatusMessage = nil
        clipboardSync.activate(sessionID: sessionID) { [weak self] envelope in
            guard let self else { throw WebRTCSessionError.dataChannelUnavailable }
            try self.coordinator.sendTerminalEnvelope(envelope)
        }
        workspaceStore.activate()
    }

    /// The transport ended without user action. Tabs stay mounted with their
    /// terminal IDs and backlogs intact; a reconnect with the same session ID
    /// reattaches them instead of starting fresh.
    func suspendForReattach() {
        guard activeSessionID != nil else { return }
        openingRetryTasks.values.forEach { $0.cancel() }
        openingRetryTasks.removeAll()
        viewUpdateTask?.cancel()
        viewUpdateTask = nil
        activityFlushTasks.values.forEach { $0.cancel() }
        activityFlushTasks.removeAll()
        pendingOutputActivityCounts.removeAll()
        for tab in tabs {
            tab.session.suspendForReattach()
        }
        suspendedSessionID = activeSessionID
        activeSessionID = nil
        clipboardSync.deactivate()
        clipboardStatusMessage = nil
    }

    /// Clears the workspace when the session is explicitly ended. Tabs send a
    /// polite close so the host tears the shells down. Transient transport
    /// loss must use `suspendForReattach()` instead — reconnecting starts a
    /// fresh workspace only when there is nothing to reattach.
    func stop() {
        openingRetryTasks.values.forEach { $0.cancel() }
        openingRetryTasks.removeAll()
        viewUpdateTask?.cancel()
        viewUpdateTask = nil
        activityFlushTasks.values.forEach { $0.cancel() }
        activityFlushTasks.removeAll()
        pendingOutputActivityCounts.removeAll()
        lastActivityOutputSequence.removeAll()
        for tab in tabs {
            tab.session.deactivate()
        }
        tabs.removeAll()
        sessionObservations.removeAll()
        chatObservations.removeAll()
        selectedTabID = nil
        activeSessionID = nil
        suspendedSessionID = nil
        clipboardSync.deactivate()
        clipboardStatusMessage = nil
    }

    @discardableResult
    func createTab(
        startupCommand: String? = nil,
        title: String? = nil,
        provider: VampAgentProvider? = nil,
        workspace: RemoteWorkspace? = nil,
        resumeMode: ResumeMode = .new,
        persistenceMode: PersistenceMode = .sessionOnly,
        launchExecutable: String? = nil,
        launchArguments: [String] = []
    ) -> Bool {
        guard canCreateTab, let sessionID = activeSessionID else { return false }

        let tabID = UUID()
        let session = ClientTerminalSessionManager()
        let coordinator = self.coordinator
        session.activate(sessionID: sessionID) { [weak coordinator] envelope in
            guard let coordinator else {
                throw WebRTCSessionError.dataChannelUnavailable
            }
            try coordinator.sendTerminalEnvelope(envelope)
        }
        let tabTitle = title ?? provider?.sessionDisplayName ?? nextDefaultTabTitle()
        let launchRequest: SessionLaunchRequest? = if let workspace, let provider {
            SessionLaunchRequest(
                hostID: workspace.hostID,
                workspaceID: workspace.id,
                workingDirectory: workspace.path,
                agent: provider.rawValue,
                resumeMode: resumeMode,
                persistenceMode: persistenceMode
            )
        } else {
            nil
        }
        let tab = Tab(
            id: tabID,
            title: tabTitle,
            session: session,
            chat: TerminalChatStore(tabTitle: tabTitle, sessionID: tabID),
            provider: provider,
            workspaceID: workspace?.id,
            workingDirectory: workspace?.path,
            launchRequest: launchRequest
        )
        // Mount and observe the tab before sending TerminalOpen. This keeps a
        // very fast host-ready response from arriving before the tab is
        // routable in the workspace collection.
        tabs.append(tab)
        observe(session: session, tabID: tabID)
        observe(chat: tab.chat, tabID: tabID)
        if let startupCommand { tab.chat.recordStartupCommand(startupCommand) }
        _ = session.open(
            cols: 80,
            rows: 24,
            startupCommand: startupCommand,
            workspaceID: workspace?.id,
            workingDirectory: workspace?.path,
            launchExecutable: launchExecutable,
            launchArguments: launchArguments
        )
        if let workspace {
            workspaceStore.markOpened(workspace)
        }
        scheduleOpeningRetry(for: tabID)
        selectedTabID = tabID
        lastTerminalError = nil
        return true
    }

    func select(tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        selectedTabID = tabID
        if let index = tabs.firstIndex(where: { $0.id == tabID }) {
            tabs[index].hasUnreadOutput = false
        }
    }

    func close(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        openingRetryTasks[tabID]?.cancel()
        openingRetryTasks.removeValue(forKey: tabID)
        let wasSelected = selectedTabID == tabID
        tabs[index].session.close(reason: "user-closed")
        tabs[index].session.deactivate()
        sessionObservations[tabID]?.cancel()
        sessionObservations.removeValue(forKey: tabID)
        chatObservations[tabID]?.cancel()
        chatObservations.removeValue(forKey: tabID)
        tabs.remove(at: index)

        guard !tabs.isEmpty else {
            selectedTabID = nil
            return
        }
        if wasSelected || selectedTabID == nil {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
            if let selectedTabID,
               let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) {
                tabs[selectedIndex].hasUnreadOutput = false
            }
        }
    }

    func rename(tabID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].title = trimmed
    }

    func updateDraft(tabID: UUID, value: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].draft = value
    }

    func retryStalledTabs() {
        lastTerminalError = nil
        for index in tabs.indices {
            guard tabs[index].session.retryAfterOpeningFailure(cols: 80, rows: 24) else { continue }
            tabs[index].chat.prepareForRetry()
            scheduleOpeningRetry(for: tabs[index].id)
        }
    }

    // MARK: - Clipboard bridge

    /// Sends the phone's current plaintext clipboard to the Mac host. This is
    /// explicit so iOS never polls or silently exports clipboard contents.
    @discardableResult
    func sendClipboardToHost() -> Bool {
        let sent = clipboardSync.pushToHost()
        showClipboardStatus(sent ? "Phone clipboard sent to Mac" : "Nothing to send")
        return sent
    }

    /// Used by SwiftTerm's OSC 52 callback when a remote program explicitly
    /// writes a clipboard value.
    @discardableResult
    func sendClipboardTextToHost(_ text: String) -> Bool {
        let sent = clipboardSync.pushTextToHost(text)
        showClipboardStatus(sent ? "Terminal clipboard sent to Mac" : "Clipboard send failed")
        return sent
    }

    /// Sends the exact immutable Chat composer value once. The transcript is
    /// written before transport and never reconstructed from PTY echo.
    func sendCommand(tabID: UUID, text: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let command = text.replacingOccurrences(of: "\u{0}", with: "")
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              tabs[index].session.canSendInput else { return }
        guard !tabs[index].chat.requestApproval(for: command, provider: tabs[index].provider) else { return }
        sendApprovedCommand(tabID: tabID, command: command)
    }

    func resolveApproval(tabID: UUID, choice: TerminalChatStore.ApprovalChoice) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let command = tabs[index].chat.resolveApproval(choice) else { return }
        sendApprovedCommand(tabID: tabID, command: command)
    }

    private func sendApprovedCommand(tabID: UUID, command: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].session.canSendInput else { return }
        if tabs[index].provider?.semanticProvider != nil {
            _ = submitAgentPrompt(tabID: tabID, text: command)
            return
        }
        tabs[index].chat.recordChatSubmission(command, provider: tabs[index].provider)
        tabs[index].chat.markWorking(provider: tabs[index].provider)
        // A PTY Enter key is carriage return (0x0D). Interactive TUIs such as
        // Grok keep LF in their editor buffer instead of submitting.
        tabs[index].session.sendInput(Data((command + "\r").utf8))
    }

    /// Raw Terminal input is intentionally not added to Chat. It remains a
    /// byte-accurate PTY interaction and is visible in Terminal mode only.
    func recordInput(tabID: UUID, data: Data) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tab.chat.recordInput(data)
    }

    /// Sends a graceful interrupt to the active PTY and pauses an attached
    /// plan. Terminating a session remains a separate close action.
    func interrupt(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].session.canSendInput else { return }
        tabs[index].session.sendInput(Data([0x03]))
        tabs[index].chat.recordActivity("Interrupt requested")
        if tabs[index].chat.taskPlan?.isActive == true {
            tabs[index].chat.applyTaskPlanEvent(.planPaused)
        }
    }

    /// Resumes a paused semantic plan without recreating its PTY or clearing
    /// its terminal screen. The next Chat submission or terminal key can
    /// continue the agent from the preserved session state.
    func resumePlan(tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              tab.chat.taskPlan?.state == .paused else { return }
        tab.chat.applyTaskPlanEvent(.planResumed)
        tab.chat.recordActivity("Task plan resumed")
    }

    /// Applies a task event received from the authenticated semantic channel.
    /// Session and terminal IDs are both required so one agent can never
    /// mutate another tab's plan.
    func applyTaskPlanEvent(_ event: SessionTaskEvent, tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tab.chat.applyTaskPlanEvent(event)
    }

    /// Test/provider hook for a stable semantic block. Raw PTY output must not
    /// call this method; use an agent protocol adapter before VT rendering.
    func consumeSemanticAgentOutput(tabID: UUID, text: String) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let sessionID = activeSessionID,
              let terminalID = tab.session.terminalID else { return }
        tab.chat.consumeSemanticAgentOutput(text, provider: tab.provider, sessionID: sessionID, terminalID: terminalID)
    }

    @discardableResult
    func submitAgentPrompt(tabID: UUID, text: String) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let sessionID = activeSessionID,
              let terminalID = tab.session.terminalID,
              let provider = tab.provider?.semanticProvider,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        tab.chat.recordChatSubmission(text, provider: tab.provider)
        tab.chat.markWorking(provider: tab.provider)
        let message = AgentPromptMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            provider: provider,
            prompt: text,
            workingDirectory: tab.workingDirectory
        )
        guard let envelope = try? DataChannelEnvelope.agentPrompt(message) else { return false }
        do {
            try coordinator.sendTerminalEnvelope(envelope)
            return true
        } catch {
            tab.chat.applyProviderSemanticEvent(.failed("The host could not start the agent request."), provider: tab.provider)
            return false
        }
    }

    /// Requests the Mac clipboard. The response is placed in the phone
    /// clipboard by `ClientClipboardSyncManager`, ready for the terminal's
    /// Paste action or any other iOS app.
    @discardableResult
    func requestClipboardFromHost() -> Bool {
        let requested = clipboardSync.requestFromHost()
        showClipboardStatus(requested ? "Getting Mac clipboard…" : "Clipboard request failed")
        return requested
    }

    // MARK: - Routed incoming messages

    private func receiveReady(_ message: TerminalReadyMessage) {
        for tab in tabs where tab.session.receiveReady(message) {
            tab.chat.markReady()
            cancelOpeningRetry(for: tab.id)
            lastTerminalError = nil
            return
        }
    }

    private func receiveOutput(_ message: TerminalOutputMessage) {
        for index in tabs.indices where tabs[index].session.receiveOutput(message) {
            tabs[index].chat.appendOutput(message.data, provider: tabs[index].provider)
            scheduleOutputActivity(tabID: tabs[index].id, sequence: message.sequence)
            if tabs[index].id != selectedTabID {
                tabs[index].hasUnreadOutput = true
            }
            return
        }
    }

    private func scheduleOutputActivity(tabID: UUID, sequence: UInt64) {
        guard sequence > (lastActivityOutputSequence[tabID] ?? 0) else { return }
        lastActivityOutputSequence[tabID] = sequence
        pendingOutputActivityCounts[tabID, default: 0] += 1
        guard activityFlushTasks[tabID] == nil else { return }
        activityFlushTasks[tabID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            let count = self.pendingOutputActivityCounts.removeValue(forKey: tabID) ?? 0
            self.activityFlushTasks[tabID] = nil
            if let tab = self.tabs.first(where: { $0.id == tabID }) {
                tab.chat.recordActivity(count == 1 ? "Terminal output received" : "Terminal output updated")
            }
        }
    }

    private func receiveClose(_ message: TerminalCloseMessage) {
        for tab in tabs {
            let wasOpening: Bool
            if case .opening = tab.session.state {
                wasOpening = true
            } else {
                wasOpening = false
            }
            guard tab.session.receiveClose(message) else { continue }
            tab.chat.markClosed(reason: message.reason)
            cancelOpeningRetry(for: tab.id)
            if let reason = message.reason {
                switch reason {
                case "terminal-disabled":
                    lastTerminalError = "Terminal Mode is disabled in Vamp Host settings. Turn it on, then retry this tab."
                case "terminal-capacity":
                    lastTerminalError = "The Mac has reached its 8-terminal limit. Close a tab on the Mac, then retry."
                case "workspace-unavailable", "workspace-mismatch":
                    lastTerminalError = "\(tab.title) could not start in that workspace. Refresh workspaces and choose an available folder."
                case "shell-exited":
                    lastTerminalError = wasOpening
                        ? "\(tab.title) exited before it became ready. Check Terminal Mode and retry."
                        : "\(tab.title) exited. Retry the tab if you want a new shell."
                case "eof":
                    lastTerminalError = "\(tab.title) closed before it became ready. Check Terminal Mode and retry."
                default:
                    if reason.hasPrefix("forkpty failed") {
                        lastTerminalError = "\(tab.title) could not create a shell on the Mac. Check permissions, then retry."
                    } else if reason.hasPrefix("read-error") {
                        lastTerminalError = "\(tab.title) could not start on the Mac: \(reason)."
                    }
                }
            }
            return
        }
    }

    private func receiveTaskPlanEvent(_ message: SessionTaskEventMessage) {
        guard message.sessionID == activeSessionID else { return }
        guard let tab = tabs.first(where: { $0.session.terminalID == message.terminalID }) else { return }
        guard message.event.isBound(toSessionID: message.sessionID, terminalID: message.terminalID) else { return }
        tab.chat.applyTaskPlanEvent(message.event)
    }

    private func receiveProviderSemanticEvent(_ message: ProviderSemanticEventMessage) {
        guard message.sessionID == activeSessionID,
              let tab = tabs.first(where: { $0.session.terminalID == message.terminalID }),
              tab.provider?.semanticProvider == message.provider else { return }
        tab.chat.applyProviderSemanticEvent(message.event, provider: tab.provider)
    }

    /// Applies one replayed journal event (step E). The coordinator already
    /// deduped by journal sequence, so this is exactly-once by construction.
    private func receiveSessionSyncEvent(_ message: SessionSyncEventMessage) {
        switch message.kind {
        case "taskPlan":
            if let event = try? JSONDecoder().decode(SessionTaskEventMessage.self, from: message.payload) {
                receiveTaskPlanEvent(event)
            }
        case "providerSemantic":
            if let event = try? JSONDecoder().decode(ProviderSemanticEventMessage.self, from: message.payload) {
                receiveProviderSemanticEvent(event)
            }
        case "terminalClosed":
            // A shell died while the client was away; surface it on the tab.
            if let event = try? JSONDecoder().decode(TerminalCloseMessage.self, from: message.payload) {
                receiveClose(event)
            }
        default:
            break
        }
    }

    /// Reconciles tabs against the host's authoritative snapshot (step E).
    /// Reaped terminals that a tab still believes are open are closed, so a
    /// relaunched client never shows a live pane for a dead shell.
    private func receiveSessionSnapshot(_ snapshot: SessionSnapshotMessage) {
        for terminal in snapshot.terminals where terminal.state == "reaped" {
            guard let tab = tabs.first(where: { $0.session.terminalID == terminal.terminalID }) else { continue }
            let close = TerminalCloseMessage(
                sessionID: snapshot.sessionID,
                terminalID: terminal.terminalID,
                exitCode: nil,
                signal: nil,
                reason: "shell-exited-while-away"
            )
            _ = tab.session.receiveClose(close)
        }
    }

    private func receiveClipboard(_ message: ClipboardSyncMessage) {
        guard message.sessionID == activeSessionID,
              message.source == "host" else { return }
        clipboardSync.receive(message)
        showClipboardStatus("Mac clipboard copied to iPhone")
    }

    private func showClipboardStatus(_ message: String) {
        clipboardStatusTask?.cancel()
        clipboardStatusMessage = message
        clipboardStatusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.clipboardStatusMessage = nil
        }
    }

    private func observe(session: ClientTerminalSessionManager, tabID: UUID) {
        sessionObservations[tabID] = session.objectWillChange.sink { [weak self] _ in
            self?.scheduleViewUpdate()
        }
    }

    private func observe(chat: TerminalChatStore, tabID: UUID) {
        chatObservations[tabID] = chat.objectWillChange.sink { [weak self] _ in
            self?.scheduleViewUpdate()
        }
    }

    private func scheduleViewUpdate() {
        guard viewUpdateTask == nil else { return }
        viewUpdateTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.viewUpdateTask = nil
            self.objectWillChange.send()
        }
    }

    private func retryOpeningTabs(for phase: ClientSessionCoordinator.SessionPhase) {
        guard phase == .waitingForMedia || phase == .receiving else { return }
        for tab in tabs where tab.state == .opening {
            _ = tab.session.retryOpen(cols: 80, rows: 24)
        }
    }

    private func scheduleOpeningRetry(for tabID: UUID) {
        openingRetryTasks[tabID]?.cancel()
        openingRetryTasks[tabID] = Task { [weak self] in
            // The first terminal can race the final WebRTC control-channel
            // transition, especially on a Tailscale path. Keep the tab in an
            // opening state long enough for that channel to become writable;
            // the host treats the stable terminal ID as an idempotency key.
            // WebRTC negotiation can legitimately take 20–30 seconds on a
            // waking Mac or a Tailscale path. Keep retrying the same stable
            // terminal ID until the data channel is writable instead of
            // declaring the shell dead while the connection is still opening.
            let delays: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000, 12_000_000_000, 16_000_000_000, 20_000_000_000]
            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                guard self.activeSessionID != nil,
                      let tab = self.tabs.first(where: { $0.id == tabID }),
                      tab.state == .opening else {
                    return
                }
                _ = tab.session.retryOpen(cols: 80, rows: 24)
            }

            guard !Task.isCancelled,
                  let self,
                  let tab = self.tabs.first(where: { $0.id == tabID }),
                  tab.state == .opening else { return }
            tab.session.failOpening()
            tab.chat.markClosed(reason: "terminal-start-timeout")
            self.lastTerminalError = "\(tab.title) did not receive a terminal-ready response. Check that Terminal Mode is enabled and Vamp Host is updated, then retry."
        }
    }

    private func cancelOpeningRetry(for tabID: UUID) {
        openingRetryTasks[tabID]?.cancel()
        openingRetryTasks.removeValue(forKey: tabID)
    }

    private static func isRetryableOpeningFailure(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return reason == "terminal-start-timeout"
            || reason == "terminal-disabled"
            || reason == "terminal-capacity"
            || reason == "workspace-unavailable"
            || reason == "workspace-mismatch"
            || reason == "shell-exited"
            || reason == "eof"
            || reason.hasPrefix("forkpty failed")
            || reason.hasPrefix("read-error")
    }

    private func nextDefaultTabTitle() -> String {
        let existingTitles = Set(tabs.map(\.title))
        var number = 1
        while existingTitles.contains("Terminal \(number)") {
            number += 1
        }
        return "Terminal \(number)"
    }
}
