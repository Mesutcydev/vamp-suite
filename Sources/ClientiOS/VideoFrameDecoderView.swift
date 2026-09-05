import AVFoundation
#if canImport(AVKit)
import AVKit
#endif
import Combine
import CoreMedia
import CoreVideo
import Foundation
import SharedModels
import SharedUtilities
import SwiftUI
import TransportWebRTC
import VideoToolbox
import os
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Video Frame Decoder

/// Decodes received `VideoFrameData` (H.264/HEVC) into `CVPixelBuffer` frames
/// using VideoToolbox's `VTDecompressionSession`.
///
/// Parameter sets (SPS/PPS) extracted on keyframes are used to create the
/// `CMVideoFormatDescription` needed to initialize the decoder.
final class VideoFrameDecoder: @unchecked Sendable {
    /// Hard ceiling on decoded frame dimensions. Comfortably above any real display
    /// (6K Pro Display XDR = 6016×3384, 8K = 7680×4320) while bounding the worst-case
    /// allocation a malformed or hostile keyframe's parameter sets can request.
    private static let maxDecodeDimension: Int32 = 8192

    private let lock = NSLock()
    private let decodeQueue = DispatchQueue(label: "com.mesutcy.remotedesktop.terminal.video-decode", qos: .userInitiated)
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentDynamicRange: StreamDynamicRange = .sdr
    private var callbackSelfRef: UnsafeMutableRawPointer?
    private var decodeGeneration: UInt64 = 0
    private var _decodedFrames: UInt64 = 0
    private var _decodeErrors: UInt64 = 0
    /// Reference-time of the last successful decode, used by the client watchdog to detect
    /// a stream that's receiving frames but never decoding (e.g. the initial keyframe's
    /// parameter sets were lost on the unreliable channel). Nil until the first success.
    private var _lastSuccessfulDecodeAt: TimeInterval?
    private let logger = Logger(subsystem: "com.mesutcy.remotedesktop.terminal", category: "VideoDecoder")
    private var hasLoggedDecodeStart = false
    private var hasLoggedDecodeSuccess = false

    var decodedFrames: UInt64 { lock.withLock { _decodedFrames } }
    var decodeErrors: UInt64 { lock.withLock { _decodeErrors } }

    /// Callback invoked on each decoded pixel buffer.
    var onDecodedFrame: ((CVPixelBuffer, CMTime) -> Void)?

    /// Invoked (debounced) when decoding fails on a non-keyframe — i.e. a delta
    /// arrived whose reference frame is missing (packet loss / mid-stream keyframe
    /// loss). The owner should ask the host for a fresh keyframe; otherwise the
    /// decoder emits errors indefinitely (the "(no keyframe)" stall).
    var onNeedsKeyframe: (() -> Void)?
    private var lastKeyframeRequest: TimeInterval = 0

    deinit {
        teardownSession()
    }

    /// Fire `onNeedsKeyframe` at most ~twice a second so a burst of failed deltas
    /// triggers a single recovery request rather than a flood.
    private func requestKeyframeRecovery() {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        let elapsed = now - lastKeyframeRequest
        if elapsed < 0.5 {
            lock.unlock()
            return
        }
        lastKeyframeRequest = now
        lock.unlock()
        onNeedsKeyframe?()
    }

    /// Client-side keyframe watchdog. Call periodically while frames are being received:
    /// if no frame has decoded successfully within `stallSeconds` (covers a lost initial
    /// keyframe whose parameter sets never arrived, where a non-keyframe decode failure may
    /// never occur), proactively request a fresh keyframe. Routed through the same debounced
    /// `requestKeyframeRecovery`, so it can't fire faster than that debounce (~2/sec).
    func requestKeyframeIfStalled(stallSeconds: TimeInterval = 2.0) {
        let now = Date().timeIntervalSinceReferenceDate
        let stalled = lock.withLock { () -> Bool in
            guard let last = _lastSuccessfulDecodeAt else {
                // No successful decode yet at all — treat as stalled so we keep nudging
                // the host for an IDR until the first frame lands.
                return true
            }
            return (now - last) >= stallSeconds
        }
        guard stalled else { return }
        requestKeyframeRecovery()
    }

    func stopDecoding() {
        lock.lock()
        decodeGeneration &+= 1
        lock.unlock()
        teardownSession()
    }

    func decodeAsync(_ frame: VideoFrameData) {
        let generation = lock.withLock { decodeGeneration }
        decodeQueue.async { [weak self] in
            guard let self else { return }
            let isCurrent = self.lock.withLock { self.decodeGeneration == generation }
            guard isCurrent else { return }
            self.decode(frame)
        }
    }

