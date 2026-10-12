import Diagnostics
import Foundation
import InputControl
import SharedModels
import SharedProtocol
import TransportWebRTC
import os

/// Listens for input commands on the WebRTC data channel and routes them
/// to the `InputInjectionServiceProtocol` after validating session state.
///
/// Validation uses the pure `InputCommandValidation.validateRouting` function,
/// keeping policy logic isolated and testable.
final class HostInputCommandRouter: @unchecked Sendable {
    private let inputService: any InputInjectionServiceProtocol
    private let webRTCSessionManager: any WebRTCSessionManaging
    private let eventLogStore: any EventLogStoreProtocol
    private let modeProvider: HostSessionModeController
    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "InputRouter")

    private let lock = NSLock()
    private var _activeSessionID: UUID?
    private var _isEnabled: Bool = false
    private var _terminalOnly: Bool = false
    private var _terminalModeEnabled: Bool = true
    private var _commandsProcessed: UInt64 = 0
    private var _commandsRejected: UInt64 = 0
    private var _lastQualityAdjustAt: Date?
    private var _lastDisplaySwitchAt: Date?
    private var _lastFileTransferOfferAt: Date?
    private var _lastClipboardRequestAt: Date?
    private var _expectedSessionTokenHex: String?
    private var _controlChannelAuthenticated: Bool = false
    private var _lastAcceptedAuthCounter: UInt64 = 0
    private var _unlockAttempts: Int = 0
    private var _lastUnlockAttemptAt: Date?
    private var listenTask: Task<Void, Never>?
    private var authTimeoutTask: Task<Void, Never>?
    #if DEBUG
    var traceHandler: (@Sendable (String) -> Void)?
    #endif
    /// Returns the current host lock state (thread-safe).
    /// Defaults to `.unlockedActiveSession`; set by the coordinator when
    /// `LockStateMonitor` is wired up.
    var lockStateProvider: @Sendable () -> HostLockState = { .unlockedActiveSession }

    /// Host-side feature gate (set from Settings). Default enabled to preserve
    /// existing behavior. When off, remote login-screen unlock is refused even for
    /// an authenticated, trusted client. (Terminal Mode has its own gate in the
    /// environment's terminal-open handler.)
    var remoteUnlockEnabled: @Sendable () -> Bool = { false }

    /// Called when the client requests a mid-session quality preset change.
    /// The coordinator sets this closure to apply the new preset to the pipeline.
    var onQualityAdjust: (@Sendable (StreamQualityPreset) -> Void)?
    var onSetActiveDisplays: (@Sendable (SetActiveDisplaysMessage) async -> Void)?
    var onFileTransferMessage: (@Sendable (FileTransferMessage) async -> Void)?
    var onDisplaySwitchRequest: (@Sendable (DisplaySwitchRequestMessage) async -> Void)?
    /// App Streaming: client asks for the Mac's application registry.
    var onApplicationListRequest: (@Sendable (ApplicationListRequestMessage) async -> Void)?
    /// App Streaming: client asks to retarget the live stream to a window/application.
    var onStreamTargetSwitchRequest: (@Sendable (StreamTargetSwitchRequestMessage) async -> Void)?
    /// App Streaming: client asks the Mac to quit a running application.
    var onApplicationCloseRequest: (@Sendable (ApplicationCloseRequestMessage) async -> Void)?
    /// Called when the client requests a fresh keyframe because its decoder is stuck.
    /// The coordinator wires this to `encoderPipeline.forceKeyframe()`.
    var onKeyframeRequest: (@Sendable () -> Void)?
    /// Called when the client sends a password to unlock the Mac at the login screen.
    /// The coordinator injects it via HID event tap + Return key press.
    var onUnlockPassword: (@Sendable (String) async -> Void)?
    /// Called when the client pushes its clipboard text to the host.
    var onClipboardSync: (@Sendable (String) -> Void)?
    /// Called when the client requests the host push its current clipboard.
    var onClipboardRequest: (@Sendable () -> Void)?
    /// Terminal Mode hooks — the environment wires these to `HostTerminalService`.
    var onTerminalOpen: (@Sendable (TerminalOpenMessage) -> Void)?
    var onTerminalInput: (@Sendable (TerminalInputMessage) -> Void)?
    var onTerminalResize: (@Sendable (TerminalResizeMessage) -> Void)?
    var onTerminalClose: (@Sendable (TerminalCloseMessage) -> Void)?
    var onAgentPrompt: (@Sendable (AgentPromptMessage) -> Void)?
    /// Resumable-session sync (step D): replay journaled semantic events
    /// after the requested sequence and push the current snapshot.
    var onSessionSyncRequest: (@Sendable (SessionSyncRequestMessage) -> Void)?
    /// Workspace discovery is host-local; these callbacks are only reached
    /// after the same authenticated session/timestamp validation as terminal
    /// input, so an unauthenticated peer cannot browse the filesystem.
    var onWorkspaceListRequest: (@Sendable (WorkspaceListRequestMessage) -> Void)?
    var onWorkspaceDirectoryRequest: (@Sendable (WorkspaceDirectoryRequestMessage) -> Void)?
    var onWorkspaceAccessRequest: (@Sendable (WorkspaceAccessRequestMessage) -> Void)?
    /// Called from `stopListening` so per-session services (terminal, etc.) can clean up.
    var onSessionStarted: (@Sendable (UUID) -> Void)?
    /// Fired when listening stops because the transport session ended, with
    /// the session ID that was active. Terminals are deliberately NOT torn
    /// down here — the terminal service detaches them so a reconnect can
    /// reattach. Explicit teardown (per-tab close, Terminal Mode disabled,
    /// host quit) reaches the service through its dedicated API instead.
    var onSessionTransportEnded: (@Sendable (UUID) -> Void)?

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func incrementProcessedCount() {
        lock.lock()
        _commandsProcessed += 1
        lock.unlock()
    }

    private func incrementRejectedCount() {
        lock.lock()
        _commandsRejected += 1
        lock.unlock()
    }

    private func shouldAllowQualityAdjust(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = _lastQualityAdjustAt, now.timeIntervalSince(last) < 10 {
            return false
        }
        _lastQualityAdjustAt = now
        return true
    }

    private func shouldAllowDisplaySwitch(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = _lastDisplaySwitchAt, now.timeIntervalSince(last) < 2 {
            return false
        }
        _lastDisplaySwitchAt = now
        return true
    }

    private func shouldAllowFileTransferOffer(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = _lastFileTransferOfferAt, now.timeIntervalSince(last) < 2 {
            return false
        }
        _lastFileTransferOfferAt = now
        return true
    }

    /// Clipboard reads are cheap but reveal host data. Keep the explicit
    /// request path bounded so a compromised client cannot poll the pasteboard
    /// continuously after pairing.
    private func shouldAllowClipboardRequest(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = _lastClipboardRequestAt, now.timeIntervalSince(last) < 1 {
            return false
        }
        _lastClipboardRequestAt = now
        return true
    }

    init(
        inputService: any InputInjectionServiceProtocol,
        webRTCSessionManager: any WebRTCSessionManaging,
        eventLogStore: any EventLogStoreProtocol,
        modeProvider: HostSessionModeController
    ) {
        self.inputService = inputService
        self.webRTCSessionManager = webRTCSessionManager
        self.eventLogStore = eventLogStore
        self.modeProvider = modeProvider
    }

    // MARK: - Observable State

    var activeSessionID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return _activeSessionID
    }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isEnabled
    }

    var commandsProcessed: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _commandsProcessed
    }

    var commandsRejected: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _commandsRejected
    }

    /// Terminal Mode is kept in the router because terminal-open packets are
    /// handled off the main actor. This avoids making PTY creation depend on
    /// SwiftUI/main-actor scheduling while still preserving the full-host
    /// feature gate.
    var terminalModeEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _terminalModeEnabled
    }

    func setTerminalModeEnabled(_ enabled: Bool) {
        lock.lock()
        _terminalModeEnabled = enabled
        lock.unlock()
    }

    // MARK: - Start / Stop

    func startListening(
        sessionID: UUID,
        expectedSessionTokenHex: String?,
        terminalOnly: Bool = false
    ) {
        lock.lock()
        _activeSessionID = sessionID
        _isEnabled = true
        _terminalOnly = terminalOnly
        _commandsProcessed = 0
        _commandsRejected = 0
        _lastQualityAdjustAt = nil
        _lastDisplaySwitchAt = nil
        _lastFileTransferOfferAt = nil
        _lastClipboardRequestAt = nil
        _expectedSessionTokenHex = expectedSessionTokenHex
        _controlChannelAuthenticated = false
        _lastAcceptedAuthCounter = 0
        _unlockAttempts = 0
        _lastUnlockAttemptAt = nil
        lock.unlock()

        authTimeoutTask?.cancel()
        authTimeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            let authenticated = self.withLock { self._controlChannelAuthenticated }
            guard !authenticated else { return }
            self.logger.warning("Control channel not authenticated 30 s after session start")
            Task {
                await self.eventLogStore.append(EventLogItem(
                    severity: .warning,
                    category: "Trust",
                    message: "Control channel not authenticated 30 s after session start — possible protocol mismatch or unauthenticated client"
                ))
            }
        }

        listenTask?.cancel()
        // Register the broadcast subscriber synchronously so an early, one-shot
        // controlAuth packet cannot arrive before the receive task is scheduled.
        let messageStream = webRTCSessionManager.receiveDataMessages()
        listenTask = Task { [weak self] in
            guard let self else { return }
            #if DEBUG
            self.traceHandler?("router.task.started")
            #endif
            for await envelope in messageStream {
                guard !Task.isCancelled else { break }
                if self.withLock({ self._terminalOnly }), !self.isAllowedInTerminalOnly(envelope.kind) {
                    self.rejectCommand(reason: "Command unavailable on terminal-only host")
                    continue
                }
                switch envelope.kind {
                case .inputCommand:
                    #if DEBUG
                    self.traceHandler?("router.envelope.received")
                    #endif
                    await self.handleInputEnvelope(envelope)
                case .ping:
                    await self.handlePingEnvelope(envelope)
                case .chatMessage:
                    await self.handleChatEnvelope(envelope)
                case .qualityAdjust:
                    await self.handleQualityAdjustEnvelope(envelope)
                case .fileTransfer:
                    await self.handleFileTransferEnvelope(envelope)
                case .displaySwitch:
                    await self.handleDisplaySwitchEnvelope(envelope)
                case .applicationList:
                    await self.handleApplicationListEnvelope(envelope)
                case .streamTargetSwitch:
                    await self.handleStreamTargetSwitchEnvelope(envelope)
                case .applicationClose:
                    await self.handleApplicationCloseEnvelope(envelope)
                case .setActiveDisplays:
                    await self.handleSetActiveDisplaysEnvelope(envelope)
                case .controlAuth:
                    await self.handleControlAuthEnvelope(envelope)
                case .requestKeyframe:
                    await self.handleKeyframeRequestEnvelope(envelope)
                case .unlockPassword:
                    await self.handleUnlockPasswordEnvelope(envelope)
                case .clipboardSync:
                    await self.handleClipboardSyncEnvelope(envelope)
                case .clipboardRequest:
                    await self.handleClipboardRequestEnvelope(envelope)
                case .terminalOpen:
                    await self.handleTerminalOpenEnvelope(envelope)
                case .terminalInput:
                    await self.handleTerminalInputEnvelope(envelope)
                case .terminalResize:
                    await self.handleTerminalResizeEnvelope(envelope)
                case .terminalClose:
                    await self.handleTerminalCloseEnvelope(envelope)
                case .agentPrompt:
                    await self.handleAgentPromptEnvelope(envelope)
                case .sessionSyncRequest:
                    await self.handleSessionSyncRequestEnvelope(envelope)
                case .workspaceListRequest:
                    await self.handleWorkspaceListRequestEnvelope(envelope)
                case .workspaceDirectoryRequest:
                    await self.handleWorkspaceDirectoryRequestEnvelope(envelope)
                case .workspaceAccessRequest:
                    await self.handleWorkspaceAccessRequestEnvelope(envelope)
                default:
                    continue
                }
            }
            #if DEBUG
            self.traceHandler?("router.task.stopped")
            #endif
        }

        #if DEBUG
        traceHandler?("router.startListening")
        #endif
        logger.info("Input router started for session \(sessionID.uuidString)")
        onSessionStarted?(sessionID)
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Input",
                message: "Input router started for session \(sessionID.uuidString)"
            ))
        }
    }

    func releaseHeldInput() {
        inputService.releaseHeldPointerButton()
        inputService.releaseHeldKeys()
    }

    func stopListening() {
        authTimeoutTask?.cancel()
        authTimeoutTask = nil
        let finishingTask = listenTask
        listenTask?.cancel()
        listenTask = nil
        #if DEBUG
        traceHandler?("router.stopListening")
        #endif

        lock.lock()
        let endedSessionID = _activeSessionID
        let processed = _commandsProcessed
        let rejected = _commandsRejected
        _activeSessionID = nil
        _isEnabled = false
        _terminalOnly = false
        _expectedSessionTokenHex = nil
        _controlChannelAuthenticated = false
        _lastAcceptedAuthCounter = 0
        _lastClipboardRequestAt = nil
        _unlockAttempts = 0
        _lastUnlockAttemptAt = nil
        lock.unlock()

        // Release any button still held from an in-progress drag so a lost
        // button-up can't leave the Mac stuck dragging after disconnect.
        releaseHeldInput()
        Task { [weak self] in
            await finishingTask?.value
            guard let self, self.activeSessionID == nil else { return }
            self.releaseHeldInput()
        }

        if let endedSessionID {
            onSessionTransportEnded?(endedSessionID)
        }

        logger.info("Input router stopped (processed: \(processed), rejected: \(rejected))")
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Input",
                message: "Input router stopped — \(processed) processed, \(rejected) rejected"
            ))
        }
    }

    // MARK: - Command Handling

    private func isAllowedInTerminalOnly(_ kind: DataChannelMessageKind) -> Bool {
        switch kind {
        case .controlAuth, .ping, .pong,
             .clipboardSync, .clipboardRequest,
             .terminalOpen, .terminalInput, .terminalResize, .terminalClose,
             .workspaceListRequest, .workspaceDirectoryRequest,
             .workspaceAccessRequest, .agentPrompt, .sessionSyncRequest:
            return true
        default:
            return false
        }
    }

    private func handleInputEnvelope(_ envelope: DataChannelEnvelope) async {
        // Anti-replay: drop stale or future-dated envelopes
        guard envelope.hasAcceptableTimestamp else {
            rejectCommand(reason: "Timestamp out of acceptable window")
            return
        }
        guard validateControlEnvelopeAuth(envelope) else {
            rejectCommand(reason: "Control channel authentication required")
            return
        }

        // Lock-screen guard — macOS protects password entry.  Do NOT bypass.
        let currentLockState = lockStateProvider()
        if currentLockState.blocksRemoteInput {
            rejectCommand(reason: "Mac is locked: \(currentLockState.rawValue)")
            return
        }

        // Decode the input command
        let inputMessage: InputCommandMessage
        do {
            inputMessage = try envelope.decodeInputCommand()
        } catch {
            rejectCommand(reason: "Decode failed: \(error.localizedDescription)")
            return
        }

        // Validate routing
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: inputMessage.sessionID,
            activeSessionID: activeSessionID,
            isRouterEnabled: isEnabled,
            connectionState: webRTCSessionManager.connectionState
        )
        if let rejection {
            rejectCommand(reason: "\(rejection)")
            return
        }

        if modeProvider.currentMode.blocksRemoteInput {
            rejectCommand(reason: "Remote input blocked by view-only mode")
            Task {
                await eventLogStore.append(EventLogItem(
                    severity: .info,
                    category: "SessionMode",
                    message: "Remote input blocked while host was in view-only mode"
                ))
            }
            return
        }

        // Validate command content bounds
        if let contentRejection = InputCommandValidation.validateContent(inputMessage.command) {
            rejectCommand(reason: "\(contentRejection)")
            return
        }

        // Inject
        do {
            try await inputService.inject(inputMessage.command)
            incrementProcessedCount()
            #if DEBUG
            traceHandler?("router.command.processed")
            #endif
        } catch {
            rejectCommand(reason: "Injection failed: \(error.localizedDescription)")
            logger.warning("Input injection failed: \(error.localizedDescription)")
        }
    }

    private func rejectCommand(reason: String) {
        incrementRejectedCount()
        #if DEBUG
        traceHandler?("router.command.rejected.\(reason)")
        #endif
        logger.debug("Input rejected: \(reason)")
    }

    private func handlePingEnvelope(_ envelope: DataChannelEnvelope) async {
        guard validateControlEnvelopeAuth(envelope) else { return }
        guard let message = try? envelope.decodePing() else { return }
        if let loss = message.lossPermille {
            webRTCSessionManager.recordClientLossReport(loss)
        }
        let pong = PongMessage(id: message.id, sentAt: message.sentAt)
        guard let response = try? DataChannelEnvelope.pong(pong) else { return }
        try? webRTCSessionManager.sendDataMessage(response)
    }

    private func handleChatEnvelope(_ envelope: DataChannelEnvelope) async {
        guard validateControlEnvelopeAuth(envelope) else {
            return
        }
        guard let message = try? envelope.decodeChatMessage() else { return }
        await eventLogStore.append(EventLogItem(
            severity: .info,
            category: "Chat",
            message: "Chat message received from \(message.senderDisplayName) (\(message.text.count) chars)"
        ))
    }

    private func handleAgentPromptEnvelope(_ envelope: DataChannelEnvelope) async {
        guard validateControlEnvelopeAuth(envelope),
              let activeSessionID = withLock({ _activeSessionID }),
              let message = try? envelope.decodeAgentPrompt(),
              envelope.sessionID == activeSessionID,
              message.sessionID == activeSessionID,
              !message.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.prompt.utf8.count <= AgentPromptMessage.maxPromptBytes else {
            rejectCommand(reason: "Invalid agent prompt")
            return
        }
        onAgentPrompt?(message)
    }

    private func handleSessionSyncRequestEnvelope(_ envelope: DataChannelEnvelope) async {
        guard validateControlEnvelopeAuth(envelope),
              let activeSessionID = withLock({ _activeSessionID }),
              let message = try? envelope.decodeSessionSyncRequest(),
              envelope.sessionID == activeSessionID,
              message.sessionID == activeSessionID else {
            rejectCommand(reason: "Invalid session sync request")
            return
        }
        onSessionSyncRequest?(message)
    }

    private func handleQualityAdjustEnvelope(_ envelope: DataChannelEnvelope) async {
        guard validateControlEnvelopeAuth(envelope) else {
            return
        }
        guard let message = try? envelope.decodeQualityAdjust() else { return }
        guard shouldAllowQualityAdjust() else {
            await eventLogStore.append(EventLogItem(
                severity: .warning,
                category: "Quality",
                message: "Rejected quality adjust request due to rate limit"
            ))
            return
        }
        logger.info("Quality adjust request: \(message.requestedPreset.rawValue) (reason: \(message.reason))")
        await eventLogStore.append(EventLogItem(
            severity: .info,
            category: "Quality",
            message: "Client requested quality preset: \(message.requestedPreset.rawValue) (\(message.reason))"
        ))
        onQualityAdjust?(message.requestedPreset)
    }

    private func handleSetActiveDisplaysEnvelope(_ envelope: DataChannelEnvelope) async {
        guard validateControlEnvelopeAuth(envelope) else { return }
        guard let message = try? envelope.decodeSetActiveDisplays() else { return }
        await onSetActiveDisplays?(message)
    }

    private func handleKeyframeRequestEnvelope(_ envelope: DataChannelEnvelope) async {
        guard validateControlEnvelopeAuth(envelope) else { return }
        logger.info("Client requested keyframe — forcing IDR frame")
        onKeyframeRequest?()
    }

    private func handleUnlockPasswordEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp else { return }
        guard validateControlEnvelopeAuth(envelope) else { return }

        guard remoteUnlockEnabled() else {
            logger.info("Remote unlock is disabled in host settings — ignoring")
            return
        }

        // Only accept when the Mac is actually locked
        guard lockStateProvider() == .lockedOrLoginWindow else {
            logger.debug("Ignoring unlock password — host is not locked")
            return
        }

        // Rate limit: max 5 attempts in a rolling 30-second window. A permanent
        // per-session lockout stranded legitimate users after one mistyped password
        // or a loginwindow delivery failure and required a full reconnect to recover.
        let now = Date()
        let attempt = withLock { () -> Int in
            if let lastAttempt = _lastUnlockAttemptAt,
               now.timeIntervalSince(lastAttempt) >= 30 {
                _unlockAttempts = 0
            }
            _lastUnlockAttemptAt = now
            _unlockAttempts += 1
            return _unlockAttempts
        }
        guard attempt <= 5 else {
            logger.warning("Remote unlock attempt \(attempt) exceeds 30-second limit — ignored")
            return
        }

        guard let message = try? envelope.decodeUnlockPassword(),
              message.sessionID == activeSessionID,
              !message.password.isEmpty,
              message.password.count <= 256 else {
            return
        }

        logger.info("Processing remote unlock attempt \(attempt)/5")
        guard let onUnlockPassword else {
            logger.warning("Remote unlock handler unavailable")
            return
        }
        await onUnlockPassword(message.password)
    }

    private func handleClipboardSyncEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp else { return }
        guard validateControlEnvelopeAuth(envelope) else { return }
        guard let message = try? envelope.decodeClipboardSync(),
              envelope.sessionID == message.sessionID,
              message.sessionID == activeSessionID,
              message.source == "client",
              !message.text.isEmpty else { return }
        onClipboardSync?(message.text)
    }

    private func handleClipboardRequestEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp else { return }
        guard validateControlEnvelopeAuth(envelope) else { return }
        guard let message = try? envelope.decodeClipboardRequest(),
              envelope.sessionID == message.sessionID,
              message.sessionID == activeSessionID else { return }
        guard shouldAllowClipboardRequest() else {
            rejectCommand(reason: "Clipboard request rate-limited")
            return
        }
        onClipboardRequest?()
    }

    private func handleTerminalOpenEnvelope(_ envelope: DataChannelEnvelope) async {
        logger.notice("Received terminal open envelope")
        guard envelope.hasAcceptableTimestamp else {
            rejectCommand(reason: "Terminal open timestamp out of acceptable window")
            return
        }
        guard validateControlEnvelopeAuth(envelope) else {
            logger.error("Rejected terminal open envelope: authentication failed")
            rejectCommand(reason: "Terminal open authentication required")
            return
        }
        guard let message = try? envelope.decodeTerminalOpen() else {
            rejectCommand(reason: "Terminal open decode failed")
            return
        }
        guard envelope.sessionID == message.sessionID else {
            rejectCommand(reason: "Terminal open envelope session mismatch")
            return
        }
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: message.sessionID,
            activeSessionID: activeSessionID,
            isRouterEnabled: isEnabled,
            connectionState: webRTCSessionManager.connectionState
        )
        if let rejection {
            rejectCommand(reason: "Terminal open rejected: \(rejection)")
            return
        }

        guard terminalModeEnabled else {
            logger.info("Rejecting terminal open because Terminal Mode is disabled")
            rejectCommand(reason: "Terminal Mode is disabled")
            let close = TerminalCloseMessage(
                sessionID: message.sessionID,
                terminalID: message.terminalID,
                reason: "terminal-disabled"
            )
            if let response = try? DataChannelEnvelope.terminalClose(close) {
                try? webRTCSessionManager.sendDataMessage(response)
            }
            return
        }

        logger.notice("Routing terminal open to PTY service")
        onTerminalOpen?(message)
    }

    private func handleTerminalInputEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp else { return }
        guard validateControlEnvelopeAuth(envelope) else { return }
        guard let message = try? envelope.decodeTerminalInput() else { return }
        guard envelope.sessionID == message.sessionID else { return }
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: message.sessionID,
            activeSessionID: activeSessionID,
            isRouterEnabled: isEnabled,
            connectionState: webRTCSessionManager.connectionState
        )
        if let rejection {
            rejectCommand(reason: "Terminal input rejected: \(rejection)")
            return
        }
        guard !message.data.isEmpty,
              message.data.count <= TerminalInputMessage.maxChunkBytes else { return }
        onTerminalInput?(message)
    }

    private func handleTerminalResizeEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp else { return }
        guard validateControlEnvelopeAuth(envelope) else { return }
        guard let message = try? envelope.decodeTerminalResize() else { return }
        guard envelope.sessionID == message.sessionID else { return }
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: message.sessionID,
            activeSessionID: activeSessionID,
            isRouterEnabled: isEnabled,
            connectionState: webRTCSessionManager.connectionState
        )
        if let rejection {
            rejectCommand(reason: "Terminal resize rejected: \(rejection)")
            return
        }
        onTerminalResize?(message)
    }

    private func handleTerminalCloseEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp else { return }
        guard validateControlEnvelopeAuth(envelope) else { return }
        guard let message = try? envelope.decodeTerminalClose() else { return }
        guard envelope.sessionID == message.sessionID else { return }
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: message.sessionID,
            activeSessionID: activeSessionID,
            isRouterEnabled: isEnabled,
            connectionState: webRTCSessionManager.connectionState
        )
        if let rejection {
            rejectCommand(reason: "Terminal close rejected: \(rejection)")
            return
        }
        onTerminalClose?(message)
    }

    private func handleWorkspaceListRequestEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp,
              validateControlEnvelopeAuth(envelope),
              let message = try? envelope.decodeWorkspaceListRequest(),
              envelope.sessionID == message.sessionID else { return }
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: message.sessionID,
            activeSessionID: activeSessionID,
            isRouterEnabled: isEnabled,
            connectionState: webRTCSessionManager.connectionState
        )
        guard rejection == nil else { return }
        onWorkspaceListRequest?(message)
    }

    private func handleWorkspaceDirectoryRequestEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp else {
            rejectCommand(reason: "Workspace directory request timestamp rejected")
            return
        }
        guard validateControlEnvelopeAuth(envelope) else {
            rejectCommand(reason: "Workspace directory request authentication rejected")
            return
        }
        guard let message = try? envelope.decodeWorkspaceDirectoryRequest(),
              envelope.sessionID == message.sessionID else {
            rejectCommand(reason: "Workspace directory request payload rejected")
            return
        }
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: message.sessionID,
            activeSessionID: activeSessionID,
            isRouterEnabled: isEnabled,
            connectionState: webRTCSessionManager.connectionState
        )
        guard rejection == nil else {
            rejectCommand(reason: "Workspace directory request routing rejected: \(String(describing: rejection))")
            return
        }
        logger.notice("Workspace directory request accepted")
        onWorkspaceDirectoryRequest?(message)
    }

    private func handleWorkspaceAccessRequestEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp,
              validateControlEnvelopeAuth(envelope),
              let message = try? envelope.decodeWorkspaceAccessRequest(),
              envelope.sessionID == message.sessionID else { return }
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: message.sessionID,
            activeSessionID: activeSessionID,
            isRouterEnabled: isEnabled,
            connectionState: webRTCSessionManager.connectionState
        )
        guard rejection == nil else { return }
        onWorkspaceAccessRequest?(message)
    }

    private func handleFileTransferEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp else {
            rejectCommand(reason: "File transfer timestamp out of acceptable window")
            return
        }
        guard validateControlEnvelopeAuth(envelope) else {
            rejectCommand(reason: "File transfer authentication required")
            return
        }
        guard let message = try? envelope.decodeFileTransfer() else {
            rejectCommand(reason: "File transfer decode failed")
            return
        }

        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: fileTransferSessionID(for: message),
            activeSessionID: activeSessionID,
            isRouterEnabled: isEnabled,
            connectionState: webRTCSessionManager.connectionState
        )
        if let rejection {
            rejectCommand(reason: "File transfer rejected: \(rejection)")
            return
        }

        if case .offer = message, !shouldAllowFileTransferOffer() {
            rejectCommand(reason: "File transfer offer rate-limited")
            return
        }

        guard let onFileTransferMessage else {
            rejectCommand(reason: "File transfer handler unavailable")
            return
        }

        await onFileTransferMessage(message)
    }

    private func handleDisplaySwitchEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp else {
            rejectCommand(reason: "Display switch timestamp out of acceptable window")
            return
        }
        guard validateControlEnvelopeAuth(envelope) else {
            rejectCommand(reason: "Display switch authentication required")
            return
        }
        // Lock-screen guard — don't let a locked Mac be remotely reconfigured (matches handleInputEnvelope).
        let currentLockState = lockStateProvider()
        if currentLockState.blocksRemoteInput {
            rejectCommand(reason: "Mac is locked: \(currentLockState.rawValue)")
            return
        }
        guard let message = try? envelope.decodeDisplaySwitchRequest() else {
            rejectCommand(reason: "Display switch decode failed")
            return
        }

        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: message.sessionID,
            activeSessionID: activeSessionID,
            isRouterEnabled: isEnabled,
            connectionState: webRTCSessionManager.connectionState
        )
        if let rejection {
            rejectCommand(reason: "Display switch rejected: \(rejection)")
            return
        }

        guard shouldAllowDisplaySwitch() else {
            rejectCommand(reason: "Display switch rate-limited")
            return
        }
        guard let onDisplaySwitchRequest else {
            rejectCommand(reason: "Display switch handler unavailable")
            return
        }

        await onDisplaySwitchRequest(message)
    }

    private func handleApplicationListEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp else {
            rejectCommand(reason: "Application list timestamp out of acceptable window")
            return
        }
        guard validateControlEnvelopeAuth(envelope) else {
            rejectCommand(reason: "Application list authentication required")
            return
        }
        // Don't reveal the app inventory while the Mac is locked (matches display-switch policy).
        let currentLockState = lockStateProvider()
        if currentLockState.blocksRemoteInput {
            rejectCommand(reason: "Mac is locked: \(currentLockState.rawValue)")
            return
        }
        guard let message = try? envelope.decodeApplicationListRequest() else {
            rejectCommand(reason: "Application list decode failed")
            return
        }
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: message.sessionID,
            activeSessionID: activeSessionID,
            isRouterEnabled: isEnabled,
            connectionState: webRTCSessionManager.connectionState
        )
        if let rejection {
            rejectCommand(reason: "Application list rejected: \(rejection)")
            return
        }
        guard let onApplicationListRequest else {
            rejectCommand(reason: "Application list handler unavailable")
            return
        }
        await onApplicationListRequest(message)
    }

    private func handleStreamTargetSwitchEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp else {
            rejectCommand(reason: "Stream target switch timestamp out of acceptable window")
            return
        }
        guard validateControlEnvelopeAuth(envelope) else {
            rejectCommand(reason: "Stream target switch authentication required")
            return
        }
        // Launching/activating apps + retargeting capture must not run on a locked Mac.
        let currentLockState = lockStateProvider()
        if currentLockState.blocksRemoteInput {
            rejectCommand(reason: "Mac is locked: \(currentLockState.rawValue)")
            return
        }
        guard let message = try? envelope.decodeStreamTargetSwitchRequest() else {
            rejectCommand(reason: "Stream target switch decode failed")
            return
        }
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: message.sessionID,
            activeSessionID: activeSessionID,
            isRouterEnabled: isEnabled,
            connectionState: webRTCSessionManager.connectionState
        )
        if let rejection {
            rejectCommand(reason: "Stream target switch rejected: \(rejection)")
            return
        }
        // Reuse the display-switch rate limiter: both are "retarget the live stream" operations.
        guard shouldAllowDisplaySwitch() else {
            rejectCommand(reason: "Stream target switch rate-limited")
            return
        }
        guard let onStreamTargetSwitchRequest else {
            rejectCommand(reason: "Stream target switch handler unavailable")
            return
        }
        await onStreamTargetSwitchRequest(message)
    }

    private func handleApplicationCloseEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp else {
            rejectCommand(reason: "Application close timestamp out of acceptable window")
            return
        }
        guard validateControlEnvelopeAuth(envelope) else {
            rejectCommand(reason: "Application close authentication required")
            return
        }
        let currentLockState = lockStateProvider()
        if currentLockState.blocksRemoteInput {
            rejectCommand(reason: "Mac is locked: \(currentLockState.rawValue)")
            return
        }
        guard let message = try? envelope.decodeApplicationCloseRequest() else {
            rejectCommand(reason: "Application close decode failed")
            return
        }
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: message.sessionID,
            activeSessionID: activeSessionID,
            isRouterEnabled: isEnabled,
            connectionState: webRTCSessionManager.connectionState
        )
        if let rejection {
            rejectCommand(reason: "Application close rejected: \(rejection)")
            return
        }
        guard shouldAllowDisplaySwitch() else {
            rejectCommand(reason: "Application close rate-limited")
            return
        }
        guard let onApplicationCloseRequest else {
            rejectCommand(reason: "Application close handler unavailable")
            return
        }
        await onApplicationCloseRequest(message)
    }

    private func handleControlAuthEnvelope(_ envelope: DataChannelEnvelope) async {
        guard envelope.hasAcceptableTimestamp,
              let message = try? envelope.decodeControlAuth() else {
            return
        }

        let state = withLock { (_activeSessionID, _expectedSessionTokenHex) }

        // Compare the session token in constant time. A plain String `==` short-circuits
        // on the first mismatching byte, leaking token-prefix info via timing. Decode both
        // hex strings to bytes and compare with a constant-time equality (lengths differing
        // is an immediate, non-leaking reject — same accept/reject outcome as before).
        guard let activeSession = state.0,
              message.sessionID == activeSession,
              let expectedToken = state.1,
              let expectedBytes = Self.bytesFromHex(expectedToken),
              let providedBytes = Self.bytesFromHex(message.sessionToken),
              Self.constantTimeEqual(expectedBytes, providedBytes) else {
            await eventLogStore.append(EventLogItem(
                severity: .warning,
                category: "Trust",
                message: "Rejected invalid control-channel auth handshake"
            ))
            return
        }

        let established = withLock { () -> Bool in
            // The handshake is deliberately one-shot. Resetting the inbound
            // counter on a repeated valid handshake would let a captured old
            // envelope become valid again after the counter window moved on.
            guard !_controlChannelAuthenticated else { return false }
            _controlChannelAuthenticated = true
            _lastAcceptedAuthCounter = 0
            return true
        }
        guard established else {
            logger.debug("Ignoring repeated control-channel auth handshake")
            return
        }

        await eventLogStore.append(EventLogItem(
            severity: .info,
            category: "Trust",
            message: "Control channel authentication established"
        ))
    }

    private func validateControlEnvelopeAuth(_ envelope: DataChannelEnvelope) -> Bool {
        // Every authenticated command must also be fresh. The monotonic counter
        // already blocks replays, but enforcing the timestamp window here keeps
        // the invariant uniform for all handlers (chat/quality/display/keyframe
        // previously skipped it) instead of relying on each call site to remember.
        guard envelope.hasAcceptableTimestamp else {
            return false
        }
        let state = withLock { (_controlChannelAuthenticated, _expectedSessionTokenHex, _lastAcceptedAuthCounter) }
        guard state.0, let expectedToken = state.1 else {
            return false
        }
        guard envelope.hasValidAuthentication(sessionTokenHex: expectedToken),
              let counter = envelope.authCounter,
              counter > state.2,
              counter - state.2 <= DataChannelEnvelope.maxCounterGap else {
            return false
        }

        let accepted = withLock { () -> Bool in
            if counter > _lastAcceptedAuthCounter {
                _lastAcceptedAuthCounter = counter
                return true
            }
            return false
        }
        return accepted
    }

    /// Decode a hex string into bytes, or nil if it isn't valid even-length hex.
    private static func bytesFromHex(_ hex: String) -> [UInt8]? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// Constant-time byte comparison (no early-out) to avoid leaking token bytes via timing.
    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in lhs.indices {
            diff |= lhs[i] ^ rhs[i]
        }
        return diff == 0
    }

    private func fileTransferSessionID(for message: FileTransferMessage) -> UUID {
        switch message {
        case .offer(let value): return value.sessionID
        case .accept(let value): return value.sessionID
        case .reject(let value): return value.sessionID
        case .chunk(let value): return value.sessionID
        case .progress(let value): return value.sessionID
        case .complete(let value): return value.sessionID
        case .cancel(let value): return value.sessionID
        case .error(let value): return value.sessionID
        }
    }
}
