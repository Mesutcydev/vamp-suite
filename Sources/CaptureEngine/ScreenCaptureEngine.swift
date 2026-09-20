#if os(macOS)
import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit
import SharedModels
import os

public enum CaptureEngineError: Error, LocalizedError, Sendable {
    case displayNotFound(String)
    case windowNotFound(String)
    case permissionDenied
    case configurationFailed(String)
    case alreadyCapturing
    case streamFailed(String)

    public var errorDescription: String? {
        switch self {
        case .displayNotFound(let id):
            return "Display '\(id)' not found in shareable content."
        case .windowNotFound(let id):
            return "Window '\(id)' not found in shareable content (it may have closed)."
        case .permissionDenied:
            return "Screen recording permission was denied."
        case .configurationFailed(let msg):
            return "Capture configuration failed: \(msg)"
        case .alreadyCapturing:
            return "Capture is already running."
        case .streamFailed(let msg):
            return "Stream error: \(msg)"
        }
    }
}

public final class ScreenCaptureEngine: NSObject, CaptureEngineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SCStream?
    private var streamConfiguration: SCStreamConfiguration?
    private var streamOutput: StreamOutputHandler?
    private var _captureState: CaptureState = .stopped
    private var _diagnostics = CaptureDiagnostics()
    private weak var _frameReceiver: (any CaptureFrameReceiver)?
    private weak var _audioReceiver: (any CaptureAudioReceiver)?
    private var _showsCursor = true
    private var stateContinuations: [UUID: AsyncStream<CaptureState>.Continuation] = [:]
    // Ordered audio conduit. Spawning a fresh `Task { await receiver.didCapture... }` per
    // buffer didn't guarantee actor-entry order, so audio frameID/sampleTime could be
    // assigned out of sequence. Instead we yield buffers into one AsyncStream drained by a
    // single long-lived consumer Task that awaits the receiver serially — preserving order.
    private var audioConduitContinuation: AsyncStream<CMSampleBuffer>.Continuation?
    private var audioConsumerTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.remotedesktop.capture", category: "ScreenCaptureEngine")

    public override init() {
        super.init()
    }

    // MARK: - CaptureEngineProtocol

    public var isCapturing: Bool {
        withLock { _captureState == .running }
    }

    public var captureState: CaptureState {
        withLock { _captureState }
    }

    public var diagnostics: CaptureDiagnostics {
        withLock { _diagnostics }
    }

    public func setFrameReceiver(_ receiver: (any CaptureFrameReceiver)?) {
        lock.lock()
        _frameReceiver = receiver
        lock.unlock()
    }

    public func setAudioReceiver(_ receiver: (any CaptureAudioReceiver)?) {
        lock.lock()
        _audioReceiver = receiver
        lock.unlock()
        // Clearing the receiver also retires the ordered conduit; it will be lazily
        // recreated on the next audio buffer if a new receiver is installed.
        if receiver == nil {
            teardownAudioConduit()
        }
    }

    public func setShowsCursor(_ showsCursor: Bool) {
        withLock { _showsCursor = showsCursor }
    }

    public func stateChanges() -> AsyncStream<CaptureState> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let id = UUID()
            lock.lock()
            stateContinuations[id] = continuation
            let current = _captureState
            lock.unlock()
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.stateContinuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    public func startCapture(displayID: String, qualityPreset: StreamQualityPreset, allowsHighResolution: Bool) async throws {
        try await startCapture(
            displayID: displayID,
            qualityPreset: qualityPreset,
            allowsHighResolution: allowsHighResolution,
            dynamicRange: .sdr
        )
    }

    public func startCapture(
        displayID: String,
        qualityPreset: StreamQualityPreset,
        allowsHighResolution: Bool,
        dynamicRange: StreamDynamicRange
    ) async throws {
        let currentState = withLock { _captureState }
        guard currentState == .stopped || currentState == .failed || currentState == .permissionBlocked else {
            throw CaptureEngineError.alreadyCapturing
        }

        transitionState(.starting)

        // A sleeping display yields no capture frames (so waitForFirstFrame times out and the
        // failure gets mislabeled as a permission error). Common on a headless/idle Mac mini, and
        // especially once "Keep Mac Awake & Reachable" is on — it keeps the system up but lets the
        // display sleep. Wake the display before capturing so the first frame actually flows.
        wakeDisplay()

        updateCaptureRequestDiagnostics(displayID: displayID, qualityPreset: qualityPreset)

        do {
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                let nsError = error as NSError
                // -3801: explicit TCC denial. Other SCK errors (e.g. -3852 on macOS 14+
                // sandboxed builds where the permission dialog was dismissed) also indicate
                // the app cannot capture — treat them all as permission denied.
                if nsError.domain == "com.apple.ScreenCaptureKit" {
                    transitionState(.permissionBlocked)
                    throw CaptureEngineError.permissionDenied
                }
                throw error
            }

            // An empty displays list means ScreenCaptureKit returned successfully but
            // the sandbox or TCC state prevented access to any display content.  This
            // happens on App Store builds when screen-recording permission has not been
            // granted for the current binary (e.g. after an update with a new signing
            // identity).  Treat it as a permission failure rather than letting the
            // pipeline start and then time out with no frames.
            guard !content.displays.isEmpty else {
                transitionState(.permissionBlocked)
                throw CaptureEngineError.permissionDenied
            }

            guard let scDisplay = content.displays.first(where: { String($0.displayID) == displayID }) else {
                transitionState(.failed)
                throw CaptureEngineError.displayNotFound(displayID)
            }

            var config = CaptureConfiguration.forPreset(
                qualityPreset,
                displayWidth: scDisplay.width,
                displayHeight: scDisplay.height,
                scaleFactor: Double(scDisplay.width) / max(1, Double(scDisplay.frame.width)),
                allowsHighResolution: allowsHighResolution
            )
            config.showsCursor = withLock { _showsCursor }

            logger.info("Starting capture: \(config.summaryDescription, privacy: .public)")

            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            try await startStream(
                filter: filter,
                config: config,
                streamID: displayID,
                dynamicRange: dynamicRange,
                capturesAudio: true
            )
            logger.info("Capture started for display \(displayID, privacy: .public)")

        } catch let error as CaptureEngineError {
            throw error
        } catch {
            transitionState(.failed)
            logger.error("Capture start failed: \(error.localizedDescription, privacy: .public)")
            throw CaptureEngineError.streamFailed(error.localizedDescription)
        }
    }

    /// Capture a single application window instead of a whole display. The entire
    /// downstream pipeline (encode → transport → decode → input) is identical; only the
    /// `SCContentFilter` and the capture surface size differ. Requires macOS 14 for
    /// `SCContentFilter.contentRect`/`pointPixelScale`, which size the Retina surface
    /// correctly without hand-rolled backing-scale math.
    public func startCapture(windowID: String, qualityPreset: StreamQualityPreset, allowsHighResolution: Bool) async throws {
        let currentState = withLock { _captureState }
        guard currentState == .stopped || currentState == .failed || currentState == .permissionBlocked else {
            throw CaptureEngineError.alreadyCapturing
        }
        guard #available(macOS 14.0, *) else {
            throw CaptureEngineError.configurationFailed("Window streaming requires macOS 14 or newer.")
        }

        transitionState(.starting)
        wakeDisplay()
        updateCaptureRequestDiagnostics(displayID: windowID, qualityPreset: qualityPreset)

        do {
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                let nsError = error as NSError
                if nsError.domain == "com.apple.ScreenCaptureKit" {
                    transitionState(.permissionBlocked)
                    throw CaptureEngineError.permissionDenied
                }
                throw error
            }

            // Only on-screen windows are streamable. A minimized/hidden window won't be
            // here, so the host must activate it first (see StreamTargetSwitch handling).
            guard let scWindow = content.windows.first(where: { String($0.windowID) == windowID }) else {
                transitionState(.failed)
                throw CaptureEngineError.windowNotFound(windowID)
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let pixelScale = CGFloat(filter.pointPixelScale)
            let contentRect = filter.contentRect
            let pixelWidth = Int((contentRect.width * pixelScale).rounded())
            let pixelHeight = Int((contentRect.height * pixelScale).rounded())
            guard pixelWidth > 0, pixelHeight > 0 else {
                transitionState(.failed)
                throw CaptureEngineError.configurationFailed("Window has zero size.")
            }

            var config = CaptureConfiguration.forPreset(
                qualityPreset,
                displayWidth: pixelWidth,
                displayHeight: pixelHeight,
                scaleFactor: Double(pixelScale),
                allowsHighResolution: allowsHighResolution,
                minLongEdge: StreamScaling.windowPerformanceMinLongEdge
            )
            config.showsCursor = withLock { _showsCursor }
            logger.info("Starting window capture: \(config.summaryDescription, privacy: .public)")

            // A window stream is video-only for now.
            // ponytail: add per-app audio once the window video path is proven.
            try await startStream(
                filter: filter,
                config: config,
                streamID: windowID,
                dynamicRange: .sdr,
                capturesAudio: false
            )
            logger.info("Capture started for window \(windowID, privacy: .public)")
        } catch let error as CaptureEngineError {
            throw error
        } catch {
            transitionState(.failed)
            logger.error("Window capture start failed: \(error.localizedDescription, privacy: .public)")
            throw CaptureEngineError.streamFailed(error.localizedDescription)
        }
    }

    /// Shared SCStream construction for both display and window capture. Given an
    /// already-built content filter and target `CaptureConfiguration`, wires the stream
    /// outputs and starts capture. Keeping one path here means display and window
    /// streaming can never drift on color/pixel-format/queue handling.
    private func startStream(
        filter: SCContentFilter,
        config: CaptureConfiguration,
        streamID: String,
        dynamicRange: StreamDynamicRange,
        capturesAudio: Bool
    ) async throws {
        let streamConfig: SCStreamConfiguration
        if dynamicRange == .hdr10 {
            if #available(macOS 15.0, *) {
                streamConfig = SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay)
            } else {
                throw CaptureEngineError.configurationFailed("HDR capture requires macOS 15 or newer.")
            }
        } else {
            streamConfig = SCStreamConfiguration()
        }
        streamConfig.width = config.width
        streamConfig.height = config.height
        streamConfig.minimumFrameInterval = config.minimumFrameInterval
        streamConfig.queueDepth = config.queueDepth
        if dynamicRange == .sdr {
            streamConfig.pixelFormat = config.pixelFormat
            // Normalize the SDR wire path so a wide-gamut display profile does
            // not arrive at the encoder as P3/HDR-ish data that the client then
            // presents as BT.709. This keeps dark terminal UI contrast intact.
            streamConfig.colorSpaceName = CGColorSpace.sRGB
            streamConfig.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
        if dynamicRange == .hdr10 {
            // The HDR preset doesn't pin a pixel format, but the encoder/decoder are
            // hard-coded to 10-bit. Without this, capture could hand back 8-bit buffers
            // and the three stages would disagree on bit depth. Force a 10-bit biplanar
            // format so capture/encode/decode all agree.
            streamConfig.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        streamConfig.showsCursor = config.showsCursor

        if #available(macOS 13.0, *) {
            streamConfig.capturesAudio = capturesAudio
        }

        let handler = StreamOutputHandler(engine: self, displayID: streamID)
        let scStream = SCStream(filter: filter, configuration: streamConfig, delegate: handler)
        try scStream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        if #available(macOS 13.0, *), capturesAudio {
            try scStream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        }

        installStream(scStream, handler: handler)
        lock.withLock { streamConfiguration = streamConfig }

        try await scStream.startCapture()
        transitionState(.running)
    }

    public func stopCapture() async {
        let currentStream = takeCurrentStream()
        // Stop the audio conduit so the consumer Task exits and no stale buffers linger.
        teardownAudioConduit()

        if let currentStream {
            do {
                try await currentStream.stopCapture()
            } catch {
                logger.warning("Stop capture error (non-fatal): \(error.localizedDescription, privacy: .public)")
            }
        }

        transitionState(.stopped)
        logger.info("Capture stopped")
    }

    public func updateFrameRateLimit(_ framesPerSecond: Int) async throws {
        guard framesPerSecond > 0 else {
            throw CaptureEngineError.configurationFailed("Frame rate must be positive.")
        }
        let snapshot = lock.withLock { (stream, streamConfiguration) }
        guard let activeStream = snapshot.0, let configuration = snapshot.1 else {
            throw CaptureEngineError.configurationFailed("No active stream to reconfigure.")
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        do {
            try await activeStream.updateConfiguration(configuration)
            logger.info("Capture frame-rate limit updated to \(framesPerSecond) fps")
        } catch {
            throw CaptureEngineError.configurationFailed(error.localizedDescription)
        }
    }

    // MARK: - Internal Callbacks

    func handleFrame(_ sampleBuffer: CMSampleBuffer, displayID: String) {
        lock.lock()
        _diagnostics.capturedFrames += 1
        _diagnostics.lastFrameTimestamp = Date()
        let receiver = _frameReceiver
        lock.unlock()

        receiver?.didCaptureFrame(sampleBuffer, displayID: displayID)
    }

    func handleAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        guard _audioReceiver != nil else {
            lock.unlock()
            return
        }
        // Lazily start the ordered conduit on the first buffer while we have a receiver.
        if audioConduitContinuation == nil {
            startAudioConduitLocked()
        }
        let continuation = audioConduitContinuation
        lock.unlock()
        // Yield into the serial stream; the single consumer awaits the receiver in order.
        continuation?.yield(sampleBuffer)
    }

    /// Create the ordered audio stream + single consumer Task. Must be called with `lock` held.
    private func startAudioConduitLocked() {
        audioConsumerTask?.cancel()
        let (stream, continuation) = AsyncStream<CMSampleBuffer>.makeStream(bufferingPolicy: .unbounded)
        audioConduitContinuation = continuation
        audioConsumerTask = Task { [weak self] in
            for await buffer in stream {
                guard let self else { break }
                // Read the current receiver per buffer so a mid-session swap is honoured;
                // awaiting here serialises delivery and keeps frameID/sampleTime ordered.
                let receiver = self.withLock { self._audioReceiver }
                guard let receiver else { continue }
                await receiver.didCaptureAudioBuffer(buffer)
            }
        }
    }

    /// Tear down the audio conduit (finish the stream, cancel the consumer). Safe to call
    /// when none is active. Acquires `lock` internally.
    private func teardownAudioConduit() {
        lock.lock()
        let continuation = audioConduitContinuation
        let task = audioConsumerTask
        audioConduitContinuation = nil
        audioConsumerTask = nil
        lock.unlock()
        continuation?.finish()
        task?.cancel()
    }

    func handleDroppedFrame() {
        lock.lock()
        _diagnostics.droppedFrames += 1
        lock.unlock()
    }

    func handleStreamError(_ error: Error) {
        logger.error("Stream error: \(error.localizedDescription, privacy: .public)")
        transitionState(.failed)

        lock.lock()
        _diagnostics.streamRestarts += 1
        lock.unlock()
    }

    // MARK: - Private

    private func transitionState(_ newState: CaptureState) {
        lock.lock()
        _captureState = newState
        let continuations = Array(stateContinuations.values)
        lock.unlock()
        continuations.forEach { $0.yield(newState) }
    }

    /// Wake a sleeping display so ScreenCaptureKit can produce frames. Declaring local user activity
    /// is the documented way to wake the display + reset the idle timer; the transient assertion id
    /// isn't retained (it's a one-shot nudge, not a held assertion).
    private func wakeDisplay() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Vamp capture starting" as CFString, kIOPMUserActiveLocal, &id)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func updateCaptureRequestDiagnostics(displayID: String, qualityPreset: StreamQualityPreset) {
        lock.lock()
        _diagnostics.currentDisplayID = displayID
        _diagnostics.qualityPreset = qualityPreset
        lock.unlock()
    }

    private func installStream(_ stream: SCStream, handler: StreamOutputHandler) {
        lock.lock()
        self.stream = stream
        self.streamOutput = handler
        lock.unlock()
    }

    private func takeCurrentStream() -> SCStream? {
        lock.lock()
        let existingStream = stream
        stream = nil
        streamOutput = nil
        streamConfiguration = nil
        lock.unlock()
        return existingStream
    }
}

// MARK: - Stream Output Handler

private final class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private weak var engine: ScreenCaptureEngine?
    private let displayID: String

    init(engine: ScreenCaptureEngine, displayID: String) {
        self.engine = engine
        self.displayID = displayID
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if #available(macOS 13.0, *), type == .audio {
            guard sampleBuffer.isValid else { return }
            engine?.handleAudioBuffer(sampleBuffer)
            return
        }

        guard type == .screen else { return }
        guard sampleBuffer.isValid else {
            engine?.handleDroppedFrame()
            return
        }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else {
            engine?.handleDroppedFrame()
            return
        }

        if status == .complete {
            engine?.handleFrame(sampleBuffer, displayID: displayID)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        engine?.handleStreamError(error)
    }
}
#endif
