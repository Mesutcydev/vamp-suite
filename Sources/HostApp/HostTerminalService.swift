#if os(macOS)
import Foundation
import Darwin
import CryptoKit
import SharedModels
import SharedProtocol
import TransportWebRTC
import os

// MARK: - libutil bridge
//
// `forkpty(3)` lives in libutil.dylib on macOS and is not exposed by Swift's
// Darwin module. Declaring it with @_silgen_name lets us call it directly
// without adding a bridging header or C shim module.
@_silgen_name("forkpty")
private func c_forkpty(
    _ amaster: UnsafeMutablePointer<Int32>?,
    _ name: UnsafeMutablePointer<CChar>?,
    _ termp: UnsafePointer<termios>?,
    _ winp: UnsafePointer<winsize>?
) -> pid_t

/// Hosts interactive shells over PTYs for the connected iOS client. One
/// service instance manages a bounded collection of independent terminals per
/// authenticated session, keyed by the client-selected terminal ID.
///
/// Threading: all public mutators hop to an internal serial queue so the PTY
/// fd, child PID, and pump tasks are touched from a single context. Output
/// arrives on the same queue and is forwarded via the injected send closure.
final class HostTerminalService: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "Terminal")
    private let queue = DispatchQueue(label: "host.terminal.service")
    private let workspaceService: HostWorkspaceService?

    /// Hard cap per authenticated connection. This keeps a client from
    /// turning one host session into an unbounded process/fd farm.
    static let maxActiveTerminals = 8

    /// Defensive output limits for runaway commands such as `yes` or
    /// `cat /dev/urandom`. Each terminal gets a fair cap and the connection
    /// has an aggregate cap so eight terminals cannot multiply the limit.
    private let outputByteBudgetPerTerminalPerSecond = 4 * 1024 * 1024
    private let outputByteBudgetPerConnectionPerSecond = 8 * 1024 * 1024
    private var connectionBudgetWindowStart = Date()
    private var connectionBudgetSpent = 0

    /// Symmetric defensive limits on client→PTY input. Output was already
    /// budgeted, but a compromised or malicious authenticated client could
    /// otherwise flood the PTY (and the child process) with input. Keystrokes
    /// and even large pastes are far below these caps, so legitimate use is
    /// unaffected.
    private let inputByteBudgetPerTerminalPerSecond = 1 * 1024 * 1024
    private let inputByteBudgetPerConnectionPerSecond = 2 * 1024 * 1024
    private var connectionInputBudgetWindowStart = Date()
    private var connectionInputBudgetSpent = 0

    /// Pump read buffer — 16 KB is a good balance between throughput on
    /// `cat large.txt` and latency for keystroke echo.
    private let readBufferSize = 16 * 1024

    /// How long a detached session's terminals keep running with no client
    /// attached. Long enough that backgrounding the phone (or a network
    /// change) for hours never kills work; short enough that abandoned
    /// shells cannot accumulate on the host forever.
    /// Step B replaces this with the durable registry's retention policy.
    let detachedRetentionSeconds: Double

    /// Per-terminal byte budget for the reattach replay buffer. Eight tabs
    /// at this budget cost at most ~2 MB of host memory.
    private let reattachReplayByteBudget = 256 * 1024

    private var activeTerminals: [UUID: ActiveSession] = [:]
    /// Sessions whose transport ended but whose terminals keep running.
    private var detachedSessions: Set<UUID> = []
    private var detachTimers: [UUID: Task<Void, Never>] = [:]

    /// Set by the environment; called whenever the service produces an
    /// outgoing envelope (output chunk or close notice).
    var sendEnvelope: ((DataChannelEnvelope) -> Void)?

    /// Durable session registry (step B). Optional so the browser-control
    /// per-client instances and tests can run without one.
    var registry: HostSessionRegistry?

    /// Durable semantic journal (step C). Optional for tests/browser
    /// per-client instances.
    var journal: HostSessionJournal?

    init(workspaceService: HostWorkspaceService? = nil, detachedRetentionSeconds: Double = 6 * 60 * 60) {
        self.workspaceService = workspaceService
        self.detachedRetentionSeconds = detachedRetentionSeconds
    }

    // MARK: - API

    /// Open a new terminal for `sessionID`. Re-opening the same terminal ID is
    /// idempotent, which makes client retries safe without resetting shell state.
    func handleOpen(_ message: TerminalOpenMessage) {
        queue.async { [weak self] in
            self?._handleOpen(message)
        }
    }

    func handleInput(_ message: TerminalInputMessage) {
        queue.async { [weak self] in
            self?._handleInput(message)
        }
    }

    func handleResize(_ message: TerminalResizeMessage) {
        queue.async { [weak self] in
            self?._handleResize(message)
        }
    }

    func handleClose(_ message: TerminalCloseMessage) {
        queue.async { [weak self] in
            self?._handleClose(message)
        }
    }

    /// Publishes a semantic task-plan mutation for one authenticated terminal.
    /// Agent adapters call this with structured events; it is deliberately
    /// separate from PTY output so a VT repaint can never become a task card.
    func publishTaskPlanEvent(_ message: SessionTaskEventMessage) {
        queue.async { [weak self] in
            guard let self,
                  let session = self.activeTerminals[message.terminalID],
                  session.sessionID == message.sessionID,
                  session.terminalID == message.terminalID,
                  message.event.isBound(toSessionID: message.sessionID, terminalID: message.terminalID) else {
                self?.logger.debug("Ignoring task-plan event for unknown or mismatched terminal")
                return
            }
            self.sendTaskPlanEvent(message)
        }
    }

    /// Conservative fallback hook for an agent integration that has already
    /// produced a stable semantic block. This method never receives PTY
    /// bytes or VT screen rows. Providers with native event APIs should call
    /// `publishTaskPlanEvent` directly instead.
    func consumeSemanticAgentOutput(
        _ semanticText: String,
        sessionID: UUID,
        terminalID: UUID,
        title: String? = nil
    ) {
        queue.async { [weak self] in
            guard let self,
                  let session = self.activeTerminals[terminalID],
                  session.sessionID == sessionID,
                  session.terminalID == terminalID,
                  let plan = SessionTaskPlanDetector.infer(
                    from: semanticText,
                    sessionID: sessionID,
                    terminalID: terminalID,
                    title: title
                  ) else {
                return
            }
            self.sendTaskPlanEvent(
                SessionTaskEventMessage(
                    sessionID: sessionID,
                    terminalID: terminalID,
                    event: .planCreated(plan)
                )
            )
        }
    }

    /// The transport that served `sessionID` ended. Terminals keep running —
    /// session ownership is independent of the socket. A reconnect presenting
    /// the same session and terminal IDs reattaches without spawning shells.
    /// An abandoned session is torn down after `detachedRetentionSeconds`.
    func transportDetached(sessionID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.detachedSessions.contains(sessionID),
                  self.activeTerminals.values.contains(where: { $0.sessionID == sessionID }) else { return }
            self.detachedSessions.insert(sessionID)
            let count = self.activeTerminals.values.filter { $0.sessionID == sessionID }.count
            let retentionNanos = UInt64(self.detachedRetentionSeconds * 1_000_000_000)
            self.logger.info("Transport detached — \(count) terminal(s) keep running for session \(sessionID.uuidString)")
            self.registry?.markSessionDetached(sessionID)
            self.journal?.append(sessionID: sessionID, type: .sessionDetached, payload: Data())
            self.detachTimers[sessionID] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: retentionNanos)
                guard !Task.isCancelled, let self else { return }
                self.queue.async {
                    self.detachTimers.removeValue(forKey: sessionID)
                    guard self.detachedSessions.contains(sessionID) else { return }
                    for session in self.activeTerminals.values.filter({ $0.sessionID == sessionID }) {
                        self._teardown(session, reason: "detached-retention-expired", notifyClient: false)
                    }
                    self.detachedSessions.remove(sessionID)
                    self.logger.info("Detached retention expired — session \\(sessionID.uuidString) terminals torn down")
                }
            }
        }
    }

    /// A new transport took over `sessionID` — cancel any pending detached
    /// retention teardown so the reconnecting client can reattach.
    func transportAttached(sessionID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.detachTimers[sessionID]?.cancel()
            self.detachTimers.removeValue(forKey: sessionID)
            self.registry?.markSessionAttached(sessionID)
            self.journal?.append(sessionID: sessionID, type: .sessionAttached, payload: Data())
            if self.detachedSessions.remove(sessionID) != nil {
                let count = self.activeTerminals.values.filter { $0.sessionID == sessionID }.count
                self.logger.info("Transport reattached — \(count) terminal(s) resume for session \(sessionID.uuidString)")
            }
        }
    }

    /// Number of live PTYs across all sessions. Diagnostics/tests only;
    /// synchronous read on the service queue.
    var activeTerminalCount: Int {
        queue.sync { activeTerminals.count }
    }

    /// Called by the coordinator when the session ends, the data channel
    /// drops, or the host pipeline resets. Kills the shell and cleans up.
    ///
    /// This is the EXPLICIT teardown path (host quit, Terminal Mode disabled,
    /// per-tab close): transport loss alone must never reach here — use
    /// `transportDetached(sessionID:)` for that so backgrounding a client
    /// cannot kill remote work.
    func sessionDidEnd(notifyClient: Bool = false, reason: String = "session-ended") {
        queue.async { [weak self] in
            guard let self else { return }
            for timer in self.detachTimers.values { timer.cancel() }
            self.detachTimers.removeAll()
            self.detachedSessions.removeAll()
            self._teardownAll(reason: reason, notifyClient: notifyClient)
        }
    }

    // MARK: - Internal (queue-isolated)

    private func _handleOpen(_ message: TerminalOpenMessage) {
        if let existing = activeTerminals[message.terminalID] {
            // A terminal ID belongs to one session. Do not let a stale or
            // mismatched packet replace another session's PTY.
            guard existing.sessionID == message.sessionID else {
                logger.warning("Rejecting terminal open with mismatched session for \(message.terminalID.uuidString)")
                return
            }
            logger.info("Re-acknowledging terminal \(existing.terminalID.uuidString) on retry/reattach")
            registry?.markSessionAttached(existing.sessionID)
            registry?.recordTerminalOpened(
                HostSessionRegistry.TerminalRecord(
                    terminalID: existing.terminalID,
                    workspaceID: existing.workspaceID,
                    workspacePath: existing.workingDirectory,
                    cols: existing.cols,
                    rows: existing.rows,
                    lastSequence: existing.outputSequence,
                    state: .running,
                    createdAt: Date(),
                    lastActivityAt: Date()
                ),
                sessionID: existing.sessionID
            )
            sendReady(for: existing, isReopen: true)
            // Replay the bounded output tail so a reattaching client restores
            // its screen instead of starting blank. Sequences are preserved,
            // so a client that already applied these chunks drops them.
            for entry in existing.recentOutput {
                let message = TerminalOutputMessage(
                    sessionID: existing.sessionID,
                    terminalID: existing.terminalID,
                    data: entry.data,
                    sequence: entry.sequence
                )
                if let envelope = try? DataChannelEnvelope.terminalOutput(message) {
                    sendEnvelope?(envelope)
                }
            }
            return
        }

        // Cap terminals per authenticated session. A reconnect reattaching the
        // same IDs consumes no extra capacity, but one session can never turn
        // the host into an unbounded process/fd farm.
        let sameSessionCount = activeTerminals.values.filter { $0.sessionID == message.sessionID }.count
        guard sameSessionCount < Self.maxActiveTerminals else {
            logger.warning("Rejecting terminal open: capacity limit \(Self.maxActiveTerminals) reached for session \(message.sessionID.uuidString)")
            sendCloseNotice(
                sessionID: message.sessionID,
                terminalID: message.terminalID,
                exitCode: nil,
                signal: nil,
                reason: "terminal-capacity"
            )
            return
        }

        let cols = clampDimension(message.cols, fallback: 80)
        let rows = clampDimension(message.rows, fallback: 24)
        let workingDirectory: String
        if let requestedPath = message.workingDirectory {
            let validated = workspaceService.map { $0.validatedWorkingDirectory(requestedPath) }
                ?? Self.validateHomeWorkingDirectory(requestedPath)
            guard let validated else {
                logger.warning("Rejecting terminal open for unavailable working directory")
                sendCloseNotice(
                    sessionID: message.sessionID,
                    terminalID: message.terminalID,
                    exitCode: nil,
                    signal: nil,
                    reason: "workspace-unavailable"
                )
                return
            }
            workingDirectory = validated
        } else {
            workingDirectory = workspaceService?.homePath ?? NSHomeDirectory()
        }

        if let requestedWorkspaceID = message.workspaceID,
           let workspaceService,
           workspaceService.workspaceID(for: workingDirectory) != requestedWorkspaceID {
            logger.warning("Rejecting terminal open with workspace identity mismatch")
            sendCloseNotice(
                sessionID: message.sessionID,
                terminalID: message.terminalID,
                exitCode: nil,
                signal: nil,
                reason: "workspace-mismatch"
            )
            return
        }

        var master: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        let pid = c_forkpty(&master, nil, nil, &ws)
        if pid < 0 {
            let err = String(cString: strerror(errno))
            logger.error("forkpty failed: \(err)")
            sendCloseNotice(
                sessionID: message.sessionID,
                terminalID: message.terminalID,
                exitCode: nil,
                signal: nil,
                reason: "forkpty failed: \(err)"
            )
            return
        }

        if pid == 0 {
            // Child process — replace with the user's shell.
            execShellAndExit(
                term: message.term ?? "xterm-256color",
                workingDirectory: workingDirectory,
                launchExecutable: message.launchExecutable,
                launchArguments: message.launchArguments
            )
            // execShellAndExit never returns; defensive fallback below.
            _exit(127)
        }

        // Parent — record the session and start pumps.
        let session = ActiveSession(
            sessionID: message.sessionID,
            terminalID: message.terminalID,
            masterFD: master,
            childPID: pid,
            cols: cols,
            rows: rows,
            workspaceID: message.workspaceID,
            workingDirectory: workingDirectory,
            outputSequence: 0
        )
        activeTerminals[session.terminalID] = session
        logger.info("Spawned PTY shell pid=\(pid) for terminal \(message.terminalID.uuidString)")
        registry?.upsertSession(session.sessionID)
        if let payload = try? JSONEncoder().encode(message) {
            journal?.append(sessionID: session.sessionID, type: .terminalOpened, payload: payload)
        }
        registry?.recordTerminalOpened(
            HostSessionRegistry.TerminalRecord(
                terminalID: session.terminalID,
                workspaceID: session.workspaceID,
                workspacePath: session.workingDirectory,
                cols: session.cols,
                rows: session.rows,
                lastSequence: 0,
                state: .running,
                createdAt: Date(),
                lastActivityAt: Date()
            ),
            sessionID: session.sessionID
        )

        // Start consuming the PTY before acknowledging it. A login shell can
        // emit bytes immediately (and a launcher can be sent immediately by
        // the client); installing the read source first prevents that first
        // burst from racing the ready message and makes the shell lifecycle
        // deterministic on slow Tailscale connections.
        startReadPump(for: session)
        startReaperTask(for: session)
        sendReady(for: session)

        // Feed an optional one-line launcher after the shell is created. PTY
        // input is buffered until the login shell is ready, so this also lets
        // tmux/screen reattach an already-running session without requiring a
        // second round trip or a fragile prompt detector on the client.
        if let startupCommand = message.startupCommand, message.launchExecutable == nil {
            writeStartupCommand(startupCommand, to: session)
        }

    }

    private func _handleClose(_ message: TerminalCloseMessage) {
        guard let session = activeTerminals[message.terminalID],
              session.sessionID == message.sessionID else {
            logger.debug("Ignoring close for unknown or mismatched terminal \(message.terminalID.uuidString)")
            return
        }
        _teardown(session, reason: message.reason ?? "client-requested", notifyClient: false)
    }

    private func _handleInput(_ message: TerminalInputMessage) {
        guard let session = activeTerminals[message.terminalID],
              session.sessionID == message.sessionID,
              session.terminalID == message.terminalID else {
            return
        }
        guard !message.data.isEmpty,
              message.data.count <= TerminalInputMessage.maxChunkBytes else {
            return
        }
        guard let chunk = claimInputBudget(message.data, session: session) else {
            logger.warning("Dropping terminal input: input byte budget exhausted")
            return
        }

        write(chunk, to: session)
    }

    /// Mirrors `dispatchOutput`'s rate budget for the input direction.
    /// Refills both the connection-wide and per-terminal windows each second
    /// and returns the bytes the caller may write, or nil when saturated.
    private func claimInputBudget(_ data: Data, session: ActiveSession) -> Data? {
        let now = Date()
        if now.timeIntervalSince(connectionInputBudgetWindowStart) >= 1.0 {
            connectionInputBudgetWindowStart = now
            connectionInputBudgetSpent = 0
        }
        if now.timeIntervalSince(session.inputBudgetWindowStart) >= 1.0 {
            session.inputBudgetWindowStart = now
            session.inputBudgetSpent = 0
        }
        guard connectionInputBudgetSpent < inputByteBudgetPerConnectionPerSecond,
              session.inputBudgetSpent < inputByteBudgetPerTerminalPerSecond else {
            return nil
        }
        let headroom = min(
            inputByteBudgetPerConnectionPerSecond - connectionInputBudgetSpent,
            inputByteBudgetPerTerminalPerSecond - session.inputBudgetSpent
        )
        let chunk = data.count > headroom ? data.prefix(headroom) : data
        connectionInputBudgetSpent += chunk.count
        session.inputBudgetSpent += chunk.count
        return chunk
    }

    private func writeStartupCommand(_ command: String, to session: ActiveSession) {
        // Startup commands are typed into an interactive PTY. Enter is CR,
        // not LF; TUIs and line editors are not required to submit on LF.
        let data = Data((command + "\r").utf8)
        guard data.count <= TerminalInputMessage.maxChunkBytes else { return }
        write(data, to: session)
    }

    private func write(_ data: Data, to session: ActiveSession) {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(session.masterFD, base, raw.count)
            }
            if written <= 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { return }  // PTY buffer full; drop rest
                let err = String(cString: strerror(errno))
                logger.warning("write to PTY failed: \(err)")
                return
            }
            if written >= remaining.count { return }
            remaining = remaining.subdata(in: written..<remaining.count)
        }
    }

    private func _handleResize(_ message: TerminalResizeMessage) {
        guard let session = activeTerminals[message.terminalID],
              session.sessionID == message.sessionID,
              session.terminalID == message.terminalID else {
            return
        }
        var ws = winsize(
            ws_row: clampDimension(message.rows, fallback: 24),
            ws_col: clampDimension(message.cols, fallback: 80),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        if ioctl(session.masterFD, TIOCSWINSZ, &ws) != 0 {
            let err = String(cString: strerror(errno))
            logger.warning("TIOCSWINSZ failed: \(err)")
        } else {
            session.cols = ws.ws_col
            session.rows = ws.ws_row
            registry?.recordTerminalProgress(
                sessionID: session.sessionID,
                terminalID: session.terminalID,
                lastSequence: session.outputSequence,
                cols: session.cols,
                rows: session.rows
            )
        }
    }

    private func _teardownAll(reason: String, notifyClient: Bool) {
        let sessions = Array(activeTerminals.values)
        for session in sessions {
            _teardown(session, reason: reason, notifyClient: notifyClient)
        }
    }

    private func _teardown(_ session: ActiveSession, reason: String, notifyClient: Bool) {
        guard activeTerminals[session.terminalID] === session else { return }
        activeTerminals.removeValue(forKey: session.terminalID)

        session.readSource?.cancel()
        session.readSource = nil
        // Keep the reaper alive after teardown so the SIGHUP'd child is still
        // collected by waitpid instead of becoming a zombie. Its completion
        // observes that the terminal was removed and does not send a second
        // close notice.

        // forkpty makes the shell a session/process-group leader. Signal the
        // whole group so tmux, screen, and agent children do not survive a
        // tab close or connection teardown as orphaned processes. Keep the
        // direct-child fallback for shells started without that guarantee.
        if session.childPID > 0 {
            _ = kill(-session.childPID, SIGHUP)
            _ = kill(session.childPID, SIGHUP)
        }
        close(session.masterFD)

        registry?.markTerminalReaped(
            sessionID: session.sessionID,
            terminalID: session.terminalID,
            lastSequence: session.outputSequence
        )
        journalTerminalClosed(
            sessionID: session.sessionID,
            terminalID: session.terminalID,
            reason: reason
        )
        let sessionStillHasTerminals = activeTerminals.values.contains { $0.sessionID == session.sessionID }
        if !sessionStillHasTerminals {
            registry?.removeSession(session.sessionID)
            journal?.remove(sessionID: session.sessionID)
        }

        if notifyClient {
            sendCloseNotice(
                sessionID: session.sessionID,
                terminalID: session.terminalID,
                exitCode: nil,
                signal: nil,
                reason: reason
            )
        }
        logger.info("Terminal \(session.terminalID.uuidString) torn down (\(reason))")
    }

    // MARK: - Read pump

    private func startReadPump(for session: ActiveSession) {
        let source = DispatchSource.makeReadSource(fileDescriptor: session.masterFD, queue: queue)
        session.readSource = source
        let bufferSize = readBufferSize

        source.setEventHandler { [weak self, weak session] in
            guard let self,
                  let session,
                  self.activeTerminals[session.terminalID] === session else { return }
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                read(session.masterFD, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                self.dispatchOutput(Data(buffer.prefix(n)), session: session)
            } else if n == 0 {
                self.logger.info("PTY master EOF for terminal \(session.terminalID.uuidString)")
                self._teardown(session, reason: "eof", notifyClient: true)
            } else {
                if errno == EAGAIN || errno == EINTR { return }
                let err = String(cString: strerror(errno))
                self.logger.warning("PTY read failed: \(err)")
                self._teardown(session, reason: "read-error: \(err)", notifyClient: true)
            }
        }
        source.setCancelHandler { /* fd closed by _teardown */ }
        source.resume()
    }

    private func dispatchOutput(_ data: Data, session: ActiveSession) {
        // Refill the connection-wide rate budget every second.
        let now = Date()
        if now.timeIntervalSince(connectionBudgetWindowStart) >= 1.0 {
            connectionBudgetWindowStart = now
            connectionBudgetSpent = 0
        }
        if now.timeIntervalSince(session.budgetWindowStart) >= 1.0 {
            session.budgetWindowStart = now
            session.budgetSpent = 0
        }
        guard connectionBudgetSpent < outputByteBudgetPerConnectionPerSecond,
              session.budgetSpent < outputByteBudgetPerTerminalPerSecond else {
            // Already saturated this second — drop to protect the link.
            return
        }
        var chunk = data
        let headroom = min(
            outputByteBudgetPerConnectionPerSecond - connectionBudgetSpent,
            outputByteBudgetPerTerminalPerSecond - session.budgetSpent
        )
        if chunk.count > headroom {
            chunk = chunk.prefix(headroom)
        }
        connectionBudgetSpent += chunk.count
        session.budgetSpent += chunk.count

        // Split into envelope-sized pieces; the envelope cap is 1 MB but
        // staying well under that keeps RTC fragmentation predictable.
        let maxChunk = TerminalOutputMessage.maxChunkBytes
        var offset = 0
        while offset < chunk.count {
            let end = min(offset + maxChunk, chunk.count)
            session.outputSequence += 1
            let slice = chunk.subdata(in: offset..<end)
            let message = TerminalOutputMessage(
                sessionID: session.sessionID,
                terminalID: session.terminalID,
                data: slice,
                sequence: session.outputSequence
            )
            if let envelope = try? DataChannelEnvelope.terminalOutput(message) {
                sendEnvelope?(envelope)
            }
            // Maintain the bounded reattach tail regardless of whether a
            // client is currently attached, so a reconnect can restore the
            // screen instead of starting blank.
            session.recentOutput.append((session.outputSequence, slice))
            session.recentOutputBytes += slice.count
            while session.recentOutputBytes > reattachReplayByteBudget, let oldest = session.recentOutput.first {
                session.recentOutput.removeFirst()
                session.recentOutputBytes -= oldest.data.count
            }
            // Durable registry progress, throttled so streaming output does
            // not turn into a disk-write storm (once per 10 s per terminal).
            if now.timeIntervalSince(session.lastRegistryFlushAt) >= 10.0 {
                session.lastRegistryFlushAt = now
                registry?.recordTerminalProgress(
                    sessionID: session.sessionID,
                    terminalID: session.terminalID,
                    lastSequence: session.outputSequence
                )
            }
            offset = end
        }
    }

    // MARK: - Child reaper

    private func startReaperTask(for session: ActiveSession) {
        let pid = session.childPID
        let terminalID = session.terminalID
        let sessionID = session.sessionID
        let task = Task { [weak self] in
            // Poll waitpid; SIGCHLD handling in Swift is awkward and this loop
            // is cheap (sleep, single syscall).
            while !Task.isCancelled {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid {
                    guard let self else { return }
                    let (exitCode, signal) = self.decodeWaitStatus(status)
                    self.handleChildExit(
                        sessionID: sessionID,
                        terminalID: terminalID,
                        exitCode: exitCode,
                        signal: signal
                    )
                    return
                } else if result < 0 {
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        session.reaperTask = task
    }

    private func handleChildExit(sessionID: UUID, terminalID: UUID, exitCode: Int32?, signal: Int32?) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let session = self.activeTerminals[terminalID],
                  session.sessionID == sessionID,
                  session.terminalID == terminalID else { return }
            self.logger.info("Child pid=\(session.childPID) exited (code=\(exitCode ?? -1), signal=\(signal ?? -1))")
            self.activeTerminals.removeValue(forKey: terminalID)
            session.readSource?.cancel()
            close(session.masterFD)
            self.registry?.markTerminalReaped(
                sessionID: sessionID,
                terminalID: terminalID,
                lastSequence: session.outputSequence
            )
            self.journalTerminalClosed(sessionID: sessionID, terminalID: terminalID, reason: "shell-exited")
            let sessionStillHasTerminals = self.activeTerminals.values.contains { $0.sessionID == sessionID }
            if !sessionStillHasTerminals {
                self.registry?.removeSession(sessionID)
                self.journal?.remove(sessionID: sessionID)
            }
            self.sendCloseNotice(
                sessionID: sessionID,
                terminalID: terminalID,
                exitCode: exitCode,
                signal: signal,
                reason: "shell-exited"
            )
        }
    }

    private func sendCloseNotice(sessionID: UUID, terminalID: UUID, exitCode: Int32?, signal: Int32?, reason: String?) {
        let message = TerminalCloseMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            exitCode: exitCode,
            signal: signal,
            reason: reason
        )
        if let envelope = try? DataChannelEnvelope.terminalClose(message) {
            sendEnvelope?(envelope)
        }
    }

    /// Appends a `.terminalClosed` semantic event to the durable journal.
    private func journalTerminalClosed(sessionID: UUID, terminalID: UUID, reason: String) {
        let message = TerminalCloseMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            exitCode: nil,
            signal: nil,
            reason: reason
        )
        if let payload = try? JSONEncoder().encode(message) {
            journal?.append(sessionID: sessionID, type: .terminalClosed, payload: payload)
        }
    }

    private func sendTaskPlanEvent(_ message: SessionTaskEventMessage) {
        var sequenced = message
        if let journal {
            sequenced.journalSequence = journal.append(
                sessionID: message.sessionID,
                type: .taskPlan,
                payload: (try? JSONEncoder().encode(message)) ?? Data()
            )
        }
        guard let envelope = try? DataChannelEnvelope.taskPlanEvent(sequenced) else {
            logger.error("Could not encode task-plan event")
            return
        }
        sendEnvelope?(envelope)
    }

    // MARK: - Child exec

    private func sendReady(for session: ActiveSession, isReopen: Bool = false) {
        let ready = TerminalReadyMessage(
            sessionID: session.sessionID,
            terminalID: session.terminalID,
            cols: session.cols,
            rows: session.rows,
            isReopen: isReopen
        )
        if let envelope = try? DataChannelEnvelope.terminalReady(ready) {
            logger.info("Dispatching terminal-ready envelope")
            sendEnvelope?(envelope)
        } else {
            logger.error("Could not encode terminal-ready envelope")
        }
    }

    private func execShellAndExit(
        term: String,
        workingDirectory: String,
        launchExecutable: String?,
        launchArguments: [String]
    ) {
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let home = env["HOME"] ?? NSHomeDirectory()

        // Build env with TERM forced to xterm-256color so curses-style apps
        // (vim/nano/htop/less) render correctly. Strip the variables we want
        // to override before reconstructing.
        var envDict = env
        envDict["TERM"] = term
        envDict["HOME"] = home
        envDict["LANG"] = envDict["LANG"] ?? "en_US.UTF-8"
        envDict["LC_ALL"] = envDict["LC_ALL"] ?? "en_US.UTF-8"

        // GUI-launched macOS apps do not inherit the interactive shell's
        // PATH. Agent CLIs installed by Homebrew, npm, pipx, or a user's
        // local bin directory therefore appear to be missing even though the
        // same command works in Terminal.app. Preserve the inherited value,
        // then add the conventional locations once, in a deterministic order.
        // This also makes provider launchers and tmux handoff behave the same
        // from the native client and Safari.
        let inheritedPath = envDict["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let commonPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/bin",
            // Agent installers frequently drop binaries outside Homebrew, e.g.
            // the official opencode installer uses ~/.opencode/bin. Include the
            // common per-user tool dirs so launchers resolve without a
            // login-shell PATH.
            "\(home)/.opencode/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.deno/bin",
            "\(home)/.volta/bin"
        ]
        var pathEntries = inheritedPath.split(separator: ":").map(String.init)
        for path in commonPaths where !pathEntries.contains(path) {
            pathEntries.append(path)
        }
        envDict["PATH"] = pathEntries.joined(separator: ":")

        var envStrings = envDict.map { "\($0.key)=\($0.value)" }
        envStrings.sort()
        var envCPtrs = envStrings.map { strdup($0) } as [UnsafeMutablePointer<CChar>?]
        envCPtrs.append(nil)

        // Do not source the user's login files for a remote PTY. GUI-launched
        // hosts frequently inherit a zsh `$SHELL` while a dotfile sources a
        // bash completion script, producing `complete: command not found`
        // before the first prompt. We still respect the configured shell
        // binary, but use a clean interactive invocation so the PTY starts
        // deterministically. Environment and cwd are supplied above.
        let shellName = URL(fileURLWithPath: shell).lastPathComponent.lowercased()
        let shellFlags: [String]
        if shellName == "zsh" {
            shellFlags = ["-f", "-i"]
        } else if shellName == "bash" {
            shellFlags = ["--noprofile", "--norc", "-i"]
        } else {
            shellFlags = ["-i"]
        }
        var argvArr: [UnsafeMutablePointer<CChar>?] = [strdup("-" + shellName)]
        argvArr.append(contentsOf: shellFlags.map { strdup($0) })
        argvArr.append(nil)

        // Set the process cwd before the shell is exec'd. This keeps the
        // selected workspace out of the visible transcript and means the
        // first shell/agent instruction sees the correct directory.
        guard chdir(workingDirectory) == 0 else {
            perror("chdir")
            _exit(126)
        }

        // Agent launchers use a direct exec path so the PTY does not first
        // echo a hidden `if command -v …; tmux …` bootstrap command. Resolve
        // the executable from the host-owned PATH and keep all validation on
        // the host; the client never supplies an arbitrary absolute path.
        if let launchExecutable {
            let isSafeName = !launchExecutable.isEmpty
                && launchExecutable.count <= 128
                && !launchExecutable.contains("/")
                && !launchExecutable.contains("\\")
                && !launchExecutable.contains("..")
                && launchExecutable.unicodeScalars.allSatisfy { scalar in
                    let value = scalar.value
                    return (value >= 65 && value <= 90)
                        || (value >= 97 && value <= 122)
                        || (value >= 48 && value <= 57)
                        || value == 46 || value == 95 || value == 45 || value == 43
                }
            guard isSafeName else {
                fputs("Vamp Terminal: invalid launcher.\n", stderr)
                _exit(126)
            }

            let executablePath = pathEntries
                .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(launchExecutable).path }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let executablePath else {
                fputs("Vamp Terminal: launcher is not installed or not on PATH.\n", stderr)
                _exit(127)
            }

            let safeArguments = Array(launchArguments.prefix(32)).filter { argument in
                argument.count <= 512 && !argument.contains("\0")
            }
            guard safeArguments.count == min(launchArguments.count, 32) else {
                fputs("Vamp Terminal: invalid launcher arguments.\n", stderr)
                _exit(126)
            }
            let argumentStrings = [executablePath] + safeArguments
            var argumentPointers = argumentStrings.map { strdup($0) }
            argumentPointers.append(nil)
            envCPtrs.withUnsafeBufferPointer { envBuf in
                argumentPointers.withUnsafeBufferPointer { argBuf in
                    _ = execve(
                        executablePath,
                        UnsafeMutablePointer(mutating: argBuf.baseAddress),
                        UnsafeMutablePointer(mutating: envBuf.baseAddress)
                    )
                }
            }
            perror("execve")
            _exit(127)
        }

        envCPtrs.withUnsafeBufferPointer { envBuf in
            argvArr.withUnsafeBufferPointer { argBuf in
                _ = execve(
                    shell,
                    UnsafeMutablePointer(mutating: argBuf.baseAddress),
                    UnsafeMutablePointer(mutating: envBuf.baseAddress)
                )
            }
        }
        // execve only returns on failure.
        perror("execve")
        _exit(127)
    }

    // MARK: - Helpers

    private func clampDimension(_ value: UInt16, fallback: UInt16) -> UInt16 {
        guard value > 0 else { return fallback }
        return min(value, 1000)
    }

    private static func validateHomeWorkingDirectory(_ path: String) -> String? {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate = URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let homePath = home.path.hasSuffix("/") ? home.path : home.path + "/"
        guard candidate.path == home.path || candidate.path.hasPrefix(homePath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return candidate.path
    }

    private func decodeWaitStatus(_ status: Int32) -> (exitCode: Int32?, signal: Int32?) {
        // WIFEXITED / WIFSIGNALED — open-coded because Swift doesn't import
        // the macros from <sys/wait.h>.
        let lowByte = status & 0x7f
        if lowByte == 0 {
            return ((status >> 8) & 0xff, nil)
        }
        if lowByte != 0x7f {
            return (nil, lowByte)
        }
        return (nil, nil)
    }

    private final class ActiveSession {
        let sessionID: UUID
        let terminalID: UUID
        let masterFD: Int32
        let childPID: pid_t
        var cols: UInt16
        var rows: UInt16
        let workspaceID: UUID?
        let workingDirectory: String
        var outputSequence: UInt64
        var budgetWindowStart = Date()
        var budgetSpent = 0
        var inputBudgetWindowStart = Date()
        var inputBudgetSpent = 0
        var readSource: DispatchSourceRead?
        var reaperTask: Task<Void, Never>?
        /// Bounded recent output kept for reattach replay. Sequence numbers are
        /// preserved so a reattaching client can dedupe chunks it already has.
        var recentOutput: [(sequence: UInt64, data: Data)] = []
        var recentOutputBytes = 0
        /// Last time durable registry progress was flushed for this terminal.
        var lastRegistryFlushAt = Date.distantPast

        init(
            sessionID: UUID,
            terminalID: UUID,
            masterFD: Int32,
            childPID: pid_t,
            cols: UInt16,
            rows: UInt16,
            workspaceID: UUID?,
            workingDirectory: String,
            outputSequence: UInt64
        ) {
            self.sessionID = sessionID
            self.terminalID = terminalID
            self.masterFD = masterFD
            self.childPID = childPID
            self.cols = cols
            self.rows = rows
            self.workspaceID = workspaceID
            self.workingDirectory = workingDirectory
            self.outputSequence = outputSequence
        }
    }
}

