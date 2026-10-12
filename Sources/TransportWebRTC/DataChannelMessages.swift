import Foundation
import CryptoKit
import SharedModels
import SharedProtocol

// MARK: - Data Channel Message Kind

public enum DataChannelMessageKind: String, Codable, Hashable, Sendable {
    case controlAuth
    case inputCommand
    case ping
    case pong
    case hostStatus
    case displayLayout
    case displayConfigurationChanged
    case displaySwitch
    case cursorState
    case chatMessage
    case fileTransfer
    case error
    /// Sent by the client to request a quality preset change mid-session.
    case qualityAdjust
    /// Client → host: the ordered set of displays to stream simultaneously (multi-monitor).
    case setActiveDisplays
    /// Sent by the client when the decoder is stuck (bytes arriving but no keyframe
    /// received).  The host responds by immediately forcing an IDR frame.
    case requestKeyframe
    /// Sent by the client to unlock the Mac when it is at the lock/login screen.
    /// The host injects the password via HID event tap, then presses Return.
    case unlockPassword
    /// Audio frame sent from the Mac host to the Mac client.
    /// Payload is an AudioFrameMessage with AAC-LC compressed audio.
    case audioFrame
    /// Pushes clipboard plaintext between host and client (bidirectional).
    case clipboardSync
    /// Sent by client to request the host push its current clipboard.
    case clipboardRequest
    /// Client → host: open a new PTY-backed shell.
    case terminalOpen
    /// Host → client: the PTY was created and is ready for input.
    case terminalReady
    /// Client → host: stdin bytes for an open terminal.
    case terminalInput
    /// Host → client: stdout/stderr bytes from an open terminal.
    case terminalOutput
    /// Client → host: PTY window size change (cols/rows).
    case terminalResize
    /// Either side: tear-down notice for a terminal (host includes exit code).
    case terminalClose
    /// Client → host: request the host's cached developer workspaces.
    case workspaceListRequest
    /// Host → client: discovered workspaces and safe browse roots.
    case workspaceListResponse
    /// Client → host: list child directories under a validated browse path.
    case workspaceDirectoryRequest
    /// Host → client: directory entries for a validated browse path.
    case workspaceDirectoryResponse
    /// Client → host: ask the Mac owner to expose another folder.
    case workspaceAccessRequest
    /// Host → client: result of the native Mac folder chooser.
    case workspaceAccessResponse
    /// Host → client: a semantic agent task-plan mutation. This is kept
    /// separate from terminalOutput so VT repaint bytes cannot become Chat
    /// tasks by accident.
    case taskPlanEvent
    /// Client → host: submit one semantic Chat prompt to a provider runner.
    case agentPrompt
    /// Host → client: provider-native semantic output for Chat/task cards.
    case providerSemanticEvent
    /// Client → host: resumable-session sync — replay journaled semantic
    /// events after the given sequence and send the current snapshot.
    case sessionSyncRequest
    /// Host → client: authoritative current session state (step D).
    case sessionSnapshot
    /// Host → client: one replayed journal event (step D).
    case sessionSyncEvent
    /// App Streaming registry: client → host request, host → client snapshot.
    case applicationList
    /// App Streaming target control: client → host switch request, host → client
    /// result (also unsolicited on window loss). Reuses the live retarget path.
    case streamTargetSwitch
    /// App Streaming quit: client → host request, host → client result.
    case applicationClose

    /// One source of truth for the control-channel authentication contract.
    /// Any kind that can inject input, change host state, read/write host data,
    /// or operate a PTY must be MACed after the session handshake.
    public var requiresControlChannelAuthentication: Bool {
        switch self {
        case .inputCommand, .chatMessage, .qualityAdjust, .fileTransfer,
             .displaySwitch, .setActiveDisplays, .requestKeyframe,
             .unlockPassword, .clipboardSync, .clipboardRequest,
             .terminalOpen, .terminalReady, .terminalInput, .terminalOutput,
             .terminalResize, .terminalClose, .workspaceListRequest,
             .workspaceListResponse, .workspaceDirectoryRequest,
             .workspaceDirectoryResponse, .workspaceAccessRequest,
             .workspaceAccessResponse, .taskPlanEvent, .agentPrompt,
             .providerSemanticEvent, .sessionSyncRequest, .sessionSnapshot,
             .sessionSyncEvent, .applicationList, .streamTargetSwitch, .applicationClose:
            return true
        default:
            return false
        }
    }
}

