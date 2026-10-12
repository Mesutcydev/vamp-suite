import Foundation

/// A single audio frame sent from the Mac host to the Mac client.
/// Payload is AAC-LC compressed audio at `sampleRate` Hz with `channelCount` channels.
public struct AudioFrameMessage: Codable, Hashable, Sendable {
    public let frameID: UInt64
    public let sampleTime: TimeInterval     // seconds since session audio start
    public let audioData: Data              // compressed audio bytes (codec-specific)
    public let sampleRate: Double           // e.g. 48000
    public let channelCount: Int            // 1 or 2
    public let codec: String               // "aac"

    public init(
        frameID: UInt64,
        sampleTime: TimeInterval,
        audioData: Data,
        sampleRate: Double,
        channelCount: Int,
        codec: String = "aac"
    ) {
        self.frameID = frameID
        self.sampleTime = sampleTime
        self.audioData = audioData
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.codec = codec
    }
}
