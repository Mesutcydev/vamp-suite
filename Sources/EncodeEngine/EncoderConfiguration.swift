import Foundation
import SharedModels

// MARK: - Encoder Configuration

public struct EncoderConfiguration: Sendable, Hashable {
    public var codec: EncodedFrameCodec
    public var width: Int
    public var height: Int
    public var expectedFrameRate: Int
    public var averageBitrate: Int
    public var maxKeyframeInterval: Int
    public var realtime: Bool
    public var allowFrameReordering: Bool
    public var profileLevel: String
    public var dynamicRange: StreamDynamicRange

    public init(
        codec: EncodedFrameCodec,
        width: Int,
        height: Int,
        expectedFrameRate: Int,
        averageBitrate: Int,
        maxKeyframeInterval: Int,
        realtime: Bool,
        allowFrameReordering: Bool,
        profileLevel: String,
        dynamicRange: StreamDynamicRange = .sdr
    ) {
        self.codec = codec
        self.width = width
        self.height = height
        self.expectedFrameRate = expectedFrameRate
        self.averageBitrate = averageBitrate
        self.maxKeyframeInterval = maxKeyframeInterval
        self.realtime = realtime
        self.allowFrameReordering = allowFrameReordering
        self.profileLevel = profileLevel
        self.dynamicRange = dynamicRange
    }

    public var summaryDescription: String {
        "\(codec.rawValue.uppercased()) \(width)×\(height) @\(expectedFrameRate)fps, \(averageBitrate / 1_000)kbps, KF=\(maxKeyframeInterval)"
    }
}

// MARK: - Preset-Based Configuration Factory

extension EncoderConfiguration {
    public static func forPreset(
        _ preset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        width: Int,
        height: Int,
        dynamicRange: StreamDynamicRange = .sdr,
        minLongEdge: Int = 0
    ) -> EncoderConfiguration {
        // Mirror CaptureConfiguration dimension scaling so the VTCompressionSession
        // is always configured at the same resolution as the captured frames.
        let (encodedWidth, encodedHeight) = scaledDimensions(
            preset: preset, width: width, height: height, codec: codec, minLongEdge: minLongEdge)
        return EncoderConfiguration(
            codec: codec,
            width: encodedWidth,
            height: encodedHeight,
            expectedFrameRate: frameRate(for: preset),
            averageBitrate: bitrate(for: preset, width: encodedWidth, height: encodedHeight, codec: codec),
            maxKeyframeInterval: keyframeInterval(for: preset),
            realtime: true,
            allowFrameReordering: false,
            profileLevel: profileLevel(for: codec, preset: preset, dynamicRange: dynamicRange),
            dynamicRange: dynamicRange
        )
    }

    /// Returns the encode dimensions for a given preset and codec. Delegates to the
    /// shared `StreamScaling` so capture and encode always agree; HEVC unlocks the 4K
    /// cap for `balanced`/`quality` while H.264 stays at 1080p. `minLongEdge` must
    /// match the capture call site's floor or VideoToolbox rescales the mismatch.
    public static func scaledDimensions(
        preset: StreamQualityPreset,
        width: Int,
        height: Int,
        codec: EncodedFrameCodec,
        minLongEdge: Int = 0
    ) -> (Int, Int) {
        let dims = StreamScaling.scaledDimensions(
            preset: preset,
            nativeWidth: width,
            nativeHeight: height,
            allowsHighResolution: codec == .hevc,
            minLongEdge: minLongEdge
        )
        return (dims.width, dims.height)
    }

    // MARK: - Tuning Tables

    public static func frameRate(for preset: StreamQualityPreset) -> Int {
        switch preset {
        case .performance: return 30
        case .balanced:    return 30
        case .quality:     return 60
        case .ultra:       return 60
        }
    }