    private func teardownSession() {
        let session: VTDecompressionSession?
        let selfRef: UnsafeMutableRawPointer?
        lock.lock()
        session = decompressionSession
        decompressionSession = nil
        formatDescription = nil
        currentDynamicRange = .sdr
        selfRef = callbackSelfRef
        callbackSelfRef = nil
        // Clear so the watchdog treats the next session as freshly started.
        _lastSuccessfulDecodeAt = nil
        lock.unlock()

        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        if let selfRef {
            Unmanaged<VideoFrameDecoder>.fromOpaque(selfRef).release()
        }
    }

    /// Decode a received video frame. For keyframes with parameter sets,
    /// re-initializes the decoder if needed.
    func decode(_ frame: VideoFrameData) {
        lock.lock()
        let shouldLogDecodeStart = !hasLoggedDecodeStart
        if shouldLogDecodeStart {
            hasLoggedDecodeStart = true
        }
        lock.unlock()
        if shouldLogDecodeStart {
            logger.info(
                "Frame decode started: codec=\(frame.codec.rawValue), seq=\(frame.sequenceNumber), keyframe=\(frame.isKeyframe), bytes=\(frame.data.count)"
            )
        }

        // NOTE: the video data channel is intentionally unordered + unreliable
        // (isOrdered:false, maxRetransmits:0) for low latency, so frames legitimately
        // arrive out of order. We must NOT drop "non-contiguous" frames or request a
        // keyframe on every reorder — that caused a keyframe-request storm and made
        // the stream far worse. Recovery is handled purely by `requestKeyframeRecovery`
        // when VideoToolbox actually fails to decode (debounced), which is correct
        // regardless of ordering.

        // If this is a keyframe with parameter sets, try to (re-)initialize
        if frame.isKeyframe, let paramSets = frame.parameterSets, !paramSets.isEmpty {
            let codec: CMVideoCodecType = frame.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
            if let newFmt = createFormatDescription(parameterSets: paramSets, codec: codec) {
                let needsReset: Bool
                lock.lock()
                if let formatDescription {
                    needsReset = !CMFormatDescriptionEqual(formatDescription, otherFormatDescription: newFmt)
                        || currentDynamicRange != frame.dynamicRange
                } else {
                    needsReset = true
                }
                lock.unlock()

                if needsReset {
                    resetSession(with: newFmt, dynamicRange: frame.dynamicRange)
                }
            }
        }

        lock.lock()
        guard let session = decompressionSession, let fmtDesc = formatDescription else {
            _decodeErrors += 1
            lock.unlock()
            // No decoder session yet. We can't start mid-GOP. This covers two cases:
            //   • a non-keyframe arrived first (normal), or
            //   • a frame *marked* keyframe arrived but with nil/empty parameter sets
            //     (a lost SPS/PPS fragment on the unreliable/unordered video channel).
            // In both cases we have no way to (re)init the decoder, so ask the host for a
            // fresh IDR (debounced) instead of silently waiting for one that never comes.
            requestKeyframeRecovery()
            return
        }
        lock.unlock()

        // Copy encoded bytes into block-buffer-owned memory.
        // Using borrowed Data memory is unsafe for asynchronous decode.
        let frameData = frame.data
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frameData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frameData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard blockStatus == noErr, let blockBuffer else {
            lock.lock()
            _decodeErrors += 1
            lock.unlock()
            logger.error("CMBlockBuffer creation failed: \(blockStatus)")
            return
        }

        let copyStatus = frameData.withUnsafeBytes { rawPtr in
            guard let baseAddress = rawPtr.baseAddress else {
                return kCMBlockBufferBadCustomBlockSourceErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: frameData.count
            )
        }

        guard copyStatus == kCMBlockBufferNoErr else {
            lock.lock()
            _decodeErrors += 1
            lock.unlock()
            logger.error("CMBlockBuffer copy failed: \(copyStatus)")
            return
        }

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = frameData.count
        let pts = CMTime(seconds: frame.presentationTimestamp, preferredTimescale: 90000)
        var timingInfo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)

        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: fmtDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sampleBuffer else {
            lock.lock()
            _decodeErrors += 1
            lock.unlock()
            logger.error("CMSampleBuffer creation failed: \(status)")
            return
        }

