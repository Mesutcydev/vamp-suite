import Foundation
import Combine
import SharedProtocol
import TransportWebRTC

/// Owns the lifecycle of a single Terminal Mode session on the client side.
///
/// The view binds to `output` to forward bytes into its emulator (SwiftTerm
/// `feed(byteArray:)`), to `state` to react to host-side shell exit / open
/// failures, and calls `sendInput`/`requestResize` from input/layout
/// callbacks. Bytes are forwarded as-is — escape interpretation is the
/// emulator's job.
@MainActor
final class ClientTerminalSessionManager: ObservableObject {

    enum State: Equatable {
        case idle
        case opening
        case open
        /// Host reported the shell exited or failed to spawn. `reason` is for
        /// diagnostics; the UI shows it under the prompt.
        case closed(exitCode: Int32?, signal: Int32?, reason: String?)
    }

    @Published private(set) var state: State = .idle
    /// Monotonically grows; the view observes count changes to feed new bytes
    /// to the emulator. We keep the last N chunks for diagnostics + replay
    /// when the view first attaches mid-session.
    @Published private(set) var output: [TerminalOutputMessage] = []

    private var sessionID: UUID?
    private(set) var terminalID: UUID?
    private var startupCommand: String?
    private(set) var workspaceID: UUID?
    private(set) var workingDirectory: String?
    private var launchExecutable: String?
    private var launchArguments: [String] = []
    private var sendEnvelope: ((DataChannelEnvelope) throws -> Void)?
    /// Holds input entered while the host is acknowledging a new PTY. This
    /// keeps the mobile composer useful during a slow WebRTC/Tailscale open
    /// without racing bytes into a PTY that does not exist yet.
    private var pendingInput = Data()
    private let pendingInputLimit = TerminalInputMessage.maxChunkBytes
    private var pendingInputRetryTask: Task<Void, Never>?
    private var lastRequestedResize: (cols: UInt16, rows: UInt16)?
    private(set) var currentTerminalSize: (cols: UInt16, rows: UInt16)?
    /// Drops chunks older than this once `outputBacklogCap` is reached so a
    /// long-lived session doesn't grow memory unboundedly.
    private let outputBacklogCap = 256
    private var lastObservedSequence: UInt64 = 0

    // MARK: - Session lifecycle

    func activate(sessionID: UUID, send: @escaping (DataChannelEnvelope) throws -> Void) {
        pendingInputRetryTask?.cancel()
        pendingInputRetryTask = nil
        self.sessionID = sessionID
        self.sendEnvelope = send
        self.state = .idle
        self.output.removeAll()
        self.lastObservedSequence = 0
        self.terminalID = nil
        self.startupCommand = nil
        self.workspaceID = nil
        self.workingDirectory = nil
        self.launchExecutable = nil
        self.launchArguments = []
        self.pendingInput.removeAll(keepingCapacity: true)
        self.lastRequestedResize = nil
        self.currentTerminalSize = nil
    }

    func deactivate(notifyHost: Bool = true) {
        pendingInputRetryTask?.cancel()
        pendingInputRetryTask = nil
        if notifyHost, let terminalID, let sessionID, (state == .open || state == .opening) {
            // Best-effort polite close so the host can teardown the shell.
            let message = TerminalCloseMessage(sessionID: sessionID, terminalID: terminalID, reason: "client-disconnect")
            if let envelope = try? DataChannelEnvelope.terminalClose(message) {
                try? sendEnvelope?(envelope)
            }
        }
        sessionID = nil
        terminalID = nil
        sendEnvelope = nil
        state = .idle
        output.removeAll()
        lastObservedSequence = 0
        startupCommand = nil
        workspaceID = nil
        workingDirectory = nil
        launchExecutable = nil
        launchArguments = []
        pendingInput.removeAll(keepingCapacity: true)
        lastRequestedResize = nil
        currentTerminalSize = nil
    }

