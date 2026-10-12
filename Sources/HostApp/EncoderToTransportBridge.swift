import CoreMedia
import EncodeEngine
import Foundation
import TransportWebRTC
import os

/// Bridges the encoder pipeline output to the WebRTC video transport.
/// Conforms to `EncodedFrameReceiver` (receives from encoder) and
/// `VideoFrameProducer` (feeds frames to the WebRTC session manager).
final class EncoderToTransportBridge: EncodedFrameReceiver, VideoFrameProducer, @unchecked Sendable {
    let sourceID: String
    private var _isActive: Bool = false
    private(set) var droppedFrames: UInt64 = 0
    private var _framesSent: UInt64 = 0
    private var _hasLoggedFirstForward = false

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<VideoFrameData>.Continuation] = [:]
    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "TransportBridge")

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isActive
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func snapshotContinuations() -> [AsyncStream<VideoFrameData>.Continuation] {
        lock.lock()
        let snapshot = Array(continuations.values)
        lock.unlock()
        return snapshot
    }

    private func takeContinuations() -> [AsyncStream<VideoFrameData>.Continuation] {
        lock.lock()
        let snapshot = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        return snapshot
    }

    init(sourceID: String = "encoder-transport-bridge") {
        self.sourceID = sourceID
    }

    deinit {
        let snapshot = takeContinuations()
        snapshot.forEach { $0.finish() }
    }

    func activate() {
        lock.lock()
        _isActive = true
        lock.unlock()
        logger.info("Transport bridge activated")
    }

    func deactivate() {
        lock.lock()
        _isActive = false
        lock.unlock()
        let snapshot = takeContinuations()
        snapshot.forEach { $0.finish() }
        logger.info("Transport bridge deactivated (dropped \(self.droppedFrames) frames total)")
    }

    // MARK: - VideoFrameProducer

    func videoFrames() -> AsyncStream<VideoFrameData> {
        // Buffer a few encoded frames so a brief forwarding stall doesn't drop encoded
        // *delta* frames (which corrupts the stream until the next keyframe). 2 was too
        // tight; 8 absorbs normal jitter while still bounding host-side latency. The
        // transport applies its own backpressure for sustained congestion.
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    // MARK: - EncodedFrameReceiver

    func didEncode(_ frame: EncodedFrame) {
        let isActive = withLock { _isActive }
        guard isActive else {
            return
        }

        let codec: VideoFrameData.VideoCodec
        switch frame.codec {
        case .h264: codec = .h264
        case .hevc: codec = .hevc
        }

        let videoFrame = VideoFrameData(
            codec: codec,
            data: frame.data,
            isKeyframe: frame.isKeyframe,
            presentationTimestamp: frame.presentationTimestamp.seconds,
            width: frame.width,
            height: frame.height,
            sequenceNumber: frame.sequenceNumber,
            parameterSets: frame.parameterSets,
            dynamicRange: frame.dynamicRange
        )

        let conts = snapshotContinuations()
        if conts.isEmpty {
            logger.debug("Bridge active but no consumer attached — frame discarded (seq=\(frame.sequenceNumber))")
            return
        }
        for c in conts {
            let result = c.yield(videoFrame)
            if case .dropped = result {
                withLock { droppedFrames += 1 }
            }
        }
        let isFirst = withLock { () -> Bool in
            _framesSent += 1
            if !_hasLoggedFirstForward {
                _hasLoggedFirstForward = true
                return true
            }
            return false
        }
        if isFirst {
            logger.info("First encoded frame forwarded to transport: \(frame.width)×\(frame.height), keyframe=\(frame.isKeyframe), seq=\(frame.sequenceNumber)")
        }
    }
}

#if os(macOS)
import CaptureEngine
import SharedModels

/// Captures + encodes ONE additional display and pushes its frames — tagged with a wire
/// `displayID` — straight to the transport via `sendVideoFrame`. The primary display keeps
/// the existing pipeline untouched (wire displayID 0); one of these runs in parallel for
/// each extra display the client asked to view.
///
/// Concurrency: `sendVideoFrame` ultimately does a single atomic `NWConnection.send` per
/// framed packet, so multiple streamers sending at once can't corrupt the channel framing.
/// `start`/`stop` are driven serially by the session coordinator.
/// (Lives here rather than its own file so it's a member of the host Xcode targets without
/// a project-file edit.)
final class SecondaryDisplayStreamer: @unchecked Sendable {
    let wireDisplayID: UInt8
    let displayID: String

    private let capture: any CaptureEngineProtocol
    private let encoder = VideoToolboxEncoder()
    private let receiver: TaggingEncodedFrameReceiver
    private var captureBridge: EncoderCaptureFrameBridge?
    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "SecondaryDisplay")

    init(wireDisplayID: UInt8, displayID: String, webRTCSessionManager: any WebRTCSessionManaging) {
        self.wireDisplayID = wireDisplayID
        self.displayID = displayID
        self.capture = ScreenCaptureEngine()
        self.receiver = TaggingEncodedFrameReceiver(wireDisplayID: wireDisplayID, manager: webRTCSessionManager)
    }

    func start(display: DisplayDescriptor, preset: StreamQualityPreset, codec: EncodedFrameCodec, dynamicRange: StreamDynamicRange) async throws {
        encoder.setEncodedFrameReceiver(receiver)
        // Match the primary's dynamic range. Capturing/encoding SDR while the session — and the
        // client's secondary decoder — expect HDR10 (10-bit) renders the secondary display BLACK.
        // Sync both the encoder and the capture to the same range.
        try await encoder.configure(for: display, qualityPreset: preset, codec: codec, dynamicRange: dynamicRange)
        try await encoder.startEncoding()
        let bridge = EncoderCaptureFrameBridge(encoder: encoder)
        captureBridge = bridge
        capture.setFrameReceiver(bridge)
        try await capture.startCapture(displayID: display.id, qualityPreset: preset, allowsHighResolution: false, dynamicRange: dynamicRange)
        logger.info("Secondary display \(self.displayID, privacy: .public) streaming as wireID \(self.wireDisplayID) (\(dynamicRange == .hdr10 ? "HDR10" : "SDR", privacy: .public))")
    }

    func forceKeyframe() {
        encoder.forceKeyframe()
    }

    func stop() async {
        await capture.stopCapture()
        capture.setFrameReceiver(nil)
        await encoder.stopEncoding()
        encoder.setEncodedFrameReceiver(nil)
        captureBridge = nil
    }
}

/// Tags each encoded frame with the display's wire ID and sends it over the shared video
/// channel. Runs on the encoder's callback thread.
final class TaggingEncodedFrameReceiver: EncodedFrameReceiver, @unchecked Sendable {
    private let wireDisplayID: UInt8
    private let manager: any WebRTCSessionManaging

    init(wireDisplayID: UInt8, manager: any WebRTCSessionManaging) {
        self.wireDisplayID = wireDisplayID
        self.manager = manager
    }

    func didEncode(_ frame: EncodedFrame) {
        let codec: VideoFrameData.VideoCodec = frame.codec == .hevc ? .hevc : .h264
        let videoFrame = VideoFrameData(
            codec: codec,
            data: frame.data,
            isKeyframe: frame.isKeyframe,
            presentationTimestamp: frame.presentationTimestamp.seconds,
            width: frame.width,
            height: frame.height,
            sequenceNumber: frame.sequenceNumber,
            parameterSets: frame.parameterSets,
            dynamicRange: frame.dynamicRange,
            displayID: wireDisplayID
        )
        try? manager.sendVideoFrame(videoFrame)
    }
}
#endif
