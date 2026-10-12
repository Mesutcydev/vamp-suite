import XCTest
@testable import EncodeEngine
@testable import SharedModels

final class EncoderConfigurationTests: XCTestCase {

    // MARK: - Frame Rate

    func testFrameRateForPerformance() {
        XCTAssertEqual(EncoderConfiguration.frameRate(for: .performance), 30)
    }

    func testFrameRateForBalanced() {
        XCTAssertEqual(EncoderConfiguration.frameRate(for: .balanced), 30)
    }

    func testFrameRateForQuality() {
        XCTAssertEqual(EncoderConfiguration.frameRate(for: .quality), 60)
    }

    func testFrameRateForUltra() {
        XCTAssertEqual(EncoderConfiguration.frameRate(for: .ultra), 60)
    }

    // MARK: - Keyframe Interval

    func testKeyframeIntervalForPerformance() {
        XCTAssertEqual(EncoderConfiguration.keyframeInterval(for: .performance), 45)
    }

    func testKeyframeIntervalForBalanced() {
        XCTAssertEqual(EncoderConfiguration.keyframeInterval(for: .balanced), 45)
    }

    func testKeyframeIntervalForQuality() {
        XCTAssertEqual(EncoderConfiguration.keyframeInterval(for: .quality), 90)
    }

    func testKeyframeIntervalForUltra() {
        XCTAssertEqual(EncoderConfiguration.keyframeInterval(for: .ultra), 90)
    }

    // MARK: - Profile Level

    func testProfileLevelH264Performance() {
        XCTAssertEqual(EncoderConfiguration.profileLevel(for: .h264, preset: .performance), "H264_Baseline_AutoLevel")
    }

    func testProfileLevelH264Balanced() {
        XCTAssertEqual(EncoderConfiguration.profileLevel(for: .h264, preset: .balanced), "H264_Main_AutoLevel")
    }

    func testProfileLevelH264Quality() {
        XCTAssertEqual(EncoderConfiguration.profileLevel(for: .h264, preset: .quality), "H264_High_AutoLevel")
    }

    func testProfileLevelH264Ultra() {
        XCTAssertEqual(EncoderConfiguration.profileLevel(for: .h264, preset: .ultra), "H264_High_AutoLevel")
    }

    func testProfileLevelHEVCAllPresets() {
        for preset in StreamQualityPreset.allCases {
            XCTAssertEqual(EncoderConfiguration.profileLevel(for: .hevc, preset: preset), "HEVC_Main_AutoLevel")
        }
    }

    // MARK: - Bitrate Calculation

    func testBitrateScalesWithResolution() {
        // Stay below the preset's bitrate cap so the proportional relationship is
        // observable (a large resolution would clip at the cap and break the 4x ratio).
        let smallBitrate = EncoderConfiguration.bitrate(for: .balanced, width: 1280, height: 720, codec: .h264)
        let largeBitrate = EncoderConfiguration.bitrate(for: .balanced, width: 2560, height: 1440, codec: .h264)
        // 4x pixels should mean ~4x bitrate
        XCTAssertEqual(largeBitrate, smallBitrate * 4)
    }

    func testBitrateScalesWithPreset() {
        let perfBitrate = EncoderConfiguration.bitrate(for: .performance, width: 1920, height: 1080, codec: .h264)
        let ultraBitrate = EncoderConfiguration.bitrate(for: .ultra, width: 1920, height: 1080, codec: .h264)
        XCTAssertGreaterThan(ultraBitrate, perfBitrate)
    }

    func testHEVCBitrateLowerThanH264() {
        let h264Bitrate = EncoderConfiguration.bitrate(for: .balanced, width: 1920, height: 1080, codec: .h264)
        let hevcBitrate = EncoderConfiguration.bitrate(for: .balanced, width: 1920, height: 1080, codec: .hevc)
        XCTAssertLessThan(hevcBitrate, h264Bitrate)
    }

    func testBitrateIsPositive() {
        for preset in StreamQualityPreset.allCases {
            for codec in [EncodedFrameCodec.h264, .hevc] {
                let bitrate = EncoderConfiguration.bitrate(for: preset, width: 1920, height: 1080, codec: codec)
                XCTAssertGreaterThan(bitrate, 0, "Bitrate should be positive for \(preset.rawValue)/\(codec.rawValue)")
            }
        }
    }

