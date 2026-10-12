import Foundation
import SharedModels

public enum VideoCodec: String, Codable, Hashable, Sendable {
    case h264
    case hevc
}

public struct NegotiatedCapabilities: Codable, Hashable, Sendable {
    public var videoCodec: VideoCodec
    public var supportsMultiDisplay: Bool
    public var supportsAudio: Bool
    public var supportsMacClient: Bool
    public var supportsHDR10: Bool
    public var supportsTerminal: Bool
    public var supportsMultipleTerminals: Bool
    public var supportsTerminalChat: Bool
    public var supportsTaskPlans: Bool
    public var supportsWorkspaces: Bool
    public var supportsAppStreaming: Bool
    public var supportsCursorlessCapture: Bool

    public init(
        videoCodec: VideoCodec,
        supportsMultiDisplay: Bool,
        supportsAudio: Bool,
        supportsMacClient: Bool,
        supportsHDR10: Bool = false,
        supportsTerminal: Bool = false,
        supportsMultipleTerminals: Bool = false,
        supportsTerminalChat: Bool = false,
        supportsTaskPlans: Bool = false,
        supportsWorkspaces: Bool = false,
        supportsAppStreaming: Bool = false,
        supportsCursorlessCapture: Bool = false
    ) {
        self.videoCodec = videoCodec
        self.supportsMultiDisplay = supportsMultiDisplay
        self.supportsAudio = supportsAudio
        self.supportsMacClient = supportsMacClient
        self.supportsHDR10 = supportsHDR10
        self.supportsTerminal = supportsTerminal
        self.supportsMultipleTerminals = supportsMultipleTerminals
        self.supportsTerminalChat = supportsTerminalChat
        self.supportsTaskPlans = supportsTaskPlans
        self.supportsWorkspaces = supportsWorkspaces
        self.supportsAppStreaming = supportsAppStreaming
        self.supportsCursorlessCapture = supportsCursorlessCapture
    }

    /// A host that shares one application window and has no display stream —
    /// Vamp Sync. It starts no capture until the client names a target, so a
    /// client that just waits for video will wait forever; it must show an
    /// application browser instead.
    public var isAppStreamingOnly: Bool {
        supportsAppStreaming && !supportsMultiDisplay && !supportsTerminal
    }

    private enum CodingKeys: String, CodingKey {
        case videoCodec
        case supportsMultiDisplay
        case supportsAudio
        case supportsMacClient
        case supportsHDR10
        case supportsTerminal
        case supportsMultipleTerminals
        case supportsTerminalChat
        case supportsTaskPlans
        case supportsWorkspaces
        case supportsAppStreaming
        case supportsCursorlessCapture
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoCodec = try container.decode(VideoCodec.self, forKey: .videoCodec)
        supportsMultiDisplay = try container.decode(Bool.self, forKey: .supportsMultiDisplay)
        supportsAudio = try container.decode(Bool.self, forKey: .supportsAudio)
        supportsMacClient = try container.decode(Bool.self, forKey: .supportsMacClient)
        supportsHDR10 = try container.decodeIfPresent(Bool.self, forKey: .supportsHDR10) ?? false
        supportsTerminal = try container.decodeIfPresent(Bool.self, forKey: .supportsTerminal) ?? false
        supportsMultipleTerminals = try container.decodeIfPresent(Bool.self, forKey: .supportsMultipleTerminals) ?? false
        supportsTerminalChat = try container.decodeIfPresent(Bool.self, forKey: .supportsTerminalChat) ?? false
        supportsTaskPlans = try container.decodeIfPresent(Bool.self, forKey: .supportsTaskPlans) ?? false
        supportsWorkspaces = try container.decodeIfPresent(Bool.self, forKey: .supportsWorkspaces) ?? false
        supportsAppStreaming = try container.decodeIfPresent(Bool.self, forKey: .supportsAppStreaming) ?? false
        supportsCursorlessCapture = try container.decodeIfPresent(Bool.self, forKey: .supportsCursorlessCapture) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(videoCodec, forKey: .videoCodec)
        try container.encode(supportsMultiDisplay, forKey: .supportsMultiDisplay)
        try container.encode(supportsAudio, forKey: .supportsAudio)
        try container.encode(supportsMacClient, forKey: .supportsMacClient)
        try container.encode(supportsHDR10, forKey: .supportsHDR10)
        try container.encode(supportsTerminal, forKey: .supportsTerminal)
        try container.encode(supportsMultipleTerminals, forKey: .supportsMultipleTerminals)
        try container.encode(supportsTerminalChat, forKey: .supportsTerminalChat)
        try container.encode(supportsTaskPlans, forKey: .supportsTaskPlans)
        try container.encode(supportsWorkspaces, forKey: .supportsWorkspaces)
        try container.encode(supportsAppStreaming, forKey: .supportsAppStreaming)
        try container.encode(supportsCursorlessCapture, forKey: .supportsCursorlessCapture)
    }
}

public enum CapabilityNegotiator {
    public static func negotiate(
        host: HostCapabilityFlags,
        client: HostCapabilityFlags
    ) -> NegotiatedCapabilities? {
        let codec: VideoCodec
        if host.contains(.supportsHEVC), client.contains(.supportsHEVC) {
            codec = .hevc
        } else if host.contains(.supportsH264), client.contains(.supportsH264) {
            codec = .h264
        } else {
            return nil
        }

        return NegotiatedCapabilities(
            videoCodec: codec,
            supportsMultiDisplay: host.contains(.supportsMultiDisplay) && client.contains(.supportsMultiDisplay),
            supportsAudio: host.contains(.supportsAudioLater) && client.contains(.supportsAudioLater),
            supportsMacClient: host.contains(.supportsMacClient) && client.contains(.supportsMacClient),
            supportsHDR10: codec == .hevc
                && host.contains(.supportsHDR10)
                && client.contains(.supportsHDR10),
            supportsTerminal: host.contains(.supportsTerminal) && client.contains(.supportsTerminal),
            supportsMultipleTerminals: host.contains(.supportsMultipleTerminals) && client.contains(.supportsMultipleTerminals),
            supportsTerminalChat: host.contains(.supportsTerminalChat) && client.contains(.supportsTerminalChat),
            supportsTaskPlans: host.contains(.supportsTaskPlans) && client.contains(.supportsTaskPlans),
            supportsWorkspaces: host.contains(.supportsWorkspaces) && client.contains(.supportsWorkspaces),
            supportsAppStreaming: host.contains(.supportsAppStreaming) && client.contains(.supportsAppStreaming),
            supportsCursorlessCapture: host.contains(.supportsCursorlessCapture)
                && client.contains(.supportsCursorlessCapture)
        )
    }
}