/// Host-side workspace discovery and browsing. This service intentionally uses
/// Foundation filesystem APIs rather than shell interpolation so a client path
/// can never become a command injection primitive. It only exposes directories
/// below the current user's home directory and the small set of developer roots
/// advertised to the client.
final class HostWorkspaceService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "host.workspace.service", qos: .utility)
    /// Interactive directory navigation must never wait behind project
    /// discovery. Discovery can traverse thousands of folders, while a tap in
    /// the workspace browser has a short client-side response deadline.
    private let browseQueue = DispatchQueue(label: "host.workspace.browser", qos: .userInitiated)
    private let fileManager = FileManager.default
    let hostID: UUID
    let homePath: String
    private var cachedWorkspaces: [RemoteWorkspace]?
    private var approvedRootURLs: [URL] = []
    private let approvedRootsLock = NSLock()
    private let approvedRootsDefaultsKey: String
    private let discoveryDelayForTesting: TimeInterval

    init(
        hostID: UUID,
        homePath: String = NSHomeDirectory(),
        discoveryDelayForTesting: TimeInterval = 0
    ) {
        self.hostID = hostID
        self.approvedRootsDefaultsKey = "com.mesutcy.vamp-terminal.workspace-roots.\(hostID.uuidString)"
        self.discoveryDelayForTesting = discoveryDelayForTesting
        self.homePath = Self.canonicalPath(
            URL(fileURLWithPath: homePath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        )
        restoreApprovedRoots()
    }

    /// Persists an explicitly user-selected directory. The resolved URLs are
    /// retained for the service lifetime so one approval can serve browsing,
    /// discovery, and PTY launches without reopening the panel.
    @discardableResult
    func addApprovedRoot(_ url: URL) -> Bool {
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        _ = canonicalURL.startAccessingSecurityScopedResource()
        approvedRootsLock.lock()
        if !approvedRootURLs.contains(where: { Self.canonicalPath($0.path) == Self.canonicalPath(canonicalURL.path) }) {
            approvedRootURLs.append(canonicalURL)
        }
        let roots = approvedRootURLs
        approvedRootsLock.unlock()
        persistApprovedRoots(roots)
        cachedWorkspaces = nil
        return true
    }

    func listWorkspaces(
        refresh: Bool,
        completion: @escaping @Sendable ([RemoteWorkspace], [WorkspaceBrowseRoot], String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            if !refresh, let cached = self.cachedWorkspaces {
                completion(cached, self.browseRoots(), nil)
                return
            }
            let result = self.discoverWorkspaces()
            self.cachedWorkspaces = result
            completion(result, self.browseRoots(), nil)
        }
    }

    /// Fast, non-recursive roots for launch UI. Project discovery may take
    /// longer on a large Desktop/Documents tree, so clients can present a
    /// useful workspace chooser immediately while discovery finishes.
    func availableBrowseRoots() -> [WorkspaceBrowseRoot] {
        browseRoots()
    }

    func listDirectory(
        path: String,
        completion: @escaping @Sendable (String, [WorkspaceDirectoryEntry], String?) -> Void
    ) {
        browseQueue.async { [weak self] in
            guard let self else { return }
            guard let canonical = self.validatedWorkingDirectory(path) else {
                completion(path, [], "That folder is unavailable or outside the allowed workspace boundary.")
                return
            }
            do {
                // Directory navigation is latency-sensitive. Do not prefetch
                // resource metadata or enumerate every child to derive project
                // hints here: either operation can block indefinitely on a
                // protected or cloud-backed child of Home. Rich metadata is
                // provided by background discovery after the user selects a
                // workspace.
                let names = try self.fileManager.contentsOfDirectory(atPath: canonical)
                let entries = names.compactMap { name -> WorkspaceDirectoryEntry? in
                    let url = URL(fileURLWithPath: canonical, isDirectory: true)
                        .appendingPathComponent(name, isDirectory: true)
                    var isDirectory: ObjCBool = false
                    guard self.fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                          isDirectory.boolValue else { return nil }
                    return WorkspaceDirectoryEntry(
                        name: name,
                        path: url.path,
                        isDirectory: true,
                        isReadable: self.fileManager.isReadableFile(atPath: url.path),
                        isGitRepository: false,
                        projectHints: []
                    )
                }
                completion(canonical, entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, nil)
            } catch {
                completion(canonical, [], "Unable to read that folder.")
            }
        }
    }

    /// Canonicalize and validate a client-provided cwd. This method is safe to
    /// call from the terminal service's serial queue and does not dispatch back
    /// to this service's queue.
    func validatedWorkingDirectory(_ path: String) -> String? {
        var requested = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if requested == "~" { requested = homePath }
        if requested.hasPrefix("~/") {
            requested = homePath + String(requested.dropFirst(1))
        }
        guard !requested.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: requested, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidatePath = Self.canonicalPath(candidate.path)
        let allowedRoots = [homePath] + approvedRootsSnapshot().map { Self.canonicalPath($0.path) }
        guard allowedRoots.contains(where: { root in
            candidatePath == root || candidatePath.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }) else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidatePath, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: candidatePath) else { return nil }
        return candidatePath
    }

    func workspaceID(for path: String) -> UUID? {
        guard let canonical = validatedWorkingDirectory(path) else { return nil }
        return stableWorkspaceID(path: canonical)
    }

    private func browseRoots() -> [WorkspaceBrowseRoot] {
        let candidates: [(String, String)] = [
            ("Home", homePath),
            ("Desktop", homePath + "/Desktop"),
            ("Documents", homePath + "/Documents"),
            ("Downloads", homePath + "/Downloads"),
            ("Developer", homePath + "/Developer"),
            ("Projects", homePath + "/Projects"),
            ("Sites", homePath + "/Sites")
        ]
        var roots: [WorkspaceBrowseRoot] = candidates.compactMap { name, path -> WorkspaceBrowseRoot? in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return WorkspaceBrowseRoot(name: name, path: path)
        }
        for url in approvedRootsSnapshot() {
            let path = Self.canonicalPath(url.path)
            guard !roots.contains(where: { Self.canonicalPath($0.path) == path }) else { continue }
            roots.append(WorkspaceBrowseRoot(name: url.lastPathComponent, path: path))
        }
        return roots
    }

    private func discoverWorkspaces() -> [RemoteWorkspace] {
        if discoveryDelayForTesting > 0 {
            Thread.sleep(forTimeInterval: discoveryDelayForTesting)
        }
        var found: [String: RemoteWorkspace] = [:]
        found[homePath] = RemoteWorkspace(
            id: stableWorkspaceID(path: homePath),
            hostID: hostID,
            name: "Home",
            path: homePath,
            kind: .home,
            gitInfo: nil,
            isAvailable: true
        )

        // Desktop, Documents, and Downloads are protected by macOS privacy.
        // Merely enumerating each of them during automatic discovery can
        // trigger several consent dialogs even though the user only asked to
        // open one workspace. Keep background discovery to conventional
        // developer roots. Protected locations remain available in the
        // explicit browser, where one deliberate user action may request
        // access to the chosen folder.
        let automaticRootNames: Set<String> = ["Developer", "Projects", "Sites"]
        let approvedPaths = Set(approvedRootsSnapshot().map { Self.canonicalPath($0.path) })
        let scanRoots = browseRoots().filter {
            automaticRootNames.contains($0.name) || approvedPaths.contains(Self.canonicalPath($0.path))
        }
        for root in scanRoots {
            let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else { continue }
            var inspectedDirectoryCount = 0
            for case let url as URL in enumerator {
                if Self.discoveryExcludedDirectoryNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                let depth = max(0, url.pathComponents.count - rootURL.pathComponents.count)
                if depth > 3 {
                    enumerator.skipDescendants()
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true else { continue }
                inspectedDirectoryCount += 1
                // Discovery is a convenience, never an unbounded filesystem
                // crawl. Users can still browse every advertised root.
                if inspectedDirectoryCount > 1_500 {
                    break
                }
                let hints = projectHints(at: url)
                let isGit = isGitRepository(at: url)
                guard isGit || !hints.isEmpty else { continue }
                let kind: WorkspaceKind = isGit ? .gitRepository : .folder
                let gitInfo = isGit
                    ? gitMetadata(at: url, projectHints: hints)
                    : GitWorkspaceInfo(projectHints: hints)
                let canonicalPath = Self.canonicalPath(url.path)
                found[canonicalPath] = RemoteWorkspace(
                    id: stableWorkspaceID(path: canonicalPath),
                    hostID: hostID,
                    name: url.lastPathComponent,
                    path: canonicalPath,
                    kind: kind,
                    gitInfo: gitInfo,
                    isAvailable: true
                )
            }
        }
        return found.values.sorted {
            if $0.kind == .home { return true }
            if $1.kind == .home { return false }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func isGitRepository(at url: URL) -> Bool {
        // Worktrees can represent .git as a file containing a gitdir pointer,
        // so do not require it to be a directory.
        return fileManager.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    private func projectHints(at url: URL) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
        var hints: [String] = []
        if names.contains("Package.swift") { hints += ["Swift", "Swift Package"] }
        if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0 == "project.pbxproj" }) {
            hints.append("Xcode")
        }
        if names.contains("package.json") { hints.append(names.contains("next.config.js") || names.contains("next.config.mjs") ? "Next.js" : "Node") }
        if names.contains("pnpm-lock.yaml") { hints.append("pnpm") }
        if names.contains("yarn.lock") { hints.append("Yarn") }
        if names.contains("Cargo.toml") { hints.append("Rust") }
        if names.contains("go.mod") { hints.append("Go") }
        if names.contains("pyproject.toml") || names.contains("requirements.txt") { hints.append("Python") }
        if names.contains("Gemfile") { hints.append("Ruby") }
        return NSOrderedSet(array: hints).array as? [String] ?? hints
    }

    private func gitMetadata(at url: URL, projectHints: [String]) -> GitWorkspaceInfo {
        let branch = runGit(["rev-parse", "--abbrev-ref", "HEAD"], at: url)
        let status = runGit(["status", "--porcelain"], at: url)
        let remote = runGit(["remote", "get-url", "origin"], at: url)
        let divergence = runGit(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], at: url)?
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .compactMap { Int($0) }
        return GitWorkspaceInfo(
            branch: branch?.isEmpty == false ? branch : nil,
            isDirty: !(status?.isEmpty ?? true),
            remoteURL: remote,
            ahead: divergence?.first,
            behind: divergence?.dropFirst().first,
            projectHints: projectHints
        )
    }

    private func runGit(_ arguments: [String], at directory: URL) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func stableWorkspaceID(path: String) -> UUID {
        var digest = Array(SHA256.hash(data: Data((hostID.uuidString + "\n" + path).utf8)))
        digest[6] = (digest[6] & 0x0f) | 0x50
        digest[8] = (digest[8] & 0x3f) | 0x80
        let bytes = digest.prefix(16)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted) ?? UUID()
    }

    private static let discoveryExcludedDirectoryNames: Set<String> = [
        ".git", ".build", "DerivedData", "node_modules", "Pods", "build",
        "dist", "vendor", "target", ".swiftpm"
    ]

    private func restoreApprovedRoots() {
        let bookmarks = UserDefaults.standard.array(forKey: approvedRootsDefaultsKey) as? [Data] ?? []
        let restored: [URL] = bookmarks.compactMap { data -> URL? in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { return nil }
            _ = url.startAccessingSecurityScopedResource()
            return url.resolvingSymlinksInPath().standardizedFileURL
        }
        approvedRootsLock.lock()
        approvedRootURLs = restored
        approvedRootsLock.unlock()
        if bookmarks.count != restored.count {
            persistApprovedRoots(restored)
        }
    }

    private func persistApprovedRoots(_ roots: [URL]? = nil) {
        let values = roots ?? approvedRootsSnapshot()
        let bookmarks = values.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: approvedRootsDefaultsKey)
    }

    private func approvedRootsSnapshot() -> [URL] {
        approvedRootsLock.lock()
        defer { approvedRootsLock.unlock() }
        return approvedRootURLs
    }

    private static func canonicalPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .path
        // macOS exposes /var and /tmp through /private aliases. Foundation's
        // directory enumerator can return the target spelling even when the
        // requested root used the public spelling. Normalize that alias so a
        // discovered workspace always passes the same boundary check used at
        // launch time.
        if standardized.hasPrefix("/private/") {
            return String(standardized.dropFirst("/private".count))
        }
        return standardized
    }
}
#endif