    public static func bitrate(
        for preset: StreamQualityPreset,
        width: Int,
        height: Int,
        codec: EncodedFrameCodec
    ) -> Int {
        // Standard target = width × height × fps × bits-per-pixel-per-frame.
        // (The previous formula divided by 30 instead of multiplying by fps, which
        // starved every non-ultra preset — e.g. 1080p balanced computed to ~207 kbps
        // and mushed badly on any motion.) These bpp values give visually-good
        // low-latency screen content; the adaptive bitrate controller trims them down
        // under real network congestion, so generous targets are safe.
        let pixelCount = Double(width * height)
        let fps = Double(frameRate(for: preset))
        let bitsPerPixel: Double
        let cap: Int
        switch preset {
        case .performance: bitsPerPixel = 0.06; cap = 8_000_000
        case .balanced:    bitsPerPixel = 0.12; cap = 24_000_000
        case .quality:     bitsPerPixel = 0.15; cap = 36_000_000
        case .ultra:       bitsPerPixel = 0.18; cap = 48_000_000
        }
        let codecMultiplier: Double = (codec == .hevc) ? 0.75 : 1.0
        let computed = Int(pixelCount * fps * bitsPerPixel * codecMultiplier)
        // Floor avoids starving tiny performance streams; cap keeps 5K/6K Ultra off
        // bitrates home Wi-Fi can't sustain (adaptive control handles the rest).
        return min(max(computed, 800_000), cap)
    }

    public static func keyframeInterval(for preset: StreamQualityPreset) -> Int {
        // ~1.5 s between keyframes (interval = fps × 1.5). On the unreliable/unordered
        // video channel a lost delta corrupts the picture until the next keyframe, so a
        // shorter GOP bounds that worst case (on top of on-demand decode-error recovery)
        // without the bandwidth cost of a very short interval.
        switch preset {
        case .performance: return 45   // 30 fps
        case .balanced:    return 45   // 30 fps
        case .quality:     return 90   // 60 fps
        case .ultra:       return 90   // 60 fps
        }
    }

    public static func profileLevel(
        for codec: EncodedFrameCodec,
        preset: StreamQualityPreset,
        dynamicRange: StreamDynamicRange = .sdr
    ) -> String {
        switch codec {
        case .h264:
            switch preset {
            case .performance: return "H264_Baseline_AutoLevel"
            case .balanced:    return "H264_Main_AutoLevel"
            case .quality:     return "H264_High_AutoLevel"
            case .ultra:       return "H264_High_AutoLevel"
            }
        case .hevc:
            return dynamicRange == .hdr10
                ? "HEVC_Main10_AutoLevel"
                : "HEVC_Main_AutoLevel"
        }
    }
}

public struct AdaptiveStreamingDecision: Sendable, Equatable {
    public var targetBitrate: Int?
    public var frameRateLimit: Int?

    public init(targetBitrate: Int? = nil, frameRateLimit: Int? = nil) {
        self.targetBitrate = targetBitrate
        self.frameRateLimit = frameRateLimit
    }

    public var isEmpty: Bool {
        targetBitrate == nil && frameRateLimit == nil
    }
}

/// Queue-pressure controller with asymmetric decrease/recovery timing.
public struct AdaptiveStreamingController: Sendable {
    public private(set) var currentBitrate: Int
    public private(set) var currentFrameRate: Int

    private let maximumBitrate: Int
    private let minimumBitrate: Int
    private let preferredFrameRate: Int
    private var smoothedBufferedBytes: Double = 0
    private var congestedSamples = 0
    private var quietSamples = 0
    /// Independent quiet-sample counter for frame-rate recovery. `quietSamples` is
    /// consumed by the bitrate-recovery branch (which fires at >= 12), so on a healthy
    /// link it never reaches the >= 20 the FPS-restore branch needs and frame rate stays
    /// pinned after a downgrade. This counter decays only on non-quiet samples, so it can
    /// actually accumulate to 20 independently of bitrate bumps.
    private var quietForFrameRate = 0
    private var severeSamples = 0
    private var lastBitrateChangeAt: TimeInterval = -.infinity
    private var lastFrameRateChangeAt: TimeInterval = -.infinity

    public init(initialBitrate: Int, preferredFrameRate: Int) {
        let sanitizedBitrate = max(300_000, initialBitrate)
        self.currentBitrate = sanitizedBitrate
        self.maximumBitrate = sanitizedBitrate
        self.minimumBitrate = max(300_000, min(2_000_000, sanitizedBitrate / 5))
        self.preferredFrameRate = max(15, preferredFrameRate)
        self.currentFrameRate = max(15, preferredFrameRate)
    }