        // Decode
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )

        if decodeStatus != noErr {
            lock.lock()
            _decodeErrors += 1
            lock.unlock()
            if decodeStatus != kVTInvalidSessionErr {
                logger.error("Decode failed: \(decodeStatus)")
                // A delta failed to decode — its reference frame is likely lost.
                // Recover by requesting a fresh keyframe instead of emitting errors
                // forever waiting for one that never comes.
                if !frame.isKeyframe {
                    requestKeyframeRecovery()
                }
            }
        }
    }

    // MARK: - Format Description

    /// Parse Annex-B parameter sets (start-code-delimited) into NAL units
    /// and create a CMVideoFormatDescription.
    private func createFormatDescription(parameterSets: Data, codec: CMVideoCodecType) -> CMVideoFormatDescription? {
        let nalUnits = parseAnnexBNALUnits(parameterSets)
        guard !nalUnits.isEmpty else { return nil }

        // Flatten all NAL units into one contiguous allocation so we can build
        // stable UnsafePointer values inside a single withUnsafeBufferPointer
        // scope that spans the CMVideoFormatDescription API call.
        // Storing baseAddress values *outside* a withUnsafeBufferPointer closure
        // is unsafe: Swift may move or release the backing store the moment the
        // closure exits, which is invisible in Debug builds but reliably crashes
        // (or silently corrupts) Release builds where the optimiser reuses memory.
        var flat: [UInt8] = []
        var offsets: [Int] = []
        var sizes: [Int] = []
        flat.reserveCapacity(nalUnits.reduce(0) { $0 + $1.count })
        for unit in nalUnits {
            offsets.append(flat.count)
            sizes.append(unit.count)
            flat.append(contentsOf: unit)
        }

        var fmt: CMVideoFormatDescription?
        flat.withUnsafeBufferPointer { flatBP in
            guard let base = flatBP.baseAddress else { return }
            // Build the pointer array inside this scope — all entries are
            // offsets into `flat`, which is pinned for the duration of the closure.
            let ptrs: [UnsafePointer<UInt8>] = offsets.map { base + $0 }
            let count = ptrs.count
            ptrs.withUnsafeBufferPointer { ptrsBP in
                sizes.withUnsafeBufferPointer { sizesBP in
                    guard let pp = ptrsBP.baseAddress,
                          let sp = sizesBP.baseAddress else { return }
                    let status: OSStatus
                    if codec == kCMVideoCodecType_H264 {
                        status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: count,
                            parameterSetPointers: pp,
                            parameterSetSizes: sp,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &fmt
                        )
                    } else {
                        if #available(iOS 16, macOS 13, *) {
                            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: count,
                                parameterSetPointers: pp,
                                parameterSetSizes: sp,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &fmt
                            )
                        } else {
                            status = -1
                        }
                    }
                    if status != noErr {
                        self.logger.warning("Format description creation failed: \(status)")
                    }
                }
            }
        }

        guard let createdFmt = fmt else { return nil }
        // Reject implausible dimensions from untrusted parameter sets before they
        // reach the decoder and pixel-buffer allocation.
        let dims = CMVideoFormatDescriptionGetDimensions(createdFmt)
        guard dims.width > 0, dims.height > 0,
              dims.width <= Self.maxDecodeDimension, dims.height <= Self.maxDecodeDimension else {
            logger.error("Rejecting stream: implausible video dimensions \(dims.width)×\(dims.height)")
            return nil
        }
        return createdFmt
    }

    /// Split Annex-B data into individual NAL units (removing 3- or 4-byte start codes).
    private func parseAnnexBNALUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        var i = data.startIndex
        let end = data.endIndex

        func findStartCode(from pos: Data.Index) -> (Data.Index, Int)? {
            var j = pos
            while j < end - 2 {
                if data[j] == 0 && data[j + 1] == 0 {
                    if j + 2 < end && data[j + 2] == 1 {
                        return (j, 3)
                    }
                    if j + 3 < end && data[j + 2] == 0 && data[j + 3] == 1 {
                        return (j, 4)
                    }
                }
                j += 1
            }
            return nil
        }

        // Find first start code
        guard let (firstStart, firstLen) = findStartCode(from: i) else { return [] }
        i = firstStart + firstLen

        while i < end {
            if let (nextStart, nextLen) = findStartCode(from: i) {
                units.append(data[i..<nextStart])
                i = nextStart + nextLen
            } else {
                units.append(data[i..<end])
                break
            }
        }

        return units
    }

    // MARK: - Session

    private func resetSession(
        with newFmt: CMVideoFormatDescription,
        dynamicRange: StreamDynamicRange
    ) {
        teardownSession()
        lock.lock()
        formatDescription = newFmt
        currentDynamicRange = dynamicRange
        lock.unlock()

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: dynamicRange == .hdr10
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        var session: VTDecompressionSession?
        let retainedSelfRef = Unmanaged.passRetained(self).toOpaque()
        let callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, pixelBuffer, pts, _ in
                guard let refcon else { return }
                let decoder = Unmanaged<VideoFrameDecoder>.fromOpaque(refcon).takeUnretainedValue()
                guard status == noErr, let pixelBuffer else {
                    decoder.logger.error("Decode callback failed: \(status)")
                    return
                }
                let dynamicRange = decoder.lock.withLock { decoder.currentDynamicRange }
                if dynamicRange == .hdr10 {
                    // Match the encoder's standards-correct HDR10 tagging:
                    // BT.2020 primaries + PQ transfer + BT.2020 matrix.
                    CVBufferSetAttachment(
                        pixelBuffer,
                        kCVImageBufferColorPrimariesKey,
                        kCVImageBufferColorPrimaries_ITU_R_2020,
                        .shouldPropagate
                    )
                    CVBufferSetAttachment(
                        pixelBuffer,
                        kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                        .shouldPropagate
                    )
                    CVBufferSetAttachment(
                        pixelBuffer,
                        kCVImageBufferYCbCrMatrixKey,
                        kCVImageBufferYCbCrMatrix_ITU_R_2020,
                        .shouldPropagate
                    )
                } else {
                    // The decoder outputs SDR as BGRA. The format description is
                    // created from parameter sets without color extensions, so
                    // VideoToolbox may otherwise leave the decoded buffer without
                    // an explicit SDR color interpretation. Tag it as the same
                    // sRGB/BT.709 contract used by ScreenCaptureKit and the encoder;
                    // the sRGB transfer function preserves dark UI contrast.
                    CVBufferSetAttachment(
                        pixelBuffer,
                        kCVImageBufferColorPrimariesKey,
                        kCVImageBufferColorPrimaries_ITU_R_709_2,
                        .shouldPropagate
                    )
                    CVBufferSetAttachment(
                        pixelBuffer,
                        kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_sRGB,
                        .shouldPropagate
                    )
                    CVBufferSetAttachment(
                        pixelBuffer,
                        kCVImageBufferYCbCrMatrixKey,
                        kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                        .shouldPropagate
                    )
                }
                decoder.lock.lock()
                decoder._decodedFrames += 1
                decoder._lastSuccessfulDecodeAt = Date().timeIntervalSinceReferenceDate
                let shouldLogDecodeSuccess = !decoder.hasLoggedDecodeSuccess
                if shouldLogDecodeSuccess {
                    decoder.hasLoggedDecodeSuccess = true
                }
                decoder.lock.unlock()
                if shouldLogDecodeSuccess {
                    decoder.logger.info("Frame decode succeeded")
                }
                decoder.onDecodedFrame?(pixelBuffer, pts)
            },
            decompressionOutputRefCon: retainedSelfRef
        )

        var callbackRecord = callback
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newFmt,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )

        if status == noErr, let session {
            lock.lock()
            decompressionSession = session
            callbackSelfRef = retainedSelfRef
            lock.unlock()
            logger.info("Decoder session created")
        } else {
            Unmanaged<VideoFrameDecoder>.fromOpaque(retainedSelfRef).release()
            logger.error("Decoder session creation failed: \(status)")
        }
    }

}