    /// The transport ended without user action. Keep the terminal identity,
    /// startup context, and local output backlog so a reconnect can reattach
    /// to the same host-side PTY. Deliberately sends NO polite close — the
    /// remote shell must keep running while this client is away.
    func suspendForReattach() {
        pendingInputRetryTask?.cancel()
        pendingInputRetryTask = nil
        sessionID = nil
        sendEnvelope = nil
        state = .idle
        // terminalID, startupCommand, workspaceID, workingDirectory,
        // launchExecutable/Arguments, output backlog, and lastObservedSequence
        // are intentionally preserved for the reattach.
    }

    /// Reattaches this tab to its preserved host-side PTY after a reconnect.
    /// Re-sends TerminalOpen with the same terminal ID; the host acknowledges
    /// with TerminalReady (isReopen) and replays its bounded output tail,
    /// which this manager dedupes against `lastObservedSequence`.
    @discardableResult
    func reattach(sessionID: UUID, send: @escaping (DataChannelEnvelope) throws -> Void) -> Bool {
        guard let terminalID else { return false }
        pendingInputRetryTask?.cancel()
        pendingInputRetryTask = nil
        self.sessionID = sessionID
        self.sendEnvelope = send
        state = .opening
        return sendOpen(
            cols: currentTerminalSize?.cols ?? 80,
            rows: currentTerminalSize?.rows ?? 24,
            sessionID: sessionID,
            terminalID: terminalID,
            startupCommand: startupCommand,
            workspaceID: workspaceID,
            workingDirectory: workingDirectory,
            launchExecutable: launchExecutable,
            launchArguments: launchArguments,
            sendEnvelope: send
        )
    }

    // MARK: - Outgoing

    @discardableResult
    func open(
        cols: UInt16,
        rows: UInt16,
        startupCommand: String? = nil,
        workspaceID: UUID? = nil,
        workingDirectory: String? = nil,
        launchExecutable: String? = nil,
        launchArguments: [String] = []
    ) -> Bool {
        guard state == .idle || state.isClosed,
              let sessionID, let sendEnvelope else { return false }
        let inputEnteredBeforeOpen = state == .idle ? pendingInput : Data()
        terminalID = UUID()
        self.startupCommand = startupCommand
        self.workspaceID = workspaceID
        self.workingDirectory = workingDirectory
        self.launchExecutable = launchExecutable
        self.launchArguments = launchArguments
        state = .opening
        output.removeAll()
        lastObservedSequence = 0
        lastRequestedResize = nil
        currentTerminalSize = nil
        // Keep anything typed in the first frame of the workspace. SwiftUI
        // can render the composer before the data channel has accepted the
        // open request; dropping that input is indistinguishable from a dead
        // keyboard to the user.
        pendingInput = inputEnteredBeforeOpen
        return sendOpen(
            cols: cols,
            rows: rows,
            sessionID: sessionID,
            startupCommand: self.startupCommand,
            workspaceID: self.workspaceID,
            workingDirectory: self.workingDirectory,
            launchExecutable: self.launchExecutable,
            launchArguments: self.launchArguments,
            sendEnvelope: sendEnvelope
        )
    }

    /// Retries an opening request when the WebRTC data channel finished coming
    /// up after the workspace was first mounted. It keeps the same terminal ID.
    @discardableResult
    func retryOpen(cols: UInt16, rows: UInt16) -> Bool {
        guard state == .opening,
              let sessionID,
              let terminalID,
              let sendEnvelope else { return false }
        return sendOpen(
            cols: cols,
            rows: rows,
            sessionID: sessionID,
            terminalID: terminalID,
            startupCommand: startupCommand,
            workspaceID: workspaceID,
            workingDirectory: workingDirectory,
            launchExecutable: launchExecutable,
            launchArguments: launchArguments,
            sendEnvelope: sendEnvelope
        )
    }

    /// Stops an opening attempt that never received a host acknowledgement.
    /// The terminal ID is cleared so a later retry cannot accidentally reuse a
    /// stale request, while the startup command is retained for handoff tabs.
    func failOpening(reason: String = "terminal-start-timeout") {
        guard state == .opening else { return }
        if let sessionID, let terminalID, let sendEnvelope,
           let envelope = try? DataChannelEnvelope.terminalClose(
            TerminalCloseMessage(sessionID: sessionID, terminalID: terminalID, reason: reason)
           ) {
            try? sendEnvelope(envelope)
        }
        state = .closed(exitCode: nil, signal: nil, reason: reason)
        self.terminalID = nil
    }

