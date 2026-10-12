@preconcurrency import CoreMedia
import Foundation
import SharedModels

// MARK: - Capture State

public enum CaptureState: String, Sendable, Hashable {
    case stopped
    case starting
    case running
    case failed
    case permissionBlocked
}

// MARK: - Capture Diagnostics

public struct CaptureDiagnostics: Sendable, Hashable {
    public var capturedFrames: UInt64
    public var droppedFrames: UInt64
    public var lastFrameTimestamp: Date?
    public var streamRestarts: Int
    public var currentDisplayID: String?
    public var qualityPreset: StreamQualityPreset?

    public init(
        capturedFrames: UInt64 = 0,
        droppedFrames: UInt64 = 0,
        lastFrameTimestamp: Date? = nil,
        streamRestarts: Int = 0,
        currentDisplayID: String? = nil,
        qualityPreset: StreamQualityPreset? = nil
    ) {
        self.capturedFrames = capturedFrames
        self.droppedFrames = droppedFrames
        self.lastFrameTimestamp = lastFrameTimestamp
        self.streamRestarts = streamRestarts
        self.currentDisplayID = currentDisplayID
        self.qualityPreset = qualityPreset
    }
}

// MARK: - Frame Output

public protocol CaptureFrameReceiver: AnyObject, Sendable {
    func didCaptureFrame(_ sampleBuffer: CMSampleBuffer, displayID: String)
}

// MARK: - Audio Output

public protocol CaptureAudioReceiver: AnyObject, Sendable {
    func didCaptureAudioBuffer(_ sampleBuffer: CMSampleBuffer) async
}

// MARK: - Capture Engine Protocol

public protocol CaptureEngineProtocol {
    var isCapturing: Bool { get }
    var captureState: CaptureState { get }
    var diagnostics: CaptureDiagnostics { get }

    /// - Parameter allowsHighResolution: when `true`, `balanced`/`quality` capture at up
    ///   to 4K instead of 1080p (HEVC path). Must match the encoder's configured codec
    ///   so capture and encode dimensions stay in lockstep.
    func startCapture(displayID: String, qualityPreset: StreamQualityPreset, allowsHighResolution: Bool) async throws
    func startCapture(
        displayID: String,
        qualityPreset: StreamQualityPreset,
        allowsHighResolution: Bool,
        dynamicRange: StreamDynamicRange
    ) async throws
    /// Capture a single application window (App Streaming). The downstream pipeline is
    /// identical to display capture; only the content filter and surface size differ.
    /// Engines that cannot do window capture get the throwing default below.
    func startCapture(windowID: String, qualityPreset: StreamQualityPreset, allowsHighResolution: Bool) async throws
    /// Reconfigures the active SCStream frame interval without restarting capture.
    func updateFrameRateLimit(_ framesPerSecond: Int) async throws
    /// Controls whether subsequent capture sessions include the host cursor.
    func setShowsCursor(_ showsCursor: Bool)
    func stopCapture() async

    func setFrameReceiver(_ receiver: (any CaptureFrameReceiver)?)
    func setAudioReceiver(_ receiver: (any CaptureAudioReceiver)?)
    func stateChanges() -> AsyncStream<CaptureState>
}

public extension CaptureEngineProtocol {
    /// Convenience for callers that don't drive HEVC negotiation (host-local capture,
    /// recovery): keeps the standard 1080p cap for `balanced`/`quality`.
    func startCapture(displayID: String, qualityPreset: StreamQualityPreset) async throws {
        try await startCapture(displayID: displayID, qualityPreset: qualityPreset, allowsHighResolution: false)
    }

    func startCapture(
        displayID: String,
        qualityPreset: StreamQualityPreset,
        allowsHighResolution: Bool,
        dynamicRange: StreamDynamicRange
    ) async throws {
        try await startCapture(
            displayID: displayID,
            qualityPreset: qualityPreset,
            allowsHighResolution: allowsHighResolution
        )
    }

    func updateFrameRateLimit(_ framesPerSecond: Int) async throws {}

    func setShowsCursor(_ showsCursor: Bool) {}

    /// Default: window capture is unsupported. `ScreenCaptureEngine` overrides this.
    func startCapture(windowID: String, qualityPreset: StreamQualityPreset, allowsHighResolution: Bool) async throws {
        throw CaptureEngineUnsupported.windowCapture
    }
}

/// Cross-platform error for capture-engine capabilities a given engine does not provide.
/// (`CaptureEngineError` is macOS-only; this default lives in the platform-neutral protocol.)
public enum CaptureEngineUnsupported: Error, Sendable {
    case windowCapture
}

public protocol DisplayLayoutProviding {
    func currentDisplayLayout() async throws -> DisplayLayout
}

public protocol DisplayLayoutObserving: DisplayLayoutProviding {
    func layoutChanges() -> AsyncStream<DisplayLayout>
}
