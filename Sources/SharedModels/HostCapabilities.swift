import Foundation
#if canImport(VideoToolbox)
import CoreMedia
import VideoToolbox
#endif

public enum StreamDynamicRange: String, Codable, Hashable, Sendable {
    case sdr
    case hdr10
}

public struct HostCapabilityFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public static let supportsHEVC = HostCapabilityFlags(rawValue: 1 << 0)
    public static let supportsH264 = HostCapabilityFlags(rawValue: 1 << 1)
    public static let supportsMultiDisplay = HostCapabilityFlags(rawValue: 1 << 2)
    public static let supportsAudioLater = HostCapabilityFlags(rawValue: 1 << 3)
    public static let supportsMacClient = HostCapabilityFlags(rawValue: 1 << 4)
    public static let supportsVideoFragmentation = HostCapabilityFlags(rawValue: 1 << 5)
    public static let supportsHDR10 = HostCapabilityFlags(rawValue: 1 << 6)
    /// The receiver understands XOR parity packets and can reconstruct a single lost
    /// video fragment without a retransmission. Sender (host) only emits parity when
    /// the client advertises this, so older clients are unaffected.
    public static let supportsVideoFEC = HostCapabilityFlags(rawValue: 1 << 7)
    /// The client can decode Opus audio. The host only sends Opus (lower-latency than
    /// AAC) when the client advertises this AND the stream rate/channels are Opus-
    /// compatible; otherwise it stays on AAC-LC, so older clients are unaffected.
    public static let supportsOpusAudio = HostCapabilityFlags(rawValue: 1 << 8)
    /// The peer can open and use the authenticated PTY terminal feature.
    public static let supportsTerminal = HostCapabilityFlags(rawValue: 1 << 9)
    /// The peer supports multiple concurrent PTYs within one authenticated session.
    public static let supportsMultipleTerminals = HostCapabilityFlags(rawValue: 1 << 10)
    /// The peer can project canonical agent turns as semantic Chat messages.
    public static let supportsTerminalChat = HostCapabilityFlags(rawValue: 1 << 11)
    /// The peer can stream structured, per-session task-plan events.
    public static let supportsTaskPlans = HostCapabilityFlags(rawValue: 1 << 12)
    /// The peer can browse and launch sessions in host-side workspaces.
    public static let supportsWorkspaces = HostCapabilityFlags(rawValue: 1 << 13)
    /// The host can enumerate/launch macOS applications and stream a single
    /// application window (App Streaming); the client will show the app browser and
    /// send `applicationList` / `streamTargetSwitch` control messages. Older peers
    /// never negotiate it, so display streaming is unaffected.
    public static let supportsAppStreaming = HostCapabilityFlags(rawValue: 1 << 14)
    /// Both peers support omitting the host cursor from captured video so a Mac
    /// client can show its local cursor with immediate, zero-round-trip feedback.
    public static let supportsCursorlessCapture = HostCapabilityFlags(rawValue: 1 << 15)

    /// Explicit opt-in to full-desktop control on a dual-mode Sync host.
    /// Older Control and focused Stream clients keep the app-window handshake.
    public static let supportsDesktopControl = HostCapabilityFlags(rawValue: 1 << 16)

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Capabilities of the current device acting as a streaming client (decoder side).
    ///
    /// HEVC is advertised only when the hardware HEVC decoder is actually available,
    /// so the host never negotiates a codec this device can't decode in hardware.
    /// Falls back to H.264 only on platforms/devices without HEVC hardware decode.
    public static func currentClient(isMacClient: Bool) -> HostCapabilityFlags {
        var flags: HostCapabilityFlags = [
            .supportsH264,
            .supportsMultiDisplay,
            .supportsAudioLater,
            .supportsVideoFragmentation,
            .supportsVideoFEC,
            .supportsOpusAudio,
            .supportsTerminal,
            .supportsMultipleTerminals,
            .supportsTerminalChat,
            .supportsTaskPlans,
            .supportsWorkspaces,
            // Any client running this code can render a window (App Streaming) stream — it is
            // just H.264/HEVC video. The host gates whether streaming is actually offered.
            .supportsAppStreaming
        ]
        #if canImport(VideoToolbox)
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            flags.insert(.supportsHEVC)
            flags.insert(.supportsHDR10)
        }
        #endif
        if isMacClient {
            flags.insert(.supportsMacClient)
            flags.insert(.supportsDesktopControl)
            flags.insert(.supportsCursorlessCapture)
        }
        return flags
    }
}

