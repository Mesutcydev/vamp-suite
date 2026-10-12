import Foundation
import SharedModels

/// Identifies the client product requesting a session. The role is optional on
/// the wire so older clients can still negotiate with a full Vamp Host, while
/// terminal-only hosts can reject an original remote-control client before
/// starting a WebRTC session.
public enum ClientProductRole: String, Codable, Hashable, Sendable {
    case remoteControl
    case terminal
}

public struct HelloMessage: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var host: HostIdentity?
    public var client: ClientIdentity?
    public var supportedCodecs: [String]

    public init(protocolVersion: Int, host: HostIdentity? = nil, client: ClientIdentity? = nil, supportedCodecs: [String]) {
        self.protocolVersion = protocolVersion
        self.host = host
        self.client = client
        self.supportedCodecs = supportedCodecs
    }
}

public struct SessionOfferMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var sdp: String
    public var requestedDisplayID: String?
    public var qualityPreset: StreamQualityPreset
    /// Session token (hex) for binding the data channel to this signaling session.
    public var sessionToken: String?
    /// ECIES-sealed session token (see `SessionTokenSealing`). Mutually exclusive
    /// with `sessionToken`: a client that knows the host's key-agreement public
    /// key seals the token so a passive observer on plaintext signaling cannot
    /// read it; the host opens it with its identity-derived key. Older hosts
    /// that predate sealing read only the plaintext `sessionToken`.
    public var sealedSessionToken: Data?
    /// Decoder-side capabilities the client advertises for this session (e.g. HEVC
    /// hardware-decode support). `nil` from older clients that predate capability
    /// advertisement; the host then falls back to its assumed-client baseline.
    public var clientCapabilities: HostCapabilityFlags?
    /// Product surface of the client. Nil is preserved for older clients and is
    /// treated as remote-control when connecting to a terminal-only host.
    public var clientProductRole: ClientProductRole?
    /// HDR is opt-in. Nil and SDR preserve the legacy 8-bit color path.
    public var preferredDynamicRange: StreamDynamicRange?

    public init(
        sessionID: UUID,
        sdp: String,
        requestedDisplayID: String? = nil,
        qualityPreset: StreamQualityPreset,
        sessionToken: String? = nil,
        sealedSessionToken: Data? = nil,
        clientCapabilities: HostCapabilityFlags? = nil,
        clientProductRole: ClientProductRole? = nil,
        preferredDynamicRange: StreamDynamicRange? = nil
    ) {
        self.sessionID = sessionID
        self.sdp = sdp
        self.requestedDisplayID = requestedDisplayID
        self.qualityPreset = qualityPreset
        self.sessionToken = sessionToken
        self.sealedSessionToken = sealedSessionToken
        self.clientCapabilities = clientCapabilities
        self.clientProductRole = clientProductRole
        self.preferredDynamicRange = preferredDynamicRange
    }
}

public struct SessionAnswerMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var sdp: String
    public var acceptedDisplayID: String?
    /// Echo of the session token from the offer, confirming data channel binding.
    public var sessionToken: String?

    public init(sessionID: UUID, sdp: String, acceptedDisplayID: String? = nil, sessionToken: String? = nil) {
        self.sessionID = sessionID
        self.sdp = sdp
        self.acceptedDisplayID = acceptedDisplayID
        self.sessionToken = sessionToken
    }
}

public struct ICECandidateMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var sdpMid: String?
    public var sdpMLineIndex: Int32
    public var candidate: String

    public init(sessionID: UUID, sdpMid: String?, sdpMLineIndex: Int32, candidate: String) {
        self.sessionID = sessionID
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.candidate = candidate
    }
}

public struct PingMessage: Codable, Hashable, Sendable {
    public var id: UUID
    public var sentAt: Date
    /// Client→host downlink video loss estimate, parts-per-thousand (0–1000). Lets the
    /// host's adaptive bitrate respond to real receiver loss, not just its own send-queue
    /// pressure. Optional so older peers (which omit it) still decode.
    public var lossPermille: Int?

    public init(id: UUID = UUID(), sentAt: Date = Date(), lossPermille: Int? = nil) {
        self.id = id
        self.sentAt = sentAt
        self.lossPermille = lossPermille
    }
}

public struct PongMessage: Codable, Hashable, Sendable {
    public var id: UUID
    public var sentAt: Date
    public var receivedAt: Date

    public init(id: UUID, sentAt: Date, receivedAt: Date = Date()) {
        self.id = id
        self.sentAt = sentAt
        self.receivedAt = receivedAt
    }
}