// MARK: - Video Renderer View Model

/// Receives decoded pixel buffers and provides them to the SwiftUI layer.
@MainActor
final class VideoRendererViewModel: ObservableObject {
    @Published private(set) var latestPixelBuffer: CVPixelBuffer?
    @Published private(set) var frameSize: DesktopSize?
    @Published private(set) var framesDecoded: UInt64 = 0
    @Published private(set) var isReceiving = false
    @Published private(set) var codecName: String = "--"

    private(set) var lastDecodedAt: TimeInterval?

    /// Optional wire display filter for multi-display demultiplexing.
    var displayIDFilter: UInt8?

    /// Set by the owning screen to forward decode-failure keyframe requests to the
    /// session coordinator. Always delivered on the main actor.
    var onNeedsKeyframe: (() -> Void)?

    /// Multicast of decoded frames on the main actor. Display views subscribe and
    /// enqueue each frame straight into their display layer — bypassing SwiftUI's
    /// `@Published` diffing, which coalesces and silently drops intermediate frames
    /// when the main thread is busy. Multiple views (preview card + fullscreen) can
    /// subscribe independently.
    let framePublisher = PassthroughSubject<CVPixelBuffer, Never>()

    let decoder = VideoFrameDecoder()
    private let webRTCSessionManager: any WebRTCSessionManaging
    private var videoTask: Task<Void, Never>?
    /// Periodically asks the decoder to request a keyframe if the stream is receiving
    /// frames but not decoding any (lost initial keyframe). The decoder's own debounce
    /// rate-limits the actual request, so polling at ~1 Hz can't spam the host.
    private var decodeWatchdogTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.mesutcy.remotedesktop.terminal", category: "VideoRenderer")
    private var hasLoggedFirstRender = false
    private var receiveGeneration: UInt64 = 0
    /// Gate for late frames: a frame decoded just before stop must not set a stale
    /// buffer after teardown. True only between startReceiving and stopReceiving.
    private var acceptingFrames = false

