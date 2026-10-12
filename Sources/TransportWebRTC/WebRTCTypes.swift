import Foundation

// MARK: - Peer Connection State

public enum PeerConnectionState: String, Codable, Hashable, Sendable {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

// MARK: - ICE Connection State

public enum ICEConnectionState: String, Codable, Hashable, Sendable {
    case new
    case checking
    case connected
    case completed
    case failed
    case disconnected
    case closed
}

// MARK: - ICE Gathering State

public enum ICEGatheringState: String, Codable, Hashable, Sendable {
    case new
    case gathering
    case complete
}

// MARK: - Data Channel State

public enum DataChannelState: String, Codable, Hashable, Sendable {
    case connecting
    case open
    case closing
    case closed
}

// MARK: - Session Description

public struct SessionDescription: Codable, Hashable, Sendable {
    public enum SDPType: String, Codable, Hashable, Sendable {
        case offer
        case answer
        case pranswer
        case rollback
    }

    public var type: SDPType
    public var sdp: String

    public init(type: SDPType, sdp: String) {
        self.type = type
        self.sdp = sdp
    }
}

// MARK: - ICE Candidate (App-Owned)

public struct ICECandidate: Codable, Hashable, Sendable {
    public var sdpMid: String?
    public var sdpMLineIndex: Int32
    public var candidate: String

    public init(sdpMid: String?, sdpMLineIndex: Int32, candidate: String) {
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.candidate = candidate
    }
}

// MARK: - WebRTC Configuration

public struct WebRTCConfiguration: Sendable {
    public var iceServers: [ICEServer]

    public init(iceServers: [ICEServer] = []) {
        self.iceServers = iceServers
    }

    public struct ICEServer: Sendable {
        public var urls: [String]
        public var username: String?
        public var credential: String?

        public init(urls: [String], username: String? = nil, credential: String? = nil) {
            self.urls = urls
            self.username = username
            self.credential = credential
        }
    }

    /// LAN-only configuration (no STUN/TURN servers needed).
    public static var lanDefault: WebRTCConfiguration {
        WebRTCConfiguration()
    }
}

// MARK: - Data Channel Configuration

public struct DataChannelConfiguration: Sendable {
    public var label: String
    public var isOrdered: Bool
    public var maxRetransmits: Int?
    public var maxPacketLifeTime: Int?

    public init(
        label: String,
        isOrdered: Bool = true,
        maxRetransmits: Int? = nil,
        maxPacketLifeTime: Int? = nil
    ) {
        self.label = label
        self.isOrdered = isOrdered
        self.maxRetransmits = maxRetransmits
        self.maxPacketLifeTime = maxPacketLifeTime
    }

    /// Reliable, ordered control channel for input commands, ping/pong, status.
    public static var controlChannel: DataChannelConfiguration {
        DataChannelConfiguration(label: "control", isOrdered: true)
    }

    /// Unreliable, unordered video data channel for low-latency frame delivery.
    public static var videoChannel: DataChannelConfiguration {
        DataChannelConfiguration(label: "video", isOrdered: false, maxRetransmits: 0)
    }
}

// MARK: - Media Constraints

public struct MediaConstraints: Sendable {
    public var mandatory: [String: String]
    public var optional: [String: String]

    public init(mandatory: [String: String] = [:], optional: [String: String] = [:]) {
        self.mandatory = mandatory
        self.optional = optional
    }

    public static var defaultOffer: MediaConstraints {
        MediaConstraints(mandatory: ["OfferToReceiveVideo": "false", "OfferToReceiveAudio": "false"])
    }

    public static var defaultAnswer: MediaConstraints {
        MediaConstraints(mandatory: ["OfferToReceiveVideo": "true", "OfferToReceiveAudio": "false"])
    }
}