    /// Starts a fresh request after a timeout without losing the command that
    /// was selected from the tmux/screen or agent launcher menu.
    @discardableResult
    func retryAfterOpeningFailure(cols: UInt16, rows: UInt16) -> Bool {
        guard case .closed(_, _, let reason) = state,
              Self.isRetryableOpeningFailure(reason) else { return false }
        return open(
            cols: cols,
            rows: rows,
            startupCommand: startupCommand,
            workspaceID: workspaceID,
            workingDirectory: workingDirectory,
            launchExecutable: launchExecutable,
            launchArguments: launchArguments
        )
    }

    @discardableResult
    private func sendOpen(
        cols: UInt16,
        rows: UInt16,
        sessionID: UUID,
        terminalID: UUID? = nil,
        startupCommand: String? = nil,
        workspaceID: UUID? = nil,
        workingDirectory: String? = nil,
        launchExecutable: String? = nil,
        launchArguments: [String] = [],
        sendEnvelope: (DataChannelEnvelope) throws -> Void
    ) -> Bool {
        let id = terminalID ?? self.terminalID ?? UUID()
        self.terminalID = id
        let message = TerminalOpenMessage(
            sessionID: sessionID,
            terminalID: id,
            cols: cols,
            rows: rows,
            startupCommand: startupCommand,
            workspaceID: workspaceID,
            workingDirectory: workingDirectory,
            launchExecutable: launchExecutable,
            launchArguments: launchArguments
        )
        guard let envelope = try? DataChannelEnvelope.terminalOpen(message) else { return false }
        do {
            try sendEnvelope(envelope)
            return true
        } catch {
            return false
        }
    }

    func sendInput(_ data: Data) {
        guard let sessionID,
              !data.isEmpty,
              data.count <= TerminalInputMessage.maxChunkBytes else { return }
        guard state == .idle || state == .open || state == .opening else { return }
        // A tab can be visible for a frame before its PTY ID is allocated, or
        // while the WebRTC data channel is still becoming writable. Keep the
        // input local and flush it after terminal-ready instead of making the
        // first command appear to vanish.
        guard let terminalID, let sendEnvelope else {
            guard pendingInput.count + data.count <= pendingInputLimit else { return }
            pendingInput.append(data)
            return
        }
        if state == .idle || state == .opening {
            guard pendingInput.count + data.count <= pendingInputLimit else { return }
            pendingInput.append(data)
            return
        }
        if !sendRawInput(data, sessionID: sessionID, terminalID: terminalID, sendEnvelope: sendEnvelope) {
            // A data channel can report open before its SCTP transport is
            // writable on a Tailscale wake/reconnect. Keep the bytes local and
            // retry briefly instead of making a tap, paste, or Return appear
            // to do nothing.
            guard pendingInput.count + data.count <= pendingInputLimit else { return }
            pendingInput.append(data)
            schedulePendingInputRetry()
        }
    }

    func requestResize(cols: UInt16, rows: UInt16) {
        guard let sessionID, let terminalID, let sendEnvelope, cols > 0, rows > 0 else { return }
        guard lastRequestedResize?.cols != cols || lastRequestedResize?.rows != rows else { return }
        let message = TerminalResizeMessage(sessionID: sessionID, terminalID: terminalID, cols: cols, rows: rows)
        if let envelope = try? DataChannelEnvelope.terminalResize(message) {
            do {
                try sendEnvelope(envelope)
                lastRequestedResize = (cols, rows)
                currentTerminalSize = (cols, rows)
            } catch {
                // Keep the old geometry so the next settled layout callback
                // retries after a temporarily unwritable data channel.
            }
        }
    }