    public mutating func observe(
        bufferedBytes: UInt64,
        lossPermille: Int = 0,
        now: TimeInterval
    ) -> AdaptiveStreamingDecision {
        let sample = Double(bufferedBytes)
        smoothedBufferedBytes = smoothedBufferedBytes == 0
            ? sample
            : (smoothedBufferedBytes * 0.8) + (sample * 0.2)

        // Normalize the buffer to queue *latency* (seconds of data) instead of raw
        // bytes, so the same thresholds mean the same thing regardless of bitrate or
        // transport (LAN vs relay both report bytes, but a given byte count is very
        // different congestion at 1 Mbps vs 30 Mbps). A small absolute floor keeps a
        // single keyframe burst from reading as congestion on a healthy link.
        let bytesPerSecond = max(1.0, Double(currentBitrate) / 8.0)
        let queueSeconds = smoothedBufferedBytes / bytesPerSecond
        let hasMeaningfulBacklog = smoothedBufferedBytes > 200_000
        // Receiver-reported downlink loss is the better congestion signal on lossy links
        // (Wi-Fi/relay), where the send queue may look fine while frames are dropping.
        // Fold it into the same response: ≥3‰ → congested, ≥100‰ → severe (FPS cut). Don't
        // ramp bitrate back up while loss is non-trivial.
        let lossy = lossPermille >= 30
        let severeLoss = lossPermille >= 100
        let isCongested = (queueSeconds > 0.30 && hasMeaningfulBacklog) || lossy
        // Quiet is judged on the *instantaneous* queue, not the smoothed one: the EMA
        // lingers for ~10 samples after a keyframe burst has fully drained, which read
        // as "not quiet" long after the link was idle again. Congested/severe keep the
        // smoothed value (anti-flap); quiet just needs "is the queue empty right now".
        // The small absolute floor mirrors hasMeaningfulBacklog for low bitrates.
        let instantQueueSeconds = sample / bytesPerSecond
        let isQuiet = (instantQueueSeconds < 0.08 || sample < 100_000) && lossPermille < 15
        let isSevere = (queueSeconds > 0.75 && hasMeaningfulBacklog) || severeLoss

        congestedSamples = isCongested ? congestedSamples + 1 : 0
        // Quiet counters decay instead of hard-resetting. On a bandwidth-constrained path
        // (Tailscale/relay) the keyframe burst every GOP (~1.5 s) briefly spikes the queue;
        // a hard reset meant "12 consecutive quiet samples" never happened, so bitrate
        // ratcheted down to minimum and stayed there forever. Decay lets recovery
        // accumulate through periodic bursts while sustained congestion still stalls it.
        quietSamples = isQuiet ? quietSamples + 1 : max(0, quietSamples - 2)
        quietForFrameRate = isQuiet ? quietForFrameRate + 1 : max(0, quietForFrameRate - 2)
        severeSamples = isSevere ? severeSamples + 1 : 0

        var decision = AdaptiveStreamingDecision()
        if congestedSamples >= 3, now - lastBitrateChangeAt >= 1.0 {
            let reduced = max(
                minimumBitrate,
                Int((Double(currentBitrate) * 0.82).rounded())
            )
            if reduced < currentBitrate {
                currentBitrate = reduced
                decision.targetBitrate = reduced
            }
            congestedSamples = 0
            quietSamples = 0
            lastBitrateChangeAt = now
        } else if quietSamples >= 12,
                  currentBitrate < maximumBitrate,
                  now - lastBitrateChangeAt >= 1.5 {
            let increased = min(
                maximumBitrate,
                max(currentBitrate + 250_000, Int(Double(currentBitrate) * 1.10))
            )
            currentBitrate = increased
            decision.targetBitrate = increased
            // Keep half the quiet credit so a sustained-quiet link ramps every ~1.5 s
            // instead of re-earning 12 samples (3 s) from scratch per step. Climbing
            // 2 → 24 Mbps still takes ~40 s of clean link — cuts remain 5× faster.
            quietSamples = 6
            lastBitrateChangeAt = now
        }

        if preferredFrameRate > 30,
           severeSamples >= 2,
           currentFrameRate > 30,
           now - lastFrameRateChangeAt >= 2.0 {
            currentFrameRate = 30
            decision.frameRateLimit = 30
            severeSamples = 0
            lastFrameRateChangeAt = now
        } else if currentFrameRate < preferredFrameRate,
                  quietForFrameRate >= 20,
                  now - lastFrameRateChangeAt >= 5.0 {
            currentFrameRate = preferredFrameRate
            decision.frameRateLimit = preferredFrameRate
            quietForFrameRate = 0
            lastFrameRateChangeAt = now
        }

        return decision
    }
}