    init(webRTCSessionManager: any WebRTCSessionManaging) {
        self.webRTCSessionManager = webRTCSessionManager
        decoder.onNeedsKeyframe = { [weak self] in
            Task { @MainActor [weak self] in
                self?.onNeedsKeyframe?()
            }
        }
    }

    func startReceiving() {
        videoTask?.cancel()
        videoTask = nil
        decodeWatchdogTask?.cancel()
        decodeWatchdogTask = nil
        receiveGeneration &+= 1
        let generation = receiveGeneration
        decoder.stopDecoding()
        decoder.onDecodedFrame = { [weak self] pixelBuffer, _ in
            Task { @MainActor [weak self] in
                guard let self, self.acceptingFrames, self.receiveGeneration == generation else { return }
                // Direct, un-coalesced fan-out to subscribed display views.
                self.framePublisher.send(pixelBuffer)
                self.lastDecodedAt = ProcessInfo.processInfo.systemUptime
                self.latestPixelBuffer = pixelBuffer
                self.framesDecoded = self.decoder.decodedFrames
                if !self.hasLoggedFirstRender {
                    self.hasLoggedFirstRender = true
                    self.logger.info("Renderer: first decoded frame presented to UI")
                }
            }
        }
        lastDecodedAt = nil
        latestPixelBuffer = nil
        frameSize = nil
        framesDecoded = 0
        isReceiving = false
        codecName = "--"
        hasLoggedFirstRender = false
        acceptingFrames = true
        logger.info("Renderer: startReceiving gen=\(generation)")

        videoTask = Task { [weak self] in
            guard let self else { return }
            self.logger.info("Renderer: videoTask gen=\(generation) subscribed to receivedVideoFrames")
            for await frame in webRTCSessionManager.receivedVideoFrames() {
                guard !Task.isCancelled else { break }
                guard self.receiveGeneration == generation else {
                    self.logger.info("Renderer: videoTask gen=\(generation) superseded — exiting")
                    break
                }
                // Multi-display: when a filter is set, this renderer only decodes its own
                // display's frames (others share the channel). nil = accept all (single display).
                if let filter = self.displayIDFilter, frame.displayID != filter { continue }
                if !self.isReceiving {
                    self.isReceiving = true
                    self.logger.info("Renderer: first frame received gen=\(generation) \(frame.width)×\(frame.height) codec=\(frame.codec.rawValue) keyframe=\(frame.isKeyframe)")
                }
                self.frameSize = DesktopSize(width: Double(frame.width), height: Double(frame.height))
                self.codecName = frame.codec == .hevc ? "HEVC" : "H.264"
                self.decoder.decodeAsync(frame)
            }
            guard self.receiveGeneration == generation else { return }
            self.logger.info("Renderer: videoTask gen=\(generation) stream ended")
            self.isReceiving = false
        }

        // Client keyframe watchdog: while frames are arriving, nudge the host for an IDR
        // if nothing decodes within the stall window. Lost keyframe fragments on the
        // unreliable video channel otherwise leave the picture stuck with no decode error
        // to trigger the existing recovery path.
        decodeWatchdogTask?.cancel()
        decodeWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.receiveGeneration == generation else { return }
                // Nudge for an IDR whenever decoding is stalled — including before the very
                // first decoded frame. A secondary display that missed the host's initial
                // keyframe never sets `isReceiving`, so gating on it would deadlock it on
                // "waiting for frame"; `requestKeyframeIfStalled` already self-gates on the
                // stall window + recovery debounce.
                self.decoder.requestKeyframeIfStalled()
            }
        }
    }

    func stopReceiving() {
        videoTask?.cancel()
        videoTask = nil
        decodeWatchdogTask?.cancel()
        decodeWatchdogTask = nil
        receiveGeneration &+= 1
        acceptingFrames = false
        decoder.stopDecoding()
        isReceiving = false
        lastDecodedAt = nil
        latestPixelBuffer = nil
        frameSize = nil
        framesDecoded = 0
        codecName = "--"
        hasLoggedFirstRender = false
    }
}

// MARK: - Shared HDR-capable display-layer presentation

