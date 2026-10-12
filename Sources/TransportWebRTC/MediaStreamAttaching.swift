import Foundation

// MARK: - Video Frame Source

/// Abstraction for a video frame source that can be attached to the WebRTC transport.
/// Concrete implementations bridge encoded frames (from the encoder pipeline) to the
/// WebRTC peer connection's video track/sender.
///
/// Phase 8 scaffolds this interface; the concrete implementation that feeds
/// `EncodedFrame` data into the WebRTC video pipeline is wired in a later phase.
public protocol VideoFrameSource: AnyObject, Sendable {
    /// Unique identifier for this source.
    var sourceID: String { get }

    /// Whether this source is currently attached and active.
    var isActive: Bool { get }
}

// MARK: - Video Frame Producer

/// A video frame source that actively produces encoded video frames.
/// When attached to a WebRTC session manager, the manager consumes
/// the frame stream and sends frames over the video data channel.
public protocol VideoFrameProducer: VideoFrameSource {
    func videoFrames() -> AsyncStream<VideoFrameData>
}

// MARK: - Media Stream State

/// Readiness state of the media/data channels on the WebRTC connection.
public struct MediaChannelReadiness: Hashable, Sendable {
    public var dataChannelState: DataChannelState
    public var videoTrackAttached: Bool
    public var audioTrackAttached: Bool

    public init(
        dataChannelState: DataChannelState = .closed,
        videoTrackAttached: Bool = false,
        audioTrackAttached: Bool = false
    ) {
        self.dataChannelState = dataChannelState
        self.videoTrackAttached = videoTrackAttached
        self.audioTrackAttached = audioTrackAttached
    }

    public var isDataChannelReady: Bool {
        dataChannelState == .open
    }

    public var isVideoReady: Bool {
        videoTrackAttached
    }

    public var summaryText: String {
        var parts: [String] = []
        parts.append("DC: \(dataChannelState.rawValue)")
        parts.append("Video: \(videoTrackAttached ? "attached" : "none")")
        parts.append("Audio: \(audioTrackAttached ? "attached" : "none")")
        return parts.joined(separator: " · ")
    }
}
