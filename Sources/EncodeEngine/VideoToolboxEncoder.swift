#if os(macOS)
import CoreMedia
import Foundation
import os
import SharedModels
import VideoToolbox

/// Hardware-accelerated H.264/HEVC encoder backed by VideoToolbox.
///
/// Conforms to ``EncoderPipelineProtocol`` so it can be wired into the host
/// streaming pipeline. Also exposes ``encodeSampleBuffer(_:)`` for direct
/// use by ``EncoderCaptureFrameBridge``.
public final class VideoToolboxEncoder: EncoderPipelineProtocol, @unchecked Sendable {

    // MARK: - Public State

    public private(set) var encoderState: EncoderState = .idle
    public private(set) var encoderDiagnostics = EncoderDiagnostics()
    public var isEncoding: Bool { encoderState == .encoding }

    // MARK: - Private

    private var session: VTCompressionSession?
    private var configuration: EncoderConfiguration?
    private weak var frameReceiver: (any EncodedFrameReceiver)?

    private var sequenceNumber: UInt64 = 0
    /// Last bitrate the adaptive controller requested via `setBitrate`. Re-applied after a
    /// session (re)build so a bitrate set while the session was momentarily nil (during
    /// reconfigure) isn't silently lost — otherwise the rebuilt session starts at the
    /// preset's full bitrate while the controller believes it's lower.
    private var lastRequestedBitrate: Int?
    private var shouldForceNextFrameKeyframe = false
    /// Consecutive encode failures; a short run forces a keyframe to re-sync.
    private var consecutiveEncodeErrors = 0
    private var stateContinuations: [UUID: AsyncStream<EncoderState>.Continuation] = [:]
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "VideoToolboxEncoder")

    public init() {}

    // MARK: - EncoderPipelineProtocol

    public func configure(for display: DisplayDescriptor, qualityPreset: StreamQualityPreset, codec: EncodedFrameCodec) async throws {
        try await configure(
            for: display,
            qualityPreset: qualityPreset,
            codec: codec,
            dynamicRange: .sdr
        )
    }

    public func configure(
        for display: DisplayDescriptor,
        qualityPreset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        dynamicRange: StreamDynamicRange
    ) async throws {
        try await configure(
            for: display,
            qualityPreset: qualityPreset,
            codec: codec,
            dynamicRange: dynamicRange,
            minLongEdge: 0
        )
    }

    public func configure(
        for display: DisplayDescriptor,
        qualityPreset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        dynamicRange: StreamDynamicRange,
        minLongEdge: Int
    ) async throws {
        func config(for codecChoice: EncodedFrameCodec) -> EncoderConfiguration {
            EncoderConfiguration.forPreset(
                qualityPreset,
                codec: codecChoice,
                width: Int(display.pixelSize.width),
                height: Int(display.pixelSize.height),
                dynamicRange: codecChoice == .hevc ? dynamicRange : .sdr,
                minLongEdge: minLongEdge
            )
        }

        var cfg = config(for: codec)
        do {
            try buildSession(configuration: cfg)
        } catch {
            // If the requested codec's session can't be created on this machine
            // (e.g. no hardware HEVC encoder), fall back to H.264 so the session
            // still starts rather than failing the whole connection.
            guard codec == .hevc else {
                transition(to: .failed)
                throw error
            }
            logger.warning("HEVC encoder unavailable (\(error.localizedDescription, privacy: .public)); falling back to H.264")
            cfg = config(for: .h264)
            do {
                try buildSession(configuration: cfg)
            } catch {
                transition(to: .failed)
                throw error
            }
        }

        lock.withLock {
            encoderDiagnostics.configuredCodec = cfg.codec
            encoderDiagnostics.configuredWidth = cfg.width
            encoderDiagnostics.configuredHeight = cfg.height
            encoderDiagnostics.configuredBitrate = cfg.averageBitrate
            encoderDiagnostics.reconfigureCount += 1
        }
        transition(to: .configured)
        logger.info("Configured \(cfg.summaryDescription, privacy: .public)")
    }

    public func reconfigure(for display: DisplayDescriptor, qualityPreset: StreamQualityPreset, codec: EncodedFrameCodec) async throws {
        try await reconfigure(
            for: display,
            qualityPreset: qualityPreset,
            codec: codec,
            dynamicRange: .sdr
        )
    }

    public func reconfigure(
        for display: DisplayDescriptor,
        qualityPreset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        dynamicRange: StreamDynamicRange
    ) async throws {
        await stopEncoding()
        try await configure(
            for: display,
            qualityPreset: qualityPreset,
            codec: codec,
            dynamicRange: dynamicRange,
            minLongEdge: 0
        )
    }

    public func reconfigure(
        for display: DisplayDescriptor,
        qualityPreset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        dynamicRange: StreamDynamicRange,
        minLongEdge: Int
    ) async throws {
        await stopEncoding()
        try await configure(
            for: display,
            qualityPreset: qualityPreset,
            codec: codec,
            dynamicRange: dynamicRange,
            minLongEdge: minLongEdge
        )
    }

    public func startEncoding() async throws {
        guard encoderState == .configured else {
            throw EncoderError.notConfigured
        }
        lock.withLock {
            sequenceNumber = 0
            shouldForceNextFrameKeyframe = true
        }
        transition(to: .encoding)
        logger.info("Encoding started")
    }

    public func flush() async throws {
        let session = lock.withLock { self.session }
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    public func stopEncoding() async {
        // Take the session out under the lock before invalidating, so a concurrent
        // encodeSampleBuffer on the encode queue can't use a just-invalidated session.
        let s = lock.withLock { () -> VTCompressionSession? in
            let current = self.session
            self.session = nil
            return current
        }
        if let s {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
        transition(to: .idle)
        logger.info("Encoding stopped")
    }

    public func setEncodedFrameReceiver(_ receiver: (any EncodedFrameReceiver)?) {
        lock.withLock { frameReceiver = receiver }
    }

    public func forceKeyframe() {
        lock.withLock { shouldForceNextFrameKeyframe = true }
    }

    public func setBitrate(_ bps: Int) {
        guard bps > 0 else { return }
        // Remember the requested bitrate even when the session is momentarily nil
        // (mid-reconfigure) so buildSession can re-apply it; otherwise the new session
        // would start at the preset's full bitrate and diverge from the controller.
        let session = lock.withLock { () -> VTCompressionSession? in
            lastRequestedBitrate = bps
            return self.session
        }
        guard let session else { return }
        // VideoToolbox accepts dynamic AverageBitRate updates without
        // tearing down the session.  We mirror it into diagnostics so
        // the stats overlay reflects what's actually being encoded.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bps))
        lock.withLock {
            encoderDiagnostics.configuredBitrate = bps
        }
    }

    public func stateChanges() -> AsyncStream<EncoderState> {
        AsyncStream { [weak self] continuation in
            guard let self else { continuation.finish(); return }
            let id = UUID()
            let current = self.lock.withLock { () -> EncoderState in
                self.stateContinuations[id] = continuation
                return self.encoderState
            }
            // Emit the current state immediately so a new subscriber doesn't sit on stale UI until
            // the next transition (matches ScreenCaptureEngine.stateChanges()).
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock { self?.stateContinuations.removeValue(forKey: id) }
            }
        }
    }

    // MARK: - Direct Encode (used by EncoderCaptureFrameBridge)

    public func encodeSampleBuffer(_ sampleBuffer: CMSampleBuffer) throws {
        // Atomically read encoding-state + session under the lock so this background encode-queue
        // call can't race a MainActor stopEncoding/buildSession that nils/invalidates the session.
        let session: VTCompressionSession? = lock.withLock { encoderState == .encoding ? self.session : nil }
        guard let session else { throw EncoderError.notEncoding }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw EncoderError.noImageBuffer
        }
        let forceKeyframe = lock.withLock { () -> Bool in
            if shouldForceNextFrameKeyframe {
                shouldForceNextFrameKeyframe = false
                return true
            }
            return false
        }
        let frameProperties: CFDictionary?
        if forceKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        } else {
            frameProperties = nil
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dur = CMSampleBufferGetDuration(sampleBuffer)
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: dur.isValid ? dur : CMTime(value: 1, timescale: 30),
            frameProperties: frameProperties,
            infoFlagsOut: nil,
            outputHandler: { [weak self] status, _, sample in
                guard let self else { return }
                guard status == noErr, let sample else {
                    // Previously swallowed silently. Record it, and after a short
                    // run of failures force the next frame to be a keyframe so the
                    // stream can re-sync instead of degrading unbounded.
                    self.lock.lock()
                    self.encoderDiagnostics.encodeErrors += 1
                    self.consecutiveEncodeErrors += 1
                    if self.consecutiveEncodeErrors >= 5 {
                        self.shouldForceNextFrameKeyframe = true
                        self.consecutiveEncodeErrors = 0
                    }
                    self.lock.unlock()
                    return
                }
                self.handleEncodedSample(sample)
            }
        )
        if status != noErr {
            lock.lock(); encoderDiagnostics.encodeErrors += 1; lock.unlock()
            throw EncoderError.vtError(status)
        }
    }

    // MARK: - Session Setup

    private func buildSession(configuration: EncoderConfiguration) throws {
        let existing = lock.withLock { () -> VTCompressionSession? in
            let current = self.session
            self.session = nil
            return current
        }
        if let existing { VTCompressionSessionInvalidate(existing) }
        self.configuration = configuration

        let codecType: CMVideoCodecType = configuration.codec == .hevc
            ? kCMVideoCodecType_HEVC
            : kCMVideoCodecType_H264

        var newSession: VTCompressionSession?
        // Prefer Apple's media engine and the encoder's low-latency rate-control path.
        // ScreenCaptureKit already supplies IOSurface-backed YUV buffers, so this keeps
        // capture -> encode on the Apple-Silicon hardware path without a CPU copy.
        var encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
#if arch(arm64)
        // Every supported Apple-Silicon Mac has the required media engine. Requiring
        // it prevents an unnoticed software fallback from adding latency and heat.
        encoderSpecification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
#endif
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: codecType,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )
        guard status == noErr, let created = newSession else {
            // Note: the caller (`configure`) owns the failed-state transition so it
            // can first attempt a codec fallback without emitting a spurious failure.
            throw EncoderError.sessionCreationFailed(status)
        }

        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime,               value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering,    value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)
        // A live desktop stream must never build an unbounded look-ahead queue. One
        // frame absorbs scheduler jitter while still bounding encoder-added latency.
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxFrameDelayCount,       value: NSNumber(value: 1))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate,       value: NSNumber(value: configuration.expectedFrameRate))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate,          value: NSNumber(value: configuration.averageBitrate))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,     value: NSNumber(value: configuration.maxKeyframeInterval))

        // NOTE: deliberately NOT setting kVTCompressionPropertyKey_DataRateLimits.
        // A hard peak cap clips keyframe/motion bursts and lowers quality. Rate is now
        // controlled by the adaptive bitrate controller (setBitrate), large frames are
        // fragmented for the unreliable channel, and the sender applies its own
        // backpressure — so a static peak cap only hurts quality.

        VTSessionSetProperty(
            created,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: configuration.profileLevel as CFString
        )

        // The capture side explicitly normalizes SDR to sRGB/BT.709. Write the same
        // colorimetry into the compressed format description so every decoder expands
        // the luma range and applies the intended transfer function instead of guessing
        // from an untagged stream. This is especially important for dark UI content,
        // where a range/profile mismatch is immediately visible as a faded veil.
        VTSessionSetProperty(
            created,
            key: kVTCompressionPropertyKey_ColorPrimaries,
            value: configuration.dynamicRange == .hdr10
                ? kCVImageBufferColorPrimaries_ITU_R_2020
                : kCVImageBufferColorPrimaries_ITU_R_709_2
        )
        VTSessionSetProperty(
            created,
            key: kVTCompressionPropertyKey_TransferFunction,
            value: configuration.dynamicRange == .hdr10
                ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                : kCVImageBufferTransferFunction_sRGB
        )
        VTSessionSetProperty(
            created,
            key: kVTCompressionPropertyKey_YCbCrMatrix,
            value: configuration.dynamicRange == .hdr10
                ? kCVImageBufferYCbCrMatrix_ITU_R_2020
                : kCVImageBufferYCbCrMatrix_ITU_R_709_2
        )

        if configuration.dynamicRange == .hdr10 {
            VTSessionSetProperty(
                created,
                key: kVTCompressionPropertyKey_OutputBitDepth,
                value: NSNumber(value: 10)
            )
            VTSessionSetProperty(
                created,
                key: kVTCompressionPropertyKey_HDRMetadataInsertionMode,
                value: kVTHDRMetadataInsertionMode_Auto
            )
        }

        VTCompressionSessionPrepareToEncodeFrames(created)
        // Assign the new session and read back any pending adaptive bitrate under the lock,
        // then apply it to the session *outside* the lock (VTSessionSetProperty must not run
        // while holding it). A nil value means the controller never lowered the rate, so the
        // freshly-built preset bitrate already stands.
        let pendingBitrate = lock.withLock { () -> Int? in
            self.session = created
            return self.lastRequestedBitrate
        }
        if let pendingBitrate, pendingBitrate > 0 {
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate,
                                 value: NSNumber(value: pendingBitrate))
            lock.withLock { encoderDiagnostics.configuredBitrate = pendingBitrate }
        }
    }

    // MARK: - Output Handling

    private func handleEncodedSample(_ sampleBuffer: CMSampleBuffer) {
        guard let cfg = configuration,
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let isKeyframe: Bool = {
            let notSync = CMGetAttachment(sampleBuffer,
                                          key: kCMSampleAttachmentKey_NotSync,
                                          attachmentModeOut: nil) as? Bool
            return !(notSync ?? false)
        }()

        var length = 0
        var rawPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &rawPointer) == kCMBlockBufferNoErr,
              let ptr = rawPointer, length > 0 else { return }

        let data = Data(bytes: ptr, count: length)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dur = CMSampleBufferGetDuration(sampleBuffer)

        var parameterSets: Data?
        if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = extractParameterSets(from: fmt, codec: cfg.codec)
        }

        let seqNum: UInt64 = lock.withLock {
            let n = sequenceNumber
            sequenceNumber += 1
            encoderDiagnostics.encodedFrames += 1
            if isKeyframe { encoderDiagnostics.keyframes += 1 }
            encoderDiagnostics.lastEncodeTimestamp = Date()
            consecutiveEncodeErrors = 0   // a frame made it through; reset error run
            return n
        }

        let frame = EncodedFrame(
            codec: cfg.codec,
            data: data,
            isKeyframe: isKeyframe,
            presentationTimestamp: pts,
            duration: dur.isValid ? dur : CMTime(value: 1, timescale: 30),
            width: cfg.width,
            height: cfg.height,
            sequenceNumber: seqNum,
            parameterSets: parameterSets,
            dynamicRange: cfg.dynamicRange
        )

        let receiver = lock.withLock { frameReceiver }
        receiver?.didEncode(frame)
    }

    private func extractParameterSets(from formatDesc: CMFormatDescription,
                                       codec: EncodedFrameCodec) -> Data? {
        var result = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]

        switch codec {
        case .h264:
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let ptr {
                    result.append(contentsOf: startCode)
                    result.append(ptr, count: size)
                }
            }
        case .hevc:
            if #available(macOS 10.13, *) {
                var count = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDesc, parameterSetIndex: 0,
                    parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                for i in 0..<count {
                    var ptr: UnsafePointer<UInt8>?
                    var size = 0
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        formatDesc, parameterSetIndex: i,
                        parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    if let ptr {
                        result.append(contentsOf: startCode)
                        result.append(ptr, count: size)
                    }
                }
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - State Machine

    private func transition(to newState: EncoderState) {
        lock.withLock {
            encoderState = newState
            stateContinuations.values.forEach { $0.yield(newState) }
        }
    }
}

// MARK: - Errors

private enum EncoderError: LocalizedError {
    case notConfigured
    case notEncoding
    case noImageBuffer
    case sessionCreationFailed(OSStatus)
    case vtError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConfigured:             return "Encoder is not configured."
        case .notEncoding:               return "Encoder is not currently encoding."
        case .noImageBuffer:             return "Sample buffer contains no image buffer."
        case .sessionCreationFailed(let c): return "VTCompressionSession creation failed (OSStatus \(c))."
        case .vtError(let c):            return "VideoToolbox encode error (OSStatus \(c))."
        }
    }
}
#endif