/// Presentation helpers shared by the iOS (`VideoDisplayUIView`) and macOS
/// (`VideoDisplayNSView`) display views. Wraps a decoded pixel buffer in a sample
/// buffer and enqueues it into an `AVSampleBufferDisplayLayer` for zero-copy GPU
/// presentation, and opts the layer into EDR so HDR10 content actually shows in HDR.
enum VideoLayerPresenter {
    /// Keep EDR presentation synchronized with the decoded frame. The client can
    /// receive SDR when HDR was requested but the host cannot negotiate it (for
    /// example, while connecting to an older host), so enabling EDR once at view
    /// creation incorrectly tone-maps that SDR fallback and makes it look faded.
    /// iOS 17 / macOS 14+; older OSes stay on the system's SDR path.
    static func updateDynamicRange(for pixelBuffer: CVPixelBuffer?, on layer: AVSampleBufferDisplayLayer) {
        if #available(iOS 17.0, macOS 14.0, *) {
            layer.wantsExtendedDynamicRangeContent = pixelBuffer.map(isHDRPixelBuffer) ?? false
        }
    }

    static func clear(_ layer: AVSampleBufferDisplayLayer) {
        updateDynamicRange(for: nil, on: layer)
        flushRemovingImage(layer)
    }

    /// Enqueue `pixelBuffer` for immediate display. Rebuilds `formatDescription` on a
    /// format/size change (it carries the HDR color attachments through to the sample
    /// buffer) and recovers a `.failed` layer (a plain `flush()` does not clear it).
    static func present(_ pixelBuffer: CVPixelBuffer,
                        in layer: AVSampleBufferDisplayLayer,
                        formatDescription: inout CMVideoFormatDescription?) {
        updateDynamicRange(for: pixelBuffer, on: layer)
        if status(of: layer) == .failed {
            flushRemovingImage(layer)
            formatDescription = nil
        }
        if formatDescription == nil ||
            !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            var fmt: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fmt)
            formatDescription = fmt
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: .invalid,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else { return }

        // Present immediately — this is live video, not a timed playlist.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        enqueue(sampleBuffer, into: layer)
    }

    private static func isHDRPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let transferFunction = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            nil
        ) else {
            return false
        }

        return CFEqual(transferFunction, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
            || CFEqual(transferFunction, kCVImageBufferTransferFunction_ITU_R_2100_HLG)
    }

    // iOS 18 / macOS 15 moved enqueue/flush/status onto `sampleBufferRenderer`. The
    // older calls must live in the `else` so Swift narrows availability and doesn't
    // warn about the symbols it deprecated in 18/15.
    private static func status(of layer: AVSampleBufferDisplayLayer) -> AVQueuedSampleBufferRenderingStatus {
        if #available(iOS 18.0, macOS 15.0, *) {
            return layer.sampleBufferRenderer.status
        } else {
            return layer.status
        }
    }
    private static func enqueue(_ sb: CMSampleBuffer, into layer: AVSampleBufferDisplayLayer) {
        if #available(iOS 18.0, macOS 15.0, *) {
            layer.sampleBufferRenderer.enqueue(sb)
        } else {
            layer.enqueue(sb)
        }
    }
    private static func flushRemovingImage(_ layer: AVSampleBufferDisplayLayer) {
        if #available(iOS 18.0, macOS 15.0, *) {
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        } else {
            layer.flushAndRemoveImage()
        }
    }
}

// MARK: - SwiftUI Video Renderer

#if canImport(UIKit) && !os(macOS)
/// Renders decoded video frames on iOS via a zero-copy `AVSampleBufferDisplayLayer`.
struct VideoFrameRendererView: UIViewRepresentable {
    let pixelBuffer: CVPixelBuffer?
    var displayMode: DisplayMappingEngine.DisplayMode = .fitDisplay
    /// When provided, the view subscribes to the renderer's frame publisher and
    /// enqueues every decoded frame directly (bypassing SwiftUI's `@Published`
    /// coalescing) for the smoothest playback. Defaults to nil → simple
    /// pixelBuffer-driven path.
    var renderer: VideoRendererViewModel? = nil
    /// Optional system Picture-in-Picture owner. It attaches to this view's
    /// sample-buffer layer, so PiP reuses the live decode/presentation path.
    var pictureInPicture: RemotePictureInPictureController? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> VideoDisplayUIView {
        let view = VideoDisplayUIView()
        view.updateDisplayMode(displayMode)
        pictureInPicture?.attach(to: view.displayLayer)
        if let renderer {
            // Frames are published on the main actor; subscribe directly (no extra hop).
            context.coordinator.cancellable = renderer.framePublisher
                .sink { [weak view] buffer in view?.display(pixelBuffer: buffer) }
        }
        return view
    }

    func updateUIView(_ uiView: VideoDisplayUIView, context: Context) {
        uiView.updateDisplayMode(displayMode)
        pictureInPicture?.attach(to: uiView.displayLayer)
        // With a renderer wired, frames arrive via the publisher subscription; don't
        // also drive from the (coalesced) @Published value.
        if renderer == nil {
            uiView.display(pixelBuffer: pixelBuffer)
        }
    }