/// Client → host: the ordered set of host displays the client wants to view at once.
/// `displayIDs[0]` is the primary (streamed by the existing pipeline as wire displayID 0);
/// the rest are streamed in parallel as wire displayIDs 1, 2, … in list order, so the
/// client can map each received frame's displayID back to the display it requested.
public struct SetActiveDisplaysMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID?
    public var displayIDs: [String]

    public init(sessionID: UUID? = nil, displayIDs: [String]) {
        self.sessionID = sessionID
        self.displayIDs = displayIDs
    }
}

public struct DisplayLayoutMessage: Codable, Hashable, Sendable {
    public var layout: DisplayLayout

    public init(layout: DisplayLayout) {
        self.layout = layout
    }
}

public struct CursorStateMessage: Codable, Hashable, Sendable {
    public var displayID: String
    public var position: DesktopPoint
    public var isVisible: Bool

    public init(displayID: String, position: DesktopPoint, isVisible: Bool) {
        self.displayID = displayID
        self.position = position
        self.isVisible = isVisible
    }
}

public enum SessionChatSenderRole: String, Codable, Hashable, Sendable {
    case client
    case host
    case system
}

public struct SessionChatMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sessionID: UUID?
    public var senderID: UUID?
    public var senderDisplayName: String
    public var senderRole: SessionChatSenderRole
    public var text: String
    public var sentAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID? = nil,
        senderID: UUID? = nil,
        senderDisplayName: String,
        senderRole: SessionChatSenderRole,
        text: String,
        sentAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.senderID = senderID
        self.senderDisplayName = senderDisplayName
        self.senderRole = senderRole
        self.text = text
        self.sentAt = sentAt
    }
}

public struct InputCommandMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var command: InputCommand

    public init(sessionID: UUID, command: InputCommand) {
        self.sessionID = sessionID
        self.command = command
    }
}

public struct PermissionStatusMessage: Codable, Hashable, Sendable {
    public var permissions: [PermissionState]

    public init(permissions: [PermissionState]) {
        self.permissions = permissions
    }
}

public struct HostStatusMessage: Codable, Hashable, Sendable {
    public var hostID: UUID
    public var connectionState: ConnectionState
    public var activeSessionID: UUID?
    public var displayLayout: DisplayLayout?
    public var selectedDisplayID: String?
    public var sessionMode: SessionControlMode?
    public var quality: NetworkQuality?
    public var thermalState: AppThermalState?
    public var lowPowerModeEnabled: Bool?
    /// Current lock / secure-input state of the host Mac.
    /// Nil means unknown (older host); treat as `.unlockedActiveSession`.
    public var lockState: HostLockState?

    public init(
        hostID: UUID,
        connectionState: ConnectionState,
        activeSessionID: UUID? = nil,
        displayLayout: DisplayLayout? = nil,
        selectedDisplayID: String? = nil,
        sessionMode: SessionControlMode? = nil,
        quality: NetworkQuality? = nil,
        thermalState: AppThermalState? = nil,
        lowPowerModeEnabled: Bool? = nil,
        lockState: HostLockState? = nil
    ) {
        self.hostID = hostID
        self.connectionState = connectionState
        self.activeSessionID = activeSessionID
        self.displayLayout = displayLayout
        self.selectedDisplayID = selectedDisplayID
        self.sessionMode = sessionMode
        self.quality = quality
        self.thermalState = thermalState
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.lockState = lockState
    }
}

public struct ErrorMessage: Codable, Hashable, Sendable {
    public var code: String
    public var message: String
    public var isRecoverable: Bool

    public init(code: String, message: String, isRecoverable: Bool) {
        self.code = code
        self.message = message
        self.isRecoverable = isRecoverable
    }
}

/// Sent by the client over the data channel to request a mid-session quality
/// preset change (e.g., adaptive downgrade on high RTT / packet loss).
public struct QualityAdjustMessage: Codable, Hashable, Sendable {
    public var requestedPreset: StreamQualityPreset
    public var reason: String

    public init(requestedPreset: StreamQualityPreset, reason: String) {
        self.requestedPreset = requestedPreset
        self.reason = reason
    }
}

/// First control-channel message sent by the client after signaling completes.
/// The host verifies this token before accepting any command envelopes.
public struct ControlChannelAuthMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var sessionToken: String

    public init(sessionID: UUID, sessionToken: String) {
        self.sessionID = sessionID
        self.sessionToken = sessionToken
    }
}

/// Sent by the client when the host Mac is at the lock/login screen.
/// The host injects the password via HID event tap (reaches the login window)
/// then presses Return to complete authentication.
/// Transmitted over the existing authenticated + encrypted WebRTC data channel.
public struct UnlockPasswordMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var password: String

    public init(sessionID: UUID, password: String) {
        self.sessionID = sessionID
        self.password = password
    }
}