    // MARK: - Factory Configuration

    func testForPresetProducesValidConfiguration() {
        let config = EncoderConfiguration.forPreset(.balanced, codec: .h264, width: 2560, height: 1440)

        XCTAssertEqual(config.codec, .h264)
        XCTAssertEqual(config.width, 1920)
        XCTAssertEqual(config.height, 1080)
        XCTAssertEqual(config.expectedFrameRate, 30)
        XCTAssertGreaterThan(config.averageBitrate, 0)
        XCTAssertEqual(config.maxKeyframeInterval, 45)
        XCTAssertTrue(config.realtime)
        XCTAssertFalse(config.allowFrameReordering)
        XCTAssertEqual(config.profileLevel, "H264_Main_AutoLevel")
    }

    func testUltraKeepsNativeDimensions() {
        let config = EncoderConfiguration.forPreset(.ultra, codec: .h264, width: 2560, height: 1440)

        XCTAssertEqual(config.width, 2560)
        XCTAssertEqual(config.height, 1440)
        XCTAssertEqual(config.expectedFrameRate, 60)
    }

    func testForPresetHEVC() {
        let config = EncoderConfiguration.forPreset(.quality, codec: .hevc, width: 3840, height: 2160)
        XCTAssertEqual(config.codec, .hevc)
        XCTAssertEqual(config.expectedFrameRate, 60)
        XCTAssertEqual(config.profileLevel, "HEVC_Main_AutoLevel")
    }

    func testAllPresetsProduceRealtimeNoReorder() {
        for preset in StreamQualityPreset.allCases {
            let config = EncoderConfiguration.forPreset(preset, codec: .h264, width: 1920, height: 1080)
            XCTAssertTrue(config.realtime, "\(preset.rawValue) should be realtime")
            XCTAssertFalse(config.allowFrameReordering, "\(preset.rawValue) should not reorder")
        }
    }

    // MARK: - Summary Description

    func testSummaryDescription() {
        let config = EncoderConfiguration.forPreset(.balanced, codec: .h264, width: 1920, height: 1080)
        let summary = config.summaryDescription
        XCTAssertTrue(summary.contains("H264"))
        XCTAssertTrue(summary.contains("1920×1080"))
        XCTAssertTrue(summary.contains("30fps"))
    }

    // MARK: - Encoded Frame Model

    func testEncodedFrameCodecRawValues() {
        XCTAssertEqual(EncodedFrameCodec.h264.rawValue, "h264")
        XCTAssertEqual(EncodedFrameCodec.hevc.rawValue, "hevc")
    }

    // MARK: - Encoder State

    func testEncoderStateRawValues() {
        XCTAssertEqual(EncoderState.idle.rawValue, "idle")
        XCTAssertEqual(EncoderState.configured.rawValue, "configured")
        XCTAssertEqual(EncoderState.encoding.rawValue, "encoding")
        XCTAssertEqual(EncoderState.failed.rawValue, "failed")
    }

    // MARK: - Encoder Diagnostics Default

    func testEncoderDiagnosticsDefault() {
        let diag = EncoderDiagnostics()
        XCTAssertEqual(diag.encodedFrames, 0)
        XCTAssertEqual(diag.keyframes, 0)
        XCTAssertEqual(diag.encodeErrors, 0)
        XCTAssertNil(diag.lastEncodeTimestamp)
        XCTAssertNil(diag.configuredCodec)
        XCTAssertNil(diag.configuredWidth)
        XCTAssertNil(diag.configuredHeight)
        XCTAssertNil(diag.configuredBitrate)
        XCTAssertEqual(diag.reconfigureCount, 0)
    }

    // MARK: - Ultra Bitrate vs Quality at 60fps

    func testUltraBitrateHigherThanQuality() {
        let qualityBitrate = EncoderConfiguration.bitrate(for: .quality, width: 1920, height: 1080, codec: .h264)
        let ultraBitrate = EncoderConfiguration.bitrate(for: .ultra, width: 1920, height: 1080, codec: .h264)
        XCTAssertGreaterThan(ultraBitrate, qualityBitrate)
    }

    // MARK: - Adaptive Streaming Controller

