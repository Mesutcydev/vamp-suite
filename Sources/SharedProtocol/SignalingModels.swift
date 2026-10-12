import Foundation
import SharedModels

public enum SignalingMessageKind: String, Codable, Hashable, Sendable {
    case offer
    case answer
    case iceCandidate
    case sessionReady
    case permissionBlocked
    case hostBusy
    case reconnecting
    case displayLayoutChanged
    case streamRestartRequired
}

public struct SignalingPeer: Codable, Hashable, Sendable {
    public var id: UUID
    public var role: RemoteDesktopRole
    public var displayName: String?
    public var publicKeyFingerprint: String?

    public init(id: UUID, role: RemoteDesktopRole, displayName: String? = nil, publicKeyFingerprint: String? = nil) {
        self.id = id
        self.role = role
        self.displayName = displayName
        self.publicKeyFingerprint = publicKeyFingerprint
    }
}

public struct SignalingEnvelope: Codable, Hashable, Sendable {
    public var id: UUID
    public var protocolVersion: Int
    public var sentAt: Date
    public var sessionID: UUID?
    public var sender: SignalingPeer
    public var recipient: SignalingPeer?
    public var event: SignalingEvent

    public init(
        id: UUID = UUID(),
        protocolVersion: Int,
        sentAt: Date = Date(),
        sessionID: UUID?,
        sender: SignalingPeer,
        recipient: SignalingPeer? = nil,
        event: SignalingEvent
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.sentAt = sentAt
        self.sessionID = sessionID
        self.sender = sender
        self.recipient = recipient
        self.event = event
    }

    public var kind: SignalingMessageKind {
        event.kind
    }
}

public struct VersionedSignalingMessage: Codable, Hashable, Sendable {
    public var minimumProtocolVersion: Int
    public var envelope: SignalingEnvelope
    public var senderPublicKey: Data?
    public var signature: Data?

    public init(
        minimumProtocolVersion: Int = 1,
        envelope: SignalingEnvelope,
        senderPublicKey: Data? = nil,
        signature: Data? = nil
    ) {
        self.minimumProtocolVersion = minimumProtocolVersion
        self.envelope = envelope
        self.senderPublicKey = senderPublicKey
        self.signature = signature
    }

    public func unsignedPayloadData() throws -> Data {
        struct UnsignedMessage: Codable {
            var minimumProtocolVersion: Int
            var envelope: SignalingEnvelope
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(UnsignedMessage(minimumProtocolVersion: minimumProtocolVersion, envelope: envelope))
    }
}

public enum SignalingEvent: Codable, Hashable, Sendable {
    case offer(SessionOfferMessage)
    case answer(SessionAnswerMessage)
    case iceCandidate(ICECandidateMessage)
    case sessionReady(SessionReadyMessage)
    case permissionBlocked(PermissionBlockedMessage)
    case hostBusy(HostBusyMessage)
    case reconnecting(ReconnectingMessage)
    case displayLayoutChanged(DisplayLayoutChangedMessage)
    case streamRestartRequired(StreamRestartRequiredMessage)

    public var kind: SignalingMessageKind {
        switch self {
        case .offer:
            return .offer
        case .answer:
            return .answer
        case .iceCandidate:
            return .iceCandidate
        case .sessionReady:
            return .sessionReady
        case .permissionBlocked:
            return .permissionBlocked
        case .hostBusy:
            return .hostBusy
        case .reconnecting:
            return .reconnecting
        case .displayLayoutChanged:
            return .displayLayoutChanged
        case .streamRestartRequired:
            return .streamRestartRequired
        }
    }
}

public struct SessionReadyMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var selectedDisplayID: String?
    public var negotiatedCapabilities: NegotiatedCapabilities
    /// Initial host lock state carried on the reliable signaling path.
    /// Older hosts omit it; clients retain their unlocked-compatible default.
    public var lockState: HostLockState?

    public init(
        sessionID: UUID,
        selectedDisplayID: String? = nil,
        negotiatedCapabilities: NegotiatedCapabilities,
        lockState: HostLockState? = nil
    ) {
        self.sessionID = sessionID
        self.selectedDisplayID = selectedDisplayID
        self.negotiatedCapabilities = negotiatedCapabilities
        self.lockState = lockState
    }
}

public struct PermissionBlockedMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var blockedPermissions: [PermissionState]
    /// Optional reason for a policy rejection. Older hosts omit it and clients
    /// retain the existing permission guidance.
    public var reason: PermissionBlockedReason?

    public init(
        sessionID: UUID,
        blockedPermissions: [PermissionState],
        reason: PermissionBlockedReason? = nil
    ) {
        self.sessionID = sessionID
        self.blockedPermissions = blockedPermissions
        self.reason = reason
    }
}

public enum PermissionBlockedReason: String, Codable, Hashable, Sendable {
    case terminalOnlyHost
}

public struct HostBusyMessage: Codable, Hashable, Sendable {
    public var hostID: UUID
    public var activeSessionID: UUID?
    public var retryAfter: TimeInterval?

    public init(hostID: UUID, activeSessionID: UUID? = nil, retryAfter: TimeInterval? = nil) {
        self.hostID = hostID
        self.activeSessionID = activeSessionID
        self.retryAfter = retryAfter
    }
}

public struct ReconnectingMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var attempt: Int
    public var reason: String?

    public init(sessionID: UUID, attempt: Int, reason: String? = nil) {
        self.sessionID = sessionID
        self.attempt = attempt
        self.reason = reason
    }
}

public struct DisplayLayoutChangedMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID?
    public var layout: DisplayLayout

    public init(sessionID: UUID? = nil, layout: DisplayLayout) {
        self.sessionID = sessionID
        self.layout = layout
    }
}

public struct StreamRestartRequiredMessage: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var displayID: String?
    public var reason: String

    public init(sessionID: UUID, displayID: String? = nil, reason: String) {
        self.sessionID = sessionID
        self.displayID = displayID
        self.reason = reason
    }
}