    static func dismantleUIView(_ uiView: VideoDisplayUIView, coordinator: Coordinator) {
        coordinator.cancellable?.cancel()
        uiView.display(pixelBuffer: nil)
    }

    final class Coordinator {
        var cancellable: AnyCancellable?
    }
}

/// UIView backed by `AVSampleBufferDisplayLayer` for zero-copy, HDR-capable GPU
/// presentation of decoded frames (no CIImage/CGImage readback).
final class VideoDisplayUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    fileprivate var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private var formatDescription: CMVideoFormatDescription?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func updateDisplayMode(_ mode: DisplayMappingEngine.DisplayMode) {
        let gravity: AVLayerVideoGravity = mode == .fillScreen ? .resizeAspectFill : .resizeAspect
        guard displayLayer.videoGravity != gravity else { return }
        displayLayer.videoGravity = gravity
    }

    func display(pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer else {
            VideoLayerPresenter.clear(displayLayer)
            formatDescription = nil
            return
        }
        VideoLayerPresenter.present(pixelBuffer, in: displayLayer, formatDescription: &formatDescription)
    }
}

/// Owns the system Picture-in-Picture session for a live remote display.
/// PiP is intentionally view-only: input continues only while Vamp Control is
/// foreground, and the system floating window receives no remote-control hooks.
@MainActor
final class RemotePictureInPictureController: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false

    private weak var attachedLayer: AVSampleBufferDisplayLayer?
    private var controller: AVPictureInPictureController?

    func attach(to layer: AVSampleBufferDisplayLayer) {
        guard attachedLayer !== layer || controller == nil else {
            refreshPossibility()
            return
        }
        // Do not replace the content source while the system owns an active PiP
        // transition. SwiftUI may rebuild the onscreen renderer during rotation.
        guard controller?.isPictureInPictureActive != true else { return }
        attachedLayer = layer
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let next = AVPictureInPictureController(contentSource: source)
        next.delegate = self
        next.canStartPictureInPictureAutomaticallyFromInline = true
        controller = next
        refreshPossibility()
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if AVPictureInPictureController.isPictureInPictureSupported() {
            controller.startPictureInPicture()
        }
        refreshPossibility()
    }

    private func refreshPossibility() {
        isPossible = AVPictureInPictureController.isPictureInPictureSupported()
            && (controller?.isPictureInPicturePossible ?? false)
    }
}

extension RemotePictureInPictureController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        refreshPossibility()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
        refreshPossibility()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        isActive = false
        refreshPossibility()
    }
}

extension RemotePictureInPictureController: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool { false }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion: @escaping () -> Void
    ) { completion() }
}
#endif

#if os(macOS)
/// macOS counterpart using NSViewRepresentable.
struct VideoFrameRendererViewMac: NSViewRepresentable {
    let pixelBuffer: CVPixelBuffer?

    func makeNSView(context: Context) -> VideoDisplayNSView {
        VideoDisplayNSView()
    }

    func updateNSView(_ nsView: VideoDisplayNSView, context: Context) {
        nsView.display(pixelBuffer: pixelBuffer)
    }
}

/// NSView whose backing layer is an `AVSampleBufferDisplayLayer` — zero-copy,
/// HDR-capable presentation. (Replaces a per-frame `CIImage → createCGImage`
/// GPU→CPU readback that could never display HDR and was the heaviest path.)
final class VideoDisplayNSView: NSView {
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private var formatDescription: CMVideoFormatDescription?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { AVSampleBufferDisplayLayer() }

    func display(pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer else {
            VideoLayerPresenter.clear(displayLayer)
            formatDescription = nil
            return
        }
        VideoLayerPresenter.present(pixelBuffer, in: displayLayer, formatDescription: &formatDescription)
    }
}
#endif

// MARK: - Multi-display demux (Tier 4a, client)