    func testAdaptiveControllerReducesBitrateAfterSustainedCongestion() {
        var controller = AdaptiveStreamingController(
            initialBitrate: 20_000_000,
            preferredFrameRate: 60
        )

        // About 400 ms of queued media: congested, but not severe enough to
        // trigger the independent frame-rate reduction path.
        XCTAssertTrue(controller.observe(bufferedBytes: 1_000_000, now: 0).isEmpty)
        XCTAssertTrue(controller.observe(bufferedBytes: 1_000_000, now: 0.25).isEmpty)
        let decision = controller.observe(bufferedBytes: 1_000_000, now: 1.0)

        XCTAssertEqual(decision.targetBitrate, 16_400_000)
    }

    func testAdaptiveControllerReducesBitrateOnReceiverLoss() {
        var controller = AdaptiveStreamingController(
            initialBitrate: 20_000_000,
            preferredFrameRate: 60
        )
        // Empty send queue, but the receiver reports 8% downlink loss — loss alone must
        // drive the same reduction after the sustained-sample window.
        XCTAssertTrue(controller.observe(bufferedBytes: 0, lossPermille: 80, now: 0).isEmpty)
        XCTAssertTrue(controller.observe(bufferedBytes: 0, lossPermille: 80, now: 0.25).isEmpty)
        let decision = controller.observe(bufferedBytes: 0, lossPermille: 80, now: 1.0)
        XCTAssertEqual(decision.targetBitrate, 16_400_000)
    }

    func testAdaptiveControllerRecoversThroughPeriodicKeyframeBursts() {
        var controller = AdaptiveStreamingController(
            initialBitrate: 20_000_000,
            preferredFrameRate: 60
        )
        // Drive one loss-based cut (empty queue keeps the smoothed backlog at zero).
        _ = controller.observe(bufferedBytes: 0, lossPermille: 80, now: 0)
        _ = controller.observe(bufferedBytes: 0, lossPermille: 80, now: 0.25)
        let cut = controller.observe(bufferedBytes: 0, lossPermille: 80, now: 0.5).targetBitrate
        XCTAssertNotNil(cut)
        XCTAssertLessThan(cut ?? .max, 20_000_000)

        // Healthy but bandwidth-constrained link (e.g. Tailscale): the queue is empty
        // except for a keyframe burst in flight every 6th sample (~1.5 s GOP at 250 ms
        // sampling). Recovery must climb back to maximum despite the periodic bursts —
        // the old hard-reset quiet counter never accumulated 12 consecutive quiet
        // samples here and pinned the bitrate at the reduced level forever. (~25 s
        // horizon: the first burst snaps the EMA high and costs one more cut before
        // the climb starts.)
        for index in 0..<100 {
            let buffered: UInt64 = (index % 6 == 0) ? 1_500_000 : 0
            _ = controller.observe(bufferedBytes: buffered, now: 0.75 + 0.25 * Double(index))
        }
        XCTAssertEqual(controller.currentBitrate, 20_000_000)
    }

    func testAdaptiveControllerSevereLossThrottlesFrameRate() {
        var controller = AdaptiveStreamingController(
            initialBitrate: 20_000_000,
            preferredFrameRate: 60
        )
        _ = controller.observe(bufferedBytes: 0, lossPermille: 200, now: 0)
        let decision = controller.observe(bufferedBytes: 0, lossPermille: 200, now: 2.1)
        XCTAssertEqual(decision.frameRateLimit, 30, "≥10% loss is severe → drop 60→30 fps")
    }

    func testAdaptiveControllerThrottlesSixtyFpsUnderSeverePressure() {
        var controller = AdaptiveStreamingController(
            initialBitrate: 20_000_000,
            preferredFrameRate: 60
        )

        _ = controller.observe(bufferedBytes: 8_000_000, now: 0)
        let decision = controller.observe(bufferedBytes: 8_000_000, now: 2.1)

        XCTAssertEqual(decision.frameRateLimit, 30)
    }

    func testAdaptiveControllerDoesNotThrottleThirtyFpsPreset() {
        var controller = AdaptiveStreamingController(
            initialBitrate: 5_000_000,
            preferredFrameRate: 30
        )
        var frameRateDecision: Int?
        for index in 0..<30 {
            frameRateDecision = controller.observe(
                bufferedBytes: 8_000_000,
                now: Double(index) * 0.25
            ).frameRateLimit ?? frameRateDecision
        }
        XCTAssertNil(frameRateDecision)
        XCTAssertEqual(controller.currentFrameRate, 30)
    }
}