// MARK: - Data Channel Envelope

/// Typed envelope for all messages sent over the WebRTC data channel.
/// Each message is JSON-encoded with a kind discriminator, optional session ID, and a payload.
public struct DataChannelEnvelope: Codable, Hashable, Sendable {
    public var kind: DataChannelMessageKind
    public var sessionID: UUID?
    public var timestamp: Date
    public var payload: Data
    public var authCounter: UInt64?
    public var authNonce: Data?
    public var authTag: Data?

    public init(
        kind: DataChannelMessageKind,
        sessionID: UUID? = nil,
        timestamp: Date = Date(),
        payload: Data,
        authCounter: UInt64? = nil,
        authNonce: Data? = nil,
        authTag: Data? = nil
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.payload = payload
        self.authCounter = authCounter
        self.authNonce = authNonce
        self.authTag = authTag
    }
}

// MARK: - Encoding Helpers

extension DataChannelEnvelope {
    /// Per-call encoder — JSONEncoder is not thread-safe and must not be shared.
    private static func makeEncoder() -> JSONEncoder { JSONEncoder() }

    public static func inputCommand(_ message: InputCommandMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .inputCommand,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func controlAuth(_ message: ControlChannelAuthMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .controlAuth,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func ping(_ message: PingMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .ping,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func pong(_ message: PongMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .pong,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func hostStatus(_ message: HostStatusMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .hostStatus,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func displayLayout(_ message: DisplayLayoutMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .displayLayout,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func displayConfigurationChanged(_ message: DisplayConfigurationChangedMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .displayConfigurationChanged,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func cursorState(_ message: CursorStateMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .cursorState,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func displaySwitch(_ message: DisplaySwitchRequestMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .displaySwitch,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func displaySwitchResult(_ message: DisplaySwitchResultMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .displaySwitch,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func applicationListRequest(_ message: ApplicationListRequestMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .applicationList,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func applicationListSnapshot(_ message: ApplicationListSnapshotMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .applicationList,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func streamTargetSwitch(_ message: StreamTargetSwitchRequestMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .streamTargetSwitch,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func streamTargetSwitchResult(_ message: StreamTargetSwitchResultMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .streamTargetSwitch,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func applicationCloseRequest(_ message: ApplicationCloseRequestMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .applicationClose,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func applicationCloseResult(_ message: ApplicationCloseResultMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .applicationClose,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func chatMessage(_ message: SessionChatMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .chatMessage,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func fileTransfer(_ message: FileTransferMessage, sessionID: UUID) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .fileTransfer,
            sessionID: sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func error(_ message: ErrorMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .error,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func qualityAdjust(_ message: QualityAdjustMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .qualityAdjust,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func setActiveDisplays(_ message: SetActiveDisplaysMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .setActiveDisplays,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func requestKeyframe(sessionID: UUID) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .requestKeyframe,
            sessionID: sessionID,
            payload: try makeEncoder().encode(["sessionID": sessionID.uuidString])
        )
    }

    public static func unlockPassword(_ message: UnlockPasswordMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .unlockPassword,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func audioFrame(_ message: AudioFrameMessage, sessionID: UUID) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .audioFrame,
            sessionID: sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func clipboardSync(_ message: ClipboardSyncMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .clipboardSync,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func clipboardRequest(_ message: ClipboardRequestMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .clipboardRequest,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func terminalOpen(_ message: TerminalOpenMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .terminalOpen,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func terminalReady(_ message: TerminalReadyMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .terminalReady,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func terminalInput(_ message: TerminalInputMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .terminalInput,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func terminalOutput(_ message: TerminalOutputMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .terminalOutput,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func terminalResize(_ message: TerminalResizeMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .terminalResize,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func terminalClose(_ message: TerminalCloseMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .terminalClose,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func workspaceListRequest(_ message: WorkspaceListRequestMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .workspaceListRequest,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func workspaceListResponse(_ message: WorkspaceListResponseMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .workspaceListResponse,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func workspaceDirectoryRequest(_ message: WorkspaceDirectoryRequestMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .workspaceDirectoryRequest,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func workspaceDirectoryResponse(_ message: WorkspaceDirectoryResponseMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .workspaceDirectoryResponse,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func workspaceAccessRequest(_ message: WorkspaceAccessRequestMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .workspaceAccessRequest,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func workspaceAccessResponse(_ message: WorkspaceAccessResponseMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .workspaceAccessResponse,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func taskPlanEvent(_ message: SessionTaskEventMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .taskPlanEvent,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func agentPrompt(_ message: AgentPromptMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .agentPrompt,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func providerSemanticEvent(_ message: ProviderSemanticEventMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .providerSemanticEvent,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func sessionSyncRequest(_ message: SessionSyncRequestMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .sessionSyncRequest,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func sessionSnapshot(_ message: SessionSnapshotMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .sessionSnapshot,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }

    public static func sessionSyncEvent(_ message: SessionSyncEventMessage) throws -> DataChannelEnvelope {
        DataChannelEnvelope(
            kind: .sessionSyncEvent,
            sessionID: message.sessionID,
            payload: try makeEncoder().encode(message)
        )
    }
}

// MARK: - Decoding Helpers

extension DataChannelEnvelope {
    /// Per-call decoder — JSONDecoder is not thread-safe and must not be shared.
    private static func makeDecoder() -> JSONDecoder { JSONDecoder() }

    public func decodeInputCommand() throws -> InputCommandMessage {
        try Self.makeDecoder().decode(InputCommandMessage.self, from: payload)
    }

    public func decodeControlAuth() throws -> ControlChannelAuthMessage {
        try Self.makeDecoder().decode(ControlChannelAuthMessage.self, from: payload)
    }

    public func decodePing() throws -> PingMessage {
        try Self.makeDecoder().decode(PingMessage.self, from: payload)
    }

    public func decodePong() throws -> PongMessage {
        try Self.makeDecoder().decode(PongMessage.self, from: payload)
    }

    public func decodeHostStatus() throws -> HostStatusMessage {
        try Self.makeDecoder().decode(HostStatusMessage.self, from: payload)
    }

    public func decodeDisplayLayout() throws -> DisplayLayoutMessage {
        try Self.makeDecoder().decode(DisplayLayoutMessage.self, from: payload)
    }

    public func decodeDisplayConfigurationChanged() throws -> DisplayConfigurationChangedMessage {
        try Self.makeDecoder().decode(DisplayConfigurationChangedMessage.self, from: payload)
    }

    public func decodeCursorState() throws -> CursorStateMessage {
        try Self.makeDecoder().decode(CursorStateMessage.self, from: payload)
    }

    public func decodeDisplaySwitchRequest() throws -> DisplaySwitchRequestMessage {
        try Self.makeDecoder().decode(DisplaySwitchRequestMessage.self, from: payload)
    }

    public func decodeDisplaySwitchResult() throws -> DisplaySwitchResultMessage {
        try Self.makeDecoder().decode(DisplaySwitchResultMessage.self, from: payload)
    }

    public func decodeApplicationListRequest() throws -> ApplicationListRequestMessage {
        try Self.makeDecoder().decode(ApplicationListRequestMessage.self, from: payload)
    }

    public func decodeApplicationListSnapshot() throws -> ApplicationListSnapshotMessage {
        try Self.makeDecoder().decode(ApplicationListSnapshotMessage.self, from: payload)
    }

    public func decodeStreamTargetSwitchRequest() throws -> StreamTargetSwitchRequestMessage {
        try Self.makeDecoder().decode(StreamTargetSwitchRequestMessage.self, from: payload)
    }

    public func decodeStreamTargetSwitchResult() throws -> StreamTargetSwitchResultMessage {
        try Self.makeDecoder().decode(StreamTargetSwitchResultMessage.self, from: payload)
    }

    public func decodeApplicationCloseRequest() throws -> ApplicationCloseRequestMessage {
        try Self.makeDecoder().decode(ApplicationCloseRequestMessage.self, from: payload)
    }

    public func decodeApplicationCloseResult() throws -> ApplicationCloseResultMessage {
        try Self.makeDecoder().decode(ApplicationCloseResultMessage.self, from: payload)
    }

    public func decodeChatMessage() throws -> SessionChatMessage {
        try Self.makeDecoder().decode(SessionChatMessage.self, from: payload)
    }

    public func decodeFileTransfer() throws -> FileTransferMessage {
        try Self.makeDecoder().decode(FileTransferMessage.self, from: payload)
    }

    public func decodeError() throws -> ErrorMessage {
        try Self.makeDecoder().decode(ErrorMessage.self, from: payload)
    }

    public func decodeQualityAdjust() throws -> QualityAdjustMessage {
        try Self.makeDecoder().decode(QualityAdjustMessage.self, from: payload)
    }

    public func decodeSetActiveDisplays() throws -> SetActiveDisplaysMessage {
        try Self.makeDecoder().decode(SetActiveDisplaysMessage.self, from: payload)
    }

    public func decodeUnlockPassword() throws -> UnlockPasswordMessage {
        try Self.makeDecoder().decode(UnlockPasswordMessage.self, from: payload)
    }

    public func decodeAudioFrame() throws -> AudioFrameMessage {
        try Self.makeDecoder().decode(AudioFrameMessage.self, from: payload)
    }

    public func decodeClipboardSync() throws -> ClipboardSyncMessage {
        try Self.makeDecoder().decode(ClipboardSyncMessage.self, from: payload)
    }

    public func decodeClipboardRequest() throws -> ClipboardRequestMessage {
        try Self.makeDecoder().decode(ClipboardRequestMessage.self, from: payload)
    }

    public func decodeTerminalOpen() throws -> TerminalOpenMessage {
        try Self.makeDecoder().decode(TerminalOpenMessage.self, from: payload)
    }

    public func decodeTerminalReady() throws -> TerminalReadyMessage {
        try Self.makeDecoder().decode(TerminalReadyMessage.self, from: payload)
    }

    public func decodeTerminalInput() throws -> TerminalInputMessage {
        try Self.makeDecoder().decode(TerminalInputMessage.self, from: payload)
    }

    public func decodeTerminalOutput() throws -> TerminalOutputMessage {
        try Self.makeDecoder().decode(TerminalOutputMessage.self, from: payload)
    }

    public func decodeTerminalResize() throws -> TerminalResizeMessage {
        try Self.makeDecoder().decode(TerminalResizeMessage.self, from: payload)
    }

    public func decodeTerminalClose() throws -> TerminalCloseMessage {
        try Self.makeDecoder().decode(TerminalCloseMessage.self, from: payload)
    }

    public func decodeAgentPrompt() throws -> AgentPromptMessage {
        try Self.makeDecoder().decode(AgentPromptMessage.self, from: payload)
    }

    public func decodeProviderSemanticEvent() throws -> ProviderSemanticEventMessage {
        try Self.makeDecoder().decode(ProviderSemanticEventMessage.self, from: payload)
    }

    public func decodeSessionSyncRequest() throws -> SessionSyncRequestMessage {
        try Self.makeDecoder().decode(SessionSyncRequestMessage.self, from: payload)
    }

    public func decodeSessionSnapshot() throws -> SessionSnapshotMessage {
        try Self.makeDecoder().decode(SessionSnapshotMessage.self, from: payload)
    }

    public func decodeSessionSyncEvent() throws -> SessionSyncEventMessage {
        try Self.makeDecoder().decode(SessionSyncEventMessage.self, from: payload)
    }

    public func decodeWorkspaceListRequest() throws -> WorkspaceListRequestMessage {
        try Self.makeDecoder().decode(WorkspaceListRequestMessage.self, from: payload)
    }

    public func decodeWorkspaceListResponse() throws -> WorkspaceListResponseMessage {
        try Self.makeDecoder().decode(WorkspaceListResponseMessage.self, from: payload)
    }

    public func decodeWorkspaceDirectoryRequest() throws -> WorkspaceDirectoryRequestMessage {
        try Self.makeDecoder().decode(WorkspaceDirectoryRequestMessage.self, from: payload)
    }

    public func decodeWorkspaceDirectoryResponse() throws -> WorkspaceDirectoryResponseMessage {
        try Self.makeDecoder().decode(WorkspaceDirectoryResponseMessage.self, from: payload)
    }

    public func decodeWorkspaceAccessRequest() throws -> WorkspaceAccessRequestMessage {
        try Self.makeDecoder().decode(WorkspaceAccessRequestMessage.self, from: payload)
    }

    public func decodeWorkspaceAccessResponse() throws -> WorkspaceAccessResponseMessage {
        try Self.makeDecoder().decode(WorkspaceAccessResponseMessage.self, from: payload)
    }

    public func decodeTaskPlanEvent() throws -> SessionTaskEventMessage {
        try Self.makeDecoder().decode(SessionTaskEventMessage.self, from: payload)
    }
}

// MARK: - Wire Encoding

extension DataChannelEnvelope {
    /// 1 MB hard cap. A normal input command is < 512 bytes; video frames travel the
    /// video channel, not here. Anything larger is almost certainly malformed or malicious.
    public static let maxWirePayloadBytes = 1_048_576

    /// Anti-replay window. Envelopes older than this are silently dropped.
    public static let maxTimestampAgeSeconds: TimeInterval = 30

    /// Forward-clock tolerance. Envelopes whose timestamp is this far in the future
    /// are also dropped (clock-skew guard).
    public static let maxTimestampFutureSeconds: TimeInterval = 5
    public static let maxCounterGap: UInt64 = 10_000

    /// Encode the entire envelope to JSON data for sending over the data channel.
    public func wireEncode() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Decode an envelope from JSON data received over the data channel.
    /// Throws if the payload exceeds `maxWirePayloadBytes`.
    public static func wireDecode(_ data: Data) throws -> DataChannelEnvelope {
        guard data.count <= maxWirePayloadBytes else {
            throw DataChannelEnvelopeError.oversizedPayload(actual: data.count, limit: maxWirePayloadBytes)
        }
        return try makeDecoder().decode(DataChannelEnvelope.self, from: data)
    }

    /// Returns true if the envelope timestamp is within the acceptable freshness window.
    /// Use this in command handlers to drop replayed or stale packets.
    public var hasAcceptableTimestamp: Bool {
        let age = Date().timeIntervalSince(timestamp)
        return age >= -Self.maxTimestampFutureSeconds && age <= Self.maxTimestampAgeSeconds
    }

    public func authenticated(using sessionTokenHex: String, counter: UInt64) -> DataChannelEnvelope? {
        guard let token = Self.tokenFromHex(sessionTokenHex) else { return nil }
        let key = SymmetricKey(data: token)
        var nonce = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce)
        let nonceData = Data(nonce)

        var envelope = self
        envelope.authCounter = counter
        envelope.authNonce = nonceData
        envelope.authTag = nil
        let mac = HMAC<SHA256>.authenticationCode(for: envelope.authenticatedBytes(), using: key)
        envelope.authTag = Data(mac)
        return envelope
    }

    public func hasValidAuthentication(sessionTokenHex: String) -> Bool {
        guard let counter = authCounter,
              let nonce = authNonce,
              let tag = authTag,
                            let token = Self.tokenFromHex(sessionTokenHex),
              nonce.count == 12,
              tag.count == 32,
              counter > 0 else {
            return false
        }
        let key = SymmetricKey(data: token)
        var unsigned = self
        unsigned.authTag = nil
        let expected = HMAC<SHA256>.authenticationCode(for: unsigned.authenticatedBytes(), using: key)
        return Self.constantTimeEqual(Data(expected), tag)
    }

    private func authenticatedBytes() -> Data {
        var material = Data()
        material.append(kind.rawValue.data(using: .utf8) ?? Data())
        if let sessionID {
            material.append(sessionID.uuidString.data(using: .utf8) ?? Data())
        }
        material.append(String(timestamp.timeIntervalSince1970).data(using: .utf8) ?? Data())
        material.append(payload)
        if let authCounter {
            material.append(String(authCounter).data(using: .utf8) ?? Data())
        }
        if let authNonce {
            material.append(authNonce)
        }
        return material
    }

    private static func tokenFromHex(_ hex: String) -> Data? {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count.isMultiple(of: 2) else {
            return nil
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(normalized.count / 2)

        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            let byteString = normalized[index..<next]
            guard let byte = UInt8(byteString, radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }

        return Data(bytes)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in lhs.indices {
            diff |= lhs[i] ^ rhs[i]
        }
        return diff == 0
    }
}

public enum DataChannelEnvelopeError: Error, LocalizedError {
    case oversizedPayload(actual: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .oversizedPayload(let actual, let limit):
            return "Data channel payload \(actual) bytes exceeds \(limit)-byte limit"
        }
    }
}