/// Drives the additional displays the host streams in parallel. The primary display keeps
/// the screen's existing renderer (we just pin its filter to wire ID 0 while multi is on);
/// each secondary (wire ID 1, 2, …) gets its own `VideoRendererViewModel` that filters the
/// shared frame stream to its display, so all displays decode at once (live thumbnails,
/// instant focus). The screen owns this as a `@StateObject`.
@MainActor
final class MultiDisplayRenderer: ObservableObject {
    /// The non-focused displays, shown as thumbnails (one renderer each).
    @Published private(set) var secondaryWireIDs: [UInt8] = []
    /// The display shown on the main surface; the primary renderer is filtered to it.
    @Published private(set) var focusedWireID: UInt8 = 0
    private var activeWireIDs: [UInt8] = [0]
    private var renderers: [UInt8: VideoRendererViewModel] = [:]
    private let webRTCSessionManager: any WebRTCSessionManaging
    private weak var primary: VideoRendererViewModel?
    /// Lets a secondary renderer ask the host for a fresh keyframe. Without this, a secondary
    /// that missed the host's initial IDR (it starts streaming after the renderer subscribes)
    /// has no way to request parameter sets and stays stuck on "waiting for frame" forever.
    /// The view points this at the session's keyframe-refresh (host force-keyframes every
    /// streamer, primary + secondaries).
    var onNeedsKeyframe: (() -> Void)?

    init(webRTCSessionManager: any WebRTCSessionManaging, primary: VideoRendererViewModel) {
        self.webRTCSessionManager = webRTCSessionManager
        self.primary = primary
    }

    func renderer(for wireID: UInt8) -> VideoRendererViewModel? { renderers[wireID] }

    /// `count` = total streamed displays incl. the primary (wire IDs 0..<count). 1 (or 0)
    /// restores single-display (primary decodes everything).
    func setActive(count: Int) {
        activeWireIDs = count > 1 ? (0..<count).map { UInt8($0) } : [0]
        if !activeWireIDs.contains(focusedWireID) { focusedWireID = 0 }
        reconfigure()
    }

    /// Move the main surface to `wireID` (instant — every active display decodes continuously;
    /// the caller nudges a keyframe so the newly-focused stream refreshes promptly).
    func focus(_ wireID: UInt8) {
        guard activeWireIDs.contains(wireID), wireID != focusedWireID else { return }
        focusedWireID = wireID
        reconfigure()
    }

    private func reconfigure() {
        let multi = activeWireIDs.count > 1
        // The main surface renders the primary renderer; pin it to the focused display.
        primary?.displayIDFilter = multi ? focusedWireID : nil
        let secondaries = activeWireIDs.filter { $0 != focusedWireID }
        for (id, vm) in renderers where !secondaries.contains(id) {
            vm.stopReceiving()
            renderers[id] = nil
        }
        for id in secondaries where renderers[id] == nil {
            let vm = VideoRendererViewModel(webRTCSessionManager: webRTCSessionManager)
            vm.displayIDFilter = id
            // Route this secondary's keyframe recovery up to the host (see `onNeedsKeyframe`).
            vm.onNeedsKeyframe = { [weak self] in self?.onNeedsKeyframe?() }
            vm.startReceiving()
            renderers[id] = vm
        }
        secondaryWireIDs = secondaries
        // A just-activated secondary likely started after the host's initial IDR went out, so
        // nudge one now rather than waiting ~2s for the decode watchdog to notice the stall.
        if !secondaries.isEmpty { onNeedsKeyframe?() }
    }

    func stopAll() {
        renderers.values.forEach { $0.stopReceiving() }
        renderers.removeAll()
        secondaryWireIDs = []
        activeWireIDs = [0]
        focusedWireID = 0
        primary?.displayIDFilter = nil
    }
}

/// One secondary display's live thumbnail surface (zero-copy, reuses the platform video view).
struct DisplayThumbnailView: View {
    @ObservedObject var renderer: VideoRendererViewModel

    var body: some View {
        ZStack {
            #if canImport(UIKit) && !os(macOS)
            VideoFrameRendererView(pixelBuffer: renderer.latestPixelBuffer, renderer: renderer)
            #elseif os(macOS)
            VideoFrameRendererViewMac(pixelBuffer: renderer.latestPixelBuffer)
            #endif
            // No frames yet → this display isn't arriving (host not streaming it, e.g. an older
            // host without multi-display support, or it's still starting). Show that rather than
            // a confusing black box.
            if renderer.latestPixelBuffer == nil {
                VStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("waiting for display…")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

/// Horizontal strip of live thumbnails for every additional streamed display. Tapping one
/// invokes `onFocus(wireID)` so the screen can promote it (e.g. via a display switch).
struct MultiDisplayThumbnailStrip: View {
    @ObservedObject var multi: MultiDisplayRenderer
    var onFocus: ((UInt8) -> Void)? = nil

    var body: some View {
        if !multi.secondaryWireIDs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(multi.secondaryWireIDs, id: \.self) { wireID in
                        if let vm = multi.renderer(for: wireID) {
                            DisplayThumbnailView(renderer: vm)
                                .frame(width: 168, height: 104)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.25))
                                )
                                .onTapGesture { onFocus?(wireID) }
                        }
                    }
                }
                .padding(10)
            }
            .background(.black.opacity(0.35))
        }
    }
}
