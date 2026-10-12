import CoreMedia
import Foundation
import SharedModels

// MARK: - Encoder State

public enum EncoderState: String, Sendable, Hashable {
    case idle
    case configured
    case encoding
    case failed
}

// MARK: - Encoded Frame Output

public struct EncodedFrame: Sendable {
    public var codec: EncodedFrameCodec
    public var data: Data
    public var isKeyframe: Bool
    public var presentationTimestamp: CMTime
    public var duration: CMTime
    public var width: Int
    public var height: Int
    public var sequenceNumber: UInt64
    /// H.264 SPS+PPS or HEVC VPS+SPS+PPS extracted from the format description.
    /// Present on keyframes so the decoder can (re-)initialize.
    public var parameterSets: Data?
    public var dynamicRange: StreamDynamicRange

    public init(
        codec: EncodedFrameCodec,
        data: Data,
        isKeyframe: Bool,
        presentationTimestamp: CMTime,
        duration: CMTime,
        width: Int,
        height: Int,
        sequenceNumber: UInt64,
        parameterSets: Data? = nil,
        dynamicRange: StreamDynamicRange = .sdr
    ) {
        self.codec = codec
        self.data = data
        self.isKeyframe = isKeyframe
        self.presentationTimestamp = presentationTimestamp
        self.duration = duration
        self.width = width
        self.height = height
        self.sequenceNumber = sequenceNumber
        self.parameterSets = parameterSets
        self.dynamicRange = dynamicRange
    }
}

public enum EncodedFrameCodec: String, Codable, Hashable, Sendable {
    case h264
    case hevc
}

// MARK: - Encoder Diagnostics

public struct EncoderDiagnostics: Sendable, Hashable {
    public var encodedFrames: UInt64
    public var keyframes: UInt64
    public var encodeErrors: UInt64
    public var lastEncodeTimestamp: Date?
    public var configuredCodec: EncodedFrameCodec?
    public var configuredWidth: Int?
    public var configuredHeight: Int?
    public var configuredBitrate: Int?
    public var reconfigureCount: Int

    public init(
        encodedFrames: UInt64 = 0,
        keyframes: UInt64 = 0,
        encodeErrors: UInt64 = 0,
        lastEncodeTimestamp: Date? = nil,
        configuredCodec: EncodedFrameCodec? = nil,
        configuredWidth: Int? = nil,
        configuredHeight: Int? = nil,
        configuredBitrate: Int? = nil,
        reconfigureCount: Int = 0
    ) {
        self.encodedFrames = encodedFrames
        self.keyframes = keyframes
        self.encodeErrors = encodeErrors
        self.lastEncodeTimestamp = lastEncodeTimestamp
        self.configuredCodec = configuredCodec
        self.configuredWidth = configuredWidth
        self.configuredHeight = configuredHeight
        self.configuredBitrate = configuredBitrate
        self.reconfigureCount = reconfigureCount
    }
}

// MARK: - Encoded Frame Receiver

public protocol EncodedFrameReceiver: AnyObject, Sendable {
    func didEncode(_ frame: EncodedFrame)
}

// MARK: - Encoder Pipeline Protocol

public protocol EncoderPipelineProtocol {
    var isEncoding: Bool { get }
    var encoderState: EncoderState { get }
    var encoderDiagnostics: EncoderDiagnostics { get }

    func configure(for display: DisplayDescriptor, qualityPreset: StreamQualityPreset, codec: EncodedFrameCodec) async throws
    func reconfigure(for display: DisplayDescriptor, qualityPreset: StreamQualityPreset, codec: EncodedFrameCodec) async throws
    func configure(
        for display: DisplayDescriptor,
        qualityPreset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        dynamicRange: StreamDynamicRange
    ) async throws
    func reconfigure(
        for display: DisplayDescriptor,
        qualityPreset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        dynamicRange: StreamDynamicRange
    ) async throws
    /// Floor-aware variants for *window* streams: `minLongEdge` (see
    /// `StreamScaling.scaledDimensions`) must equal the capture path's floor so
    /// capture and encode dimensions stay in lockstep. Display streams pass 0.
    func configure(
        for display: DisplayDescriptor,
        qualityPreset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        dynamicRange: StreamDynamicRange,
        minLongEdge: Int
    ) async throws
    func reconfigure(
        for display: DisplayDescriptor,
        qualityPreset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        dynamicRange: StreamDynamicRange,
        minLongEdge: Int
    ) async throws
    func startEncoding() async throws
    func flush() async throws
    func stopEncoding() async

    func setEncodedFrameReceiver(_ receiver: (any EncodedFrameReceiver)?)
    func stateChanges() -> AsyncStream<EncoderState>

    /// Request that the next encoded frame be a keyframe (IDR + parameter sets).
    /// Safe to call at any time; ignored when not encoding.
    func forceKeyframe()

    /// Update the encoder's target average bitrate at runtime, without
    /// rebuilding the compression session.  Used to track the WebRTC
    /// bandwidth estimate so the stream adapts to changing network
    /// conditions instead of running at a fixed bitrate.
    /// `bps` is in bits-per-second.  Safe to call at any time; ignored
    /// when not configured.
    func setBitrate(_ bps: Int)
}

public extension EncoderPipelineProtocol {
    func configure(
        for display: DisplayDescriptor,
        qualityPreset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        dynamicRange: StreamDynamicRange
    ) async throws {
        try await configure(for: display, qualityPreset: qualityPreset, codec: codec)
    }

    func reconfigure(
        for display: DisplayDescriptor,
        qualityPreset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        dynamicRange: StreamDynamicRange
    ) async throws {
        try await reconfigure(for: display, qualityPreset: qualityPreset, codec: codec)
    }

    // Default no-op so existing implementations remain source-compatible.
    func setBitrate(_ bps: Int) {}
}