public extension HostCapabilityFlags {
    static let baseline: HostCapabilityFlags = [.supportsH264]

    /// A host that only offers terminal tabs and has no display stream.
    var isTerminalOnlyHost: Bool {
        contains(.supportsTerminal)
            && contains(.supportsMultipleTerminals)
            && !contains(.supportsMultiDisplay)
    }

    var stableNames: [String] {
        var names: [String] = []
        if contains(.supportsHEVC) { names.append("supportsHEVC") }
        if contains(.supportsH264) { names.append("supportsH264") }
        if contains(.supportsMultiDisplay) { names.append("supportsMultiDisplay") }
        if contains(.supportsAudioLater) { names.append("supportsAudioLater") }
        if contains(.supportsMacClient) { names.append("supportsMacClient") }
        if contains(.supportsVideoFragmentation) { names.append("supportsVideoFragmentation") }
        if contains(.supportsHDR10) { names.append("supportsHDR10") }
        if contains(.supportsVideoFEC) { names.append("supportsVideoFEC") }
        if contains(.supportsOpusAudio) { names.append("supportsOpusAudio") }
        if contains(.supportsTerminal) { names.append("supportsTerminal") }
        if contains(.supportsMultipleTerminals) { names.append("supportsMultipleTerminals") }
        if contains(.supportsTerminalChat) { names.append("supportsTerminalChat") }
        if contains(.supportsTaskPlans) { names.append("supportsTaskPlans") }
        if contains(.supportsWorkspaces) { names.append("supportsWorkspaces") }
        if contains(.supportsAppStreaming) { names.append("supportsAppStreaming") }
        if contains(.supportsDesktopControl) { names.append("supportsDesktopControl") }
        if contains(.supportsCursorlessCapture) { names.append("supportsCursorlessCapture") }
        return names
    }

    init(stableNames: [String]) {
        var flags: HostCapabilityFlags = []
        for name in stableNames {
            switch name {
            case "supportsHEVC":
                flags.insert(.supportsHEVC)
            case "supportsH264":
                flags.insert(.supportsH264)
            case "supportsMultiDisplay":
                flags.insert(.supportsMultiDisplay)
            case "supportsAudioLater":
                flags.insert(.supportsAudioLater)
            case "supportsMacClient":
                flags.insert(.supportsMacClient)
            case "supportsVideoFragmentation":
                flags.insert(.supportsVideoFragmentation)
            case "supportsHDR10":
                flags.insert(.supportsHDR10)
            case "supportsVideoFEC":
                flags.insert(.supportsVideoFEC)
            case "supportsOpusAudio":
                flags.insert(.supportsOpusAudio)
            case "supportsTerminal":
                flags.insert(.supportsTerminal)
            case "supportsMultipleTerminals":
                flags.insert(.supportsMultipleTerminals)
            case "supportsTerminalChat":
                flags.insert(.supportsTerminalChat)
            case "supportsTaskPlans":
                flags.insert(.supportsTaskPlans)
            case "supportsWorkspaces":
                flags.insert(.supportsWorkspaces)
            case "supportsDesktopControl":
                flags.insert(.supportsDesktopControl)
            case "supportsAppStreaming":
                flags.insert(.supportsAppStreaming)
            case "supportsCursorlessCapture":
                flags.insert(.supportsCursorlessCapture)
            default:
                continue
            }
        }
        self = flags
    }
}
