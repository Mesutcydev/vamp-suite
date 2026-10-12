#if os(macOS)
import Foundation
import SharedProtocol
import TransportWebRTC
import os

/// Runs provider-supported machine-readable Chat turns without scraping the
/// interactive PTY. One service belongs to one authenticated connection; each
/// terminal keeps its own provider session identifier and cancellation task.
final class HostAgentSemanticService: @unchecked Sendable {
    private final class RunOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var terminalEventSeen = false

        func observe(_ event: ProviderSemanticEvent) {
            guard event.isTerminalProviderEvent else { return }
            lock.lock()
            terminalEventSeen = true
            lock.unlock()
        }

        var hasTerminalEvent: Bool {
            lock.lock()
            defer { lock.unlock() }
            return terminalEventSeen
        }
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data, limit: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard storage.count < limit else { return }
            storage.append(data.prefix(limit - storage.count))
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private struct AgentKey: Hashable { let sessionID: UUID; let terminalID: UUID }
    private struct State {
        var provider: AgentProviderKind
        var providerSessionID: String?
        var task: Task<Void, Never>?
    }

    private let queue = DispatchQueue(label: "host.agent.semantic.service")
    private let workspaceService: HostWorkspaceService?
    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "AgentSemantic")
    private var states: [AgentKey: State] = [:]
    var sendEnvelope: ((DataChannelEnvelope) -> Void)?
    /// Durable semantic journal (step C). Optional for tests/browser instances.
    var journal: HostSessionJournal?

    init(workspaceService: HostWorkspaceService? = nil) {
        self.workspaceService = workspaceService
    }

    func handlePrompt(_ message: AgentPromptMessage) {
        if let payload = try? JSONEncoder().encode(message) {
            journal?.append(sessionID: message.sessionID, type: .agentPrompt, payload: payload)
        }
        queue.async { [weak self] in self?._handlePrompt(message) }
    }

    func sessionDidEnd() {
        queue.async { [weak self] in
            self?.states.values.forEach { $0.task?.cancel() }
            self?.states.removeAll()
        }
    }

    private func _handlePrompt(_ message: AgentPromptMessage) {
        guard !message.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.prompt.utf8.count <= AgentPromptMessage.maxPromptBytes else {
            send(.failed("invalid-prompt"), for: message)
            return
        }
        let workingDirectory: String
        if let requested = message.workingDirectory {
            guard let validated = workspaceService?.validatedWorkingDirectory(requested)
                    ?? Self.validateHomePath(requested) else {
                send(.failed("workspace-unavailable"), for: message)
                return
            }
            workingDirectory = validated
        } else {
            workingDirectory = workspaceService?.homePath ?? NSHomeDirectory()
        }

        let key = AgentKey(sessionID: message.sessionID, terminalID: message.terminalID)
        if states[key]?.task != nil {
            send(.failed("agent-busy"), for: message)
            return
        }
        let previousSessionID = states[key]?.provider == message.provider ? states[key]?.providerSessionID : nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(message, workingDirectory: workingDirectory, previousSessionID: previousSessionID)
        }
        states[key] = State(provider: message.provider, providerSessionID: previousSessionID, task: task)
    }

    private func run(_ message: AgentPromptMessage, workingDirectory: String, previousSessionID: String?) async {
        let key = AgentKey(sessionID: message.sessionID, terminalID: message.terminalID)
        defer { queue.async { [weak self] in self?.states[key]?.task = nil } }

        let process = Process()
        let output = Pipe()
        let error = Pipe()
        let adapter = Self.adapter(for: message.provider)
        let outcome = RunOutcome()
        let launch = Self.launch(provider: message.provider, prompt: message.prompt, previousSessionID: previousSessionID)
        guard let executable = Self.resolveExecutable(launch.executable) else {
            send(.failed("\(launch.executable)-not-installed"), for: message)
            return
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        process.standardOutput = output
        process.standardError = error
        // Semantic turns are deliberately non-interactive: the complete prompt
        // is passed in the provider's arguments and permission was already
        // resolved by Vamp. Never inherit the host app's stdin here. A host
        // launched from Terminal can retain a controlling TTY; Grok then
        // switches back to interactive input after emitting its startup
        // records and Chat remains stuck forever. /dev/null gives every
        // provider an immediate EOF and keeps this runner deterministic.
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        // Interpreter-based provider CLIs run through a `#!/usr/bin/env node`
        // (or python/bun) shebang. Resolving the launcher's own path is not
        // enough: the interpreter is looked up in the child's PATH at exec
        // time. A GUI-launched host inherits only a minimal PATH, so
        // `command-code` (a node script) dies with "env: node: No such file or
        // directory" while self-contained binaries like opencode keep working.
        // Give the child the same augmented PATH used to resolve the launcher,
        // mirroring the PTY (see HostTerminalService) so Chat and Terminal
        // behave identically.
        environment["PATH"] = Self.launcherSearchDirectories().joined(separator: ":")
        process.environment = environment

        // Install the termination observer before launch so a very short
        // provider run cannot finish between `run()` and observer setup. More
        // importantly, never call Process.waitUntilExit() from this async
        // task: it blocks a cooperative executor thread while the stdout and
        // stderr child tasks need that executor to drain the provider pipes.
        // Large startup records (notably Grok's available-command payload)
        // can fill the pipe and otherwise deadlock Chat at "Working".
        let termination = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield(())
                continuation.finish()
            }
        }

        do { try process.run() }
        catch {
            send(.failed(error.localizedDescription), for: message)
            return
        }
        // `Pipe` keeps both descriptors open in this process. Once the child
        // has inherited its stdout/stderr descriptors, the host must close
        // its copies of the write ends. Otherwise the readers below never
        // observe EOF after the provider exits, `drains.notify` never runs,
        // and Chat remains stuck in Running even though the CLI completed.
        // Provider descendants inherit the child's descriptors normally;
        // closing only these parent copies does not truncate their output.
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()

        // Drain both pipes on dedicated blocking queues. FileHandle's
        // readabilityHandler is not reliable for these child pipes inside the
        // packaged app: on some macOS releases its dispatch source never
        // fires, leaving Grok's verbose startup JSON in the 16 KiB pipe and
        // permanently blocking the provider. Dedicated readers also avoid
        // occupying a cooperative Swift executor thread.
        let drains = DispatchGroup()
        let capturedError = LockedData()
        drains.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { drains.leave() }
            let handle = output.fileHandleForReading
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.consume(data, adapter: adapter, message: message, key: key, outcome: outcome)
                // One-shot Chat is done when the provider emits a terminal
                // semantic event. Stop any leftover server/TUI so the host
                // slot is not stuck in agent-busy after the turn.
                if outcome.hasTerminalEvent {
                    Self.stopLeftoverProcess(process)
                }
            }
        }
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { drains.leave() }
            let handle = error.fileHandleForReading
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { return }
                capturedError.append(data, limit: 64 * 1024)
            }
        }
        await withTaskCancellationHandler {
            for await _ in termination { break }
        } onCancel: {
            Self.stopLeftoverProcess(process)
        }
        // Closing the host-side read ends unblocks `availableData` if a
        // leftover child still holds the write end after the launcher exits.
        try? output.fileHandleForReading.close()
        try? error.fileHandleForReading.close()
        await withCheckedContinuation { continuation in
            drains.notify(queue: queue) { continuation.resume() }
        }
        let stderrData = capturedError.value
        consumeFinal(adapter: adapter, message: message, key: key, outcome: outcome)
        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8)
            if !outcome.hasTerminalEvent {
                let detail = stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
                send(.failed(detail?.isEmpty == false ? detail : "Provider exited with status \(process.terminationStatus)."), for: message)
            }
        } else if !outcome.hasTerminalEvent {
            // Some provider versions omit their documented final JSON record
            // after emitting a valid response. A successful process exit is a
            // trustworthy semantic boundary and must release Chat from its
            // Working state exactly once.
            send(.completed, for: message)
        }
    }

    private func consume(_ data: Data, adapter: ProviderSemanticAdapter, message: AgentPromptMessage, key: AgentKey, outcome: RunOutcome) {
        for event in adapter.consume(data, sessionID: message.sessionID, terminalID: message.terminalID) {
            outcome.observe(event)
            remember(event, key: key)
            if case .taskPlan(let taskEvent) = event {
                sendTaskPlan(taskEvent, message: message)
            } else {
                send(event, for: message)
            }
        }
    }

    private func consumeFinal(adapter: ProviderSemanticAdapter, message: AgentPromptMessage, key: AgentKey, outcome: RunOutcome) {
        for event in adapter.finish(sessionID: message.sessionID, terminalID: message.terminalID) {
            outcome.observe(event)
            remember(event, key: key)
            if case .taskPlan(let taskEvent) = event {
                sendTaskPlan(taskEvent, message: message)
            } else {
                send(event, for: message)
            }
        }
    }

    private func remember(_ event: ProviderSemanticEvent, key: AgentKey) {
        guard case .sessionIdentifier(let value) = event else { return }
        queue.async { [weak self] in self?.states[key]?.providerSessionID = value }
    }

    private func send(_ event: ProviderSemanticEvent, for message: AgentPromptMessage) {
        var value = ProviderSemanticEventMessage(
            sessionID: message.sessionID,
            terminalID: message.terminalID,
            provider: message.provider,
            event: event
        )
        if let journal {
            value.journalSequence = journal.append(
                sessionID: message.sessionID,
                type: .providerSemantic,
                payload: (try? JSONEncoder().encode(value)) ?? Data()
            )
        }
        if let envelope = try? DataChannelEnvelope.providerSemanticEvent(value) { sendEnvelope?(envelope) }
    }

    private func sendTaskPlan(_ event: SessionTaskEvent, message: AgentPromptMessage) {
        var value = SessionTaskEventMessage(sessionID: message.sessionID, terminalID: message.terminalID, event: event)
        if let journal {
            value.journalSequence = journal.append(
                sessionID: message.sessionID,
                type: .taskPlan,
                payload: (try? JSONEncoder().encode(value)) ?? Data()
            )
        }
        if let envelope = try? DataChannelEnvelope.taskPlanEvent(value) { sendEnvelope?(envelope) }
    }

    private static func adapter(for provider: AgentProviderKind) -> ProviderSemanticAdapter {
        switch provider {
        case .grok: return GrokAdapter()
        case .openCode: return OpenCodeAdapter()
        case .claude: return ClaudeAdapter()
        case .codex: return CodexAdapter()
        case .pi: return PiAdapter()
        case .commandCode: return CommandCodeAdapter()
        case .kimi: return KimiAdapter()
        case .qwen: return QwenAdapter()
        case .aider: return AiderAdapter()
        case .gemini: return GeminiAdapter()
        }
    }

    static func launch(provider: AgentProviderKind, prompt: String, previousSessionID: String?) -> (executable: String, arguments: [String]) {
        switch provider {
        case .grok:
            // Match the Linux host: no unattended approval bypass. If the
            // provider needs a TTY confirmation, use Terminal instead of Chat.
            var args = ["--output-format", "streaming-json", "--single"]
            if let previousSessionID { args = ["--resume", previousSessionID] + args }
            return ("grok", args + ["--", prompt])
        case .openCode:
            // Match the Linux host: `opencode run --format json -- <prompt>`.
            // `--auto` keeps a local server alive after step_finish, so Chat
            // completes while the host slot stays agent-busy.
            var args = ["run", "--format", "json"]
            if let previousSessionID { args += ["--session", previousSessionID] }
            return ("opencode", args + ["--", prompt])
        case .claude:
            var args = ["--print", "--verbose", "--output-format", "stream-json", "--include-partial-messages"]
            if let previousSessionID { args += ["--resume", previousSessionID] }
            return ("claude", args + ["--", prompt])
        case .codex:
            var args = ["exec"]
            if let previousSessionID { args += ["resume", previousSessionID] }
            args += ["--json", "--skip-git-repo-check"]
            return ("codex", args + ["--", prompt])
        case .pi:
            // JSON event mode is Pi's documented machine-readable stream; the
            // session header carries the id used to resume the same
            // conversation on the next Chat turn. Non-interactive modes never
            // show a project-trust prompt, and Vamp has already resolved the
            // user's explicit approval for this turn.
            var args = ["--mode", "json"]
            if let previousSessionID { args += ["--session", previousSessionID] }
            return ("pi", args + ["--", prompt])
        case .commandCode:
            // Print mode runs the full agent loop non-interactively. Onboarding
            // and auto-update are suppressed so a headless turn is deterministic.
            // Interactive file approvals stay in Terminal, matching Linux.
            let args = ["-p", "--skip-onboarding", "--no-auto-update"]
            return ("cmd", args + ["--", prompt])
        case .kimi:
            var args = ["--output-format", "stream-json"]
            if let previousSessionID { args += ["--session", previousSessionID] }
            return ("kimi", args + ["--prompt", prompt])
        case .qwen:
            var args = ["--output-format", "stream-json", "--include-partial-messages", "--approval-mode", "plan"]
            if let previousSessionID { args += ["--resume", previousSessionID] }
            return ("qwen", args + ["--prompt", prompt])
        case .aider:
            // Scripted `--message` mode. Edit confirmation stays with the
            // provider (no `--yes`), matching the Linux host.
            let args = ["--message", prompt, "--stream", "--no-pretty", "--no-auto-commits", "--no-check-update"]
            return ("aider", args)
        case .gemini:
            var args = ["--output-format", "stream-json", "--approval-mode", "plan"]
            if let previousSessionID { args += ["--resume", previousSessionID] }
            return ("gemini", args + ["--prompt", prompt])
        }
    }

    /// PATH search directories for provider launchers. GUI apps launched by
    /// launchd do not inherit a login-shell PATH, so a tool installed by
    /// Homebrew, npm, bun, cargo, or an agent's own installer (e.g. `opencode`
    /// lands in ~/.opencode/bin) would otherwise look "not installed" even when
    /// it is present. Used both to resolve the launcher and as the child's
    /// runtime PATH, so interpreter shebangs resolve too.
    private static func launcherSearchDirectories() -> [String] {
        let home = NSHomeDirectory()
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let common = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.local/bin", "\(home)/bin",
            "\(home)/.opencode/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.deno/bin",
            "\(home)/.volta/bin"
        ]
        var seen = Set<String>()
        return (inherited + common).filter { seen.insert($0).inserted }
    }

    private static func stopLeftoverProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.interrupt()
        if process.isRunning {
            process.terminate()
        }
    }

    private static func resolveExecutable(_ name: String) -> String? {
        launcherSearchDirectories()
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func validateHomePath(_ path: String) -> String? {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
        let value = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard value == home || value.hasPrefix(home + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return value
    }
}
#endif