    func close(reason: String? = "user-closed") {
        guard let sessionID, let terminalID, let sendEnvelope else { return }
        let message = TerminalCloseMessage(sessionID: sessionID, terminalID: terminalID, reason: reason)
        if let envelope = try? DataChannelEnvelope.terminalClose(message) {
            try? sendEnvelope(envelope)
        }
        state = .closed(exitCode: nil, signal: nil, reason: reason)
        self.terminalID = nil
        startupCommand = nil
        workspaceID = nil
        workingDirectory = nil
        launchExecutable = nil
        launchArguments = []
        pendingInput.removeAll(keepingCapacity: true)
        lastRequestedResize = nil
        currentTerminalSize = nil
    }

    // MARK: - Incoming (called by ClientSessionCoordinator)

    @discardableResult
    func receiveOutput(_ message: TerminalOutputMessage) -> Bool {
        guard message.sessionID == sessionID,
              message.terminalID == terminalID else { return false }
        if message.sequence <= lastObservedSequence { return false }
        lastObservedSequence = message.sequence
        if state == .opening {
            state = .open
            flushPendingInput()
        }
        output.append(message)
        if output.count > outputBacklogCap {
            output.removeFirst(output.count - outputBacklogCap)
        }
        return true
    }

    @discardableResult
    func receiveReady(_ message: TerminalReadyMessage) -> Bool {
        guard message.sessionID == sessionID,
              message.terminalID == terminalID,
              state == .opening else { return false }
        if !message.isReopen {
            // A fresh PTY restarts its output sequence at 0; drop the old
            // baseline so the new shell's output is not mistaken for stale.
            lastObservedSequence = 0
        }
        state = .open
        flushPendingInput()
        return true
    }

    @discardableResult
    func receiveClose(_ message: TerminalCloseMessage) -> Bool {
        guard message.sessionID == sessionID,
              message.terminalID == terminalID else { return false }
        let keepStartupCommand = Self.isRetryableOpeningFailure(message.reason)
        state = .closed(exitCode: message.exitCode, signal: message.signal, reason: message.reason)
        terminalID = nil
        if !keepStartupCommand {
            startupCommand = nil
            workspaceID = nil
            workingDirectory = nil
        }
        pendingInput.removeAll(keepingCapacity: true)
        return true
    }

    /// The composer remains editable while a shell is opening. Input is
    /// queued by `sendInput` and flushed after terminal-ready.
    var canEditInput: Bool {
        guard sessionID != nil else { return false }
        if case .closed = state { return false }
        return true
    }

    var canSendInput: Bool {
        canEditInput
    }

    private func flushPendingInput() {
        guard !pendingInput.isEmpty,
              let sessionID,
              let terminalID,
              let sendEnvelope else { return }
        let data = pendingInput
        pendingInput.removeAll(keepingCapacity: true)
        guard !sendRawInput(data, sessionID: sessionID, terminalID: terminalID, sendEnvelope: sendEnvelope) else { return }

        var retry = data
        retry.append(pendingInput)
        pendingInput = Data(retry.prefix(pendingInputLimit))
        schedulePendingInputRetry()
    }

    private func schedulePendingInputRetry() {
        guard pendingInputRetryTask == nil else { return }
        pendingInputRetryTask = Task { [weak self] in
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.state == .open, !self.pendingInput.isEmpty else {
                    self.pendingInputRetryTask = nil
                    return
                }
                self.flushPendingInput()
                if self.pendingInput.isEmpty {
                    self.pendingInputRetryTask = nil
                    return
                }
            }
            self?.pendingInputRetryTask = nil
        }
    }

    @discardableResult
    private func sendRawInput(
        _ data: Data,
        sessionID: UUID,
        terminalID: UUID,
        sendEnvelope: (DataChannelEnvelope) throws -> Void
    ) -> Bool {
        let message = TerminalInputMessage(sessionID: sessionID, terminalID: terminalID, data: data)
        guard let envelope = try? DataChannelEnvelope.terminalInput(message) else { return false }
        do {
            try sendEnvelope(envelope)
            return true
        } catch {
            return false
        }
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
}

private extension ClientTerminalSessionManager.State {
    var isClosed: Bool {
        if case .closed = self { return true }
        return false
    }
}
