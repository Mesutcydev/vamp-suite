#if os(macOS)
import Foundation
import SharedModels

public struct CaptureConfiguration: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var scaleFactor: Double
    public var minimumFrameInterval: CMTime
    public var queueDepth: Int
    public var pixelFormat: OSType
    public var showsCursor: Bool
    public var presetsUsed: StreamQualityPreset

    public init(
        width: Int,
        height: Int,
        scaleFactor: Double,
        minimumFrameInterval: CMTime,
        queueDepth: Int,
        pixelFormat: OSType,
        showsCursor: Bool,
        presetsUsed: StreamQualityPreset
    ) {
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
        self.minimumFrameInterval = minimumFrameInterval
        self.queueDepth = queueDepth
        self.pixelFormat = pixelFormat
        self.showsCursor = showsCursor
        self.presetsUsed = presetsUsed
    }
}

import CoreMedia

extension CaptureConfiguration {
    public static func forPreset(
        _ preset: StreamQualityPreset,
        displayWidth: Int,
        displayHeight: Int,
        scaleFactor: Double,
        allowsHighResolution: Bool,
        minLongEdge: Int = 0
    ) -> CaptureConfiguration {
        // Delegate to the shared scaler so capture dimensions always match the encoder's.
        let scaled = StreamScaling.scaledDimensions(
            preset: preset,
            nativeWidth: displayWidth,
            nativeHeight: displayHeight,
            allowsHighResolution: allowsHighResolution,
            minLongEdge: minLongEdge
        )
        // Derive the backing scale factor from the ratio the scaler applied.
        let scale = displayWidth > 0
            ? scaleFactor * Double(scaled.width) / Double(displayWidth)
            : scaleFactor
        return CaptureConfiguration(
            width: scaled.width,
            height: scaled.height,
            scaleFactor: scale,
            minimumFrameInterval: frameInterval(for: preset),
            queueDepth: queueDepth(),
            // Screen content is full-range RGB data. Keep the capture surface full-range
            // so dark UI pixels do not get lifted when the frame crosses the Y'CbCr
            // conversion and VideoToolbox encoder.
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            showsCursor: true,
            presetsUsed: preset
        )
    }

    public var summaryDescription: String {
        "\(width)×\(height) @\(Int(1.0 / minimumFrameInterval.seconds))fps, \(presetsUsed.rawValue), depth=\(queueDepth)"
    }

    // MARK: - Preset Tuning

    private static func frameInterval(for preset: StreamQualityPreset) -> CMTime {
        switch preset {
        case .performance:
            return CMTime(value: 1, timescale: 30)
        case .balanced:
            return CMTime(value: 1, timescale: 30)
        case .quality:
            return CMTime(value: 1, timescale: 60)
        case .ultra:
            return CMTime(value: 1, timescale: 60)
        }
    }

    private static func queueDepth() -> Int {
        // This is a live stream, not a recorder. A deep ScreenCaptureKit queue
        // preserves old frames and converts temporary encoder pressure into
        // permanent latency. Three surfaces are enough to absorb scheduling jitter
        // at every preset/frame rate — so depth is intentionally preset-independent
        // (the `preset` parameter was unused and has been dropped).
        3
    }
}
#endif
