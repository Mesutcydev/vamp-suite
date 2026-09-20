import CoreVideo
import XCTest
@testable import CaptureEngine
@testable import ClientiOS
@testable import Diagnostics
@testable import Discovery
@testable import EncodeEngine
@testable import HostApp
@testable import SharedModels
@testable import SharedProtocol
@testable import TransportWebRTC

private final class LockedTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ value: Value) {
        lock.withLock {
            self.value = value
        }
    }
}

final class SessionFeaturePolicyTests: XCTestCase {
    func testUltraSupportAllowsHighResolutionModernPhone() {
        XCTAssertTrue(
            ClientAppEnvironment.supportsUltraQualityPreset(
                isPhone: true,
                deviceModelIdentifier: "iPhone17,2",
                nativeBounds: CGSize(width: 1290, height: 2796),
                physicalMemoryBytes: 8 * 1024 * 1024 * 1024
            )
        )
    }

    func testUltraSupportBlocksKnownNonProPhoneWithoutHeadroom() {
        XCTAssertFalse(
            ClientAppEnvironment.supportsUltraQualityPreset(
                isPhone: true,
                deviceModelIdentifier: "iPhone16,3",
                nativeBounds: CGSize(width: 1179, height: 2556),
                physicalMemoryBytes: 6 * 1024 * 1024 * 1024
            )
        )
    }

    func testUltraSupportFallsBackToHeuristicForUnknownFuturePhone() {
        XCTAssertTrue(
            ClientAppEnvironment.supportsUltraQualityPreset(
                isPhone: true,
                deviceModelIdentifier: "iPhone99,9",
                nativeBounds: CGSize(width: 1320, height: 2868),
                physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
                hardwareHEVCDecodeSupported: true
            )
        )
    }

    func testUltraSupportRequiresHardwareHEVCForUnknownFuturePhone() {
        XCTAssertFalse(
            ClientAppEnvironment.supportsUltraQualityPreset(
                isPhone: true,
                deviceModelIdentifier: "iPhone99,9",
                nativeBounds: CGSize(width: 1320, height: 2868),
                physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
                hardwareHEVCDecodeSupported: false
            )
        )
    }

    func testUltraSupportBlocksLowerHeadroomPhone() {
        XCTAssertFalse(
            ClientAppEnvironment.supportsUltraQualityPreset(
                isPhone: true,
                deviceModelIdentifier: "iPhone14,5",
                nativeBounds: CGSize(width: 1170, height: 2532),
                physicalMemoryBytes: 4 * 1024 * 1024 * 1024
            )
        )
    }

    func testQualityClassifierReconnectWins() {
        let service = NetworkQualityIndicatorService()
        let metrics = SessionMetricsSnapshot(connectionState: .connected)

        XCTAssertEqual(service.classify(metrics: metrics, isReconnecting: true), .reconnecting)
    }

    func testQualityClassifierDetectsPoorConditions() {
        let service = NetworkQualityIndicatorService()
        let metrics = SessionMetricsSnapshot(
            framesPerSecond: 9,
            bitrateKbps: 900,
            latencyMs: 260,
            packetLossPercent: 6.5,
            connectionState: .connected
        )

        XCTAssertEqual(service.classify(metrics: metrics, isReconnecting: false), .poor)
    }

    func testStatsFormatterUsesCompactUnits() {
        let formatter = SessionStatsFormatter()

        XCTAssertEqual(formatter.fpsText(for: 29.2), "29 fps")
        XCTAssertEqual(formatter.bitrateText(for: 4_800), "4.8 Mbps")
        XCTAssertEqual(formatter.latencyText(for: 42), "42 ms")
        XCTAssertEqual(formatter.packetLossText(for: 1.25), "1.2%")
    }

    func testLowPowerProfileReducesFrameRateAndBitrate() {
        let policy = SessionPerformancePolicyService()
        let profile = policy.profile(
            preferredPreset: .ultra,
            lowPowerModeEnabled: true,
            thermalState: .nominal
        )

        XCTAssertEqual(profile.effectivePreset, .balanced)
        XCTAssertEqual(profile.targetFrameRate, 24)
        XCTAssertLessThan(profile.maxBitrateKbps, 8_000)
        XCTAssertEqual(profile.throttleReason, .lowPower)
    }

    func testDefaultPreferredPresetUsesUltraOnlyForAllowlistedPhones() {
        XCTAssertEqual(
            ClientAppEnvironment.defaultPreferredQualityPreset(
                isPhone: true,
                deviceModelIdentifier: "iPhone17,2"
            ),
            .quality
        )
        XCTAssertEqual(
            ClientAppEnvironment.defaultPreferredQualityPreset(
                isPhone: true,
                deviceModelIdentifier: "iPhone16,3"
            ),
            .balanced
        )
        XCTAssertEqual(
            ClientAppEnvironment.defaultPreferredQualityPreset(
                isPhone: false,
                deviceModelIdentifier: nil
            ),
            .balanced
        )
    }

    func testStreamScalingResolutionCaps() {
        // Under H.264 (allowsHighResolution = false), caps at 1920 (1080p equivalent)
        let scaledH264 = StreamScaling.scaledDimensions(
            preset: .balanced,
            nativeWidth: 3840,
            nativeHeight: 2160,
            allowsHighResolution: false
        )
        XCTAssertEqual(scaledH264.width, 1920)
        XCTAssertEqual(scaledH264.height, 1080)

        // Under HEVC (allowsHighResolution = true), caps at 3840 (4K equivalent)
        let scaledHEVC = StreamScaling.scaledDimensions(
            preset: .balanced,
            nativeWidth: 5120,
            nativeHeight: 2880,
            allowsHighResolution: true
        )
        XCTAssertEqual(scaledHEVC.width, 3840)
        XCTAssertEqual(scaledHEVC.height, 2160)

        // Under HEVC (allowsHighResolution = true) but display is smaller than 4K, returns native size
        let scaledHEVCSmall = StreamScaling.scaledDimensions(
            preset: .balanced,
            nativeWidth: 2560,
            nativeHeight: 1440,
            allowsHighResolution: true
        )
        XCTAssertEqual(scaledHEVCSmall.width, 2560)
        XCTAssertEqual(scaledHEVCSmall.height, 1440)

        // Under Ultra preset, does not cap at all (returns native dimensions)
        let scaledUltra = StreamScaling.scaledDimensions(
            preset: .ultra,
            nativeWidth: 5120,
            nativeHeight: 2880,
            allowsHighResolution: false
        )
        XCTAssertEqual(scaledUltra.width, 5120)
        XCTAssertEqual(scaledUltra.height, 2880)
    }

    func testPerformanceWindowFloor() {
        // A portrait window's backing (836×1812) would halve to 418×906 on
        // performance — quarter of an already-small stream. The window floor
        // lifts the long edge to 1080 (never past the source's own pixels).
        let floored = StreamScaling.scaledDimensions(
            preset: .performance,
            nativeWidth: 836,
            nativeHeight: 1812,
            allowsHighResolution: true,
            minLongEdge: StreamScaling.windowPerformanceMinLongEdge
        )
        // 1080/906 ≈ 1.192 → 498×1080 (even-rounded)
        XCTAssertEqual(floored.height, 1080)
        XCTAssertEqual(floored.width, 498)
        // The floor must not touch other presets…
        let balanced = StreamScaling.scaledDimensions(
            preset: .balanced,
            nativeWidth: 836,
            nativeHeight: 1812,
            allowsHighResolution: true,
            minLongEdge: StreamScaling.windowPerformanceMinLongEdge
        )
        XCTAssertEqual(balanced.width, 836)
        XCTAssertEqual(balanced.height, 1812)
        // …or streams without a floor…
        let noFloor = StreamScaling.scaledDimensions(
            preset: .performance,
            nativeWidth: 836,
            nativeHeight: 1812,
            allowsHighResolution: true
        )
        XCTAssertEqual(noFloor.width, 418)
        XCTAssertEqual(noFloor.height, 906)
        // …and must never upscale beyond the window's backing pixels.
        let smallWindow = StreamScaling.scaledDimensions(
            preset: .performance,
            nativeWidth: 700,
            nativeHeight: 960,
            allowsHighResolution: true,
            minLongEdge: StreamScaling.windowPerformanceMinLongEdge
        )
        // Long edge 480 (even half of 960) < floor, but the native long edge is
        // only 960 → clamped to native: (700, 960).
        XCTAssertEqual(smallWindow.width, 700)
        XCTAssertEqual(smallWindow.height, 960)
        // Full-display performance streams (large natives) are unaffected.
        let displayPerformance = StreamScaling.scaledDimensions(
            preset: .performance,
            nativeWidth: 3024,
            nativeHeight: 1964,
            allowsHighResolution: true,
            minLongEdge: StreamScaling.windowPerformanceMinLongEdge
        )
        XCTAssertEqual(displayPerformance.width, 1512)
        XCTAssertEqual(displayPerformance.height, 982)
    }

    /// `ultra` passes the source's native pixels straight through, so a window on a 5K/6K display
    /// (or one grown past the phone's screen) could build a frame the client's hardware decoder
    /// rejects — the stream then fails to a black picture. Window streams are clamped to the
    /// 4K UHD envelope an iPhone 17 Pro Max and an M4 Mac can actually exchange.
    func testWindowStreamUltraIsClampedToTheDecoderEnvelope() {
        // A very tall window from a 6K display: the long edge binds.
        let tall = StreamScaling.scaledDimensions(
            preset: .ultra,
            nativeWidth: 3_200,
            nativeHeight: 6_400,
            allowsHighResolution: true,
            minLongEdge: StreamScaling.windowPerformanceMinLongEdge
        )
        XCTAssertEqual(max(tall.width, tall.height), StreamScaling.windowMaximumLongEdge)
        XCTAssertLessThanOrEqual(tall.width * tall.height, StreamScaling.windowMaximumPixels)
        XCTAssertEqual(Double(tall.width) / Double(tall.height), 3_200.0 / 6_400.0, accuracy: 0.01)
        XCTAssertEqual(tall.width % 2, 0, "H.264/HEVC 4:2:0 needs even axes")
        XCTAssertEqual(tall.height % 2, 0)

        // A huge-area square window: the pixel budget binds, not the edge.
        let square = StreamScaling.scaledDimensions(
            preset: .ultra,
            nativeWidth: 4_096,
            nativeHeight: 4_096,
            allowsHighResolution: true,
            minLongEdge: StreamScaling.windowPerformanceMinLongEdge
        )
        XCTAssertLessThanOrEqual(square.width * square.height, StreamScaling.windowMaximumPixels)
        XCTAssertLessThanOrEqual(max(square.width, square.height), StreamScaling.windowMaximumLongEdge)

        // Display streams keep native resolution: the display *is* the intended picture.
        let display = StreamScaling.scaledDimensions(
            preset: .ultra,
            nativeWidth: 5_120,
            nativeHeight: 2_880,
            allowsHighResolution: true
        )
        XCTAssertEqual(display.width, 5_120)
        XCTAssertEqual(display.height, 2_880)

        // Never upscales, and real hardware sizes pass through untouched: the 2560×1440 Mac
        // pair's fitted 1364-point window is 2728 px tall, under both limits.
        let realWindow = StreamScaling.scaledDimensions(
            preset: .ultra,
            nativeWidth: 1_334,
            nativeHeight: 2_728,
            allowsHighResolution: true,
            minLongEdge: StreamScaling.windowPerformanceMinLongEdge
        )
        XCTAssertEqual(realWindow.width, 1_334)
        XCTAssertEqual(realWindow.height, 2_728)
    }

    /// Capture and encode MUST produce identical dimensions or VideoToolbox rescales mismatched
    /// input. Both delegate to `StreamScaling`, and the window ceiling is part of that shared
    /// rule, so the invariant holds for the clamped case too.
    func testCaptureAndEncodeAgreeOnWindowDimensionsIncludingTheCeiling() {
        for preset in [StreamQualityPreset.performance, .balanced, .quality, .ultra] {
            for codec in [EncodedFrameCodec.h264, .hevc] {
                let capture = CaptureConfiguration.forPreset(
                    preset,
                    displayWidth: 3_200,
                    displayHeight: 6_400,
                    scaleFactor: 2,
                    allowsHighResolution: codec == .hevc,
                    minLongEdge: StreamScaling.windowPerformanceMinLongEdge
                )
                let encode = EncoderConfiguration.scaledDimensions(
                    preset: preset,
                    width: 3_200,
                    height: 6_400,
                    codec: codec,
                    minLongEdge: StreamScaling.windowPerformanceMinLongEdge
                )
                XCTAssertEqual(capture.width, encode.0, "\(preset.rawValue)/\(codec.rawValue) width")
                XCTAssertEqual(capture.height, encode.1, "\(preset.rawValue)/\(codec.rawValue) height")
            }
        }
    }

    func testCriticalThermalStateForcesPerformancePreset() {
        let policy = SessionPerformancePolicyService()
        let profile = policy.profile(
            preferredPreset: .quality,
            lowPowerModeEnabled: false,
            thermalState: .critical
        )

        XCTAssertEqual(profile.effectivePreset, .performance)
        XCTAssertEqual(profile.targetFrameRate, 12)
        XCTAssertEqual(profile.throttleReason, .thermalCritical)
    }

    @MainActor
    func testSessionModeControllerTransitions() {
        let controller = HostSessionModeController()

        XCTAssertEqual(controller.mode, .fullControl)
        controller.setMode(.viewOnly)
        XCTAssertEqual(controller.mode, .viewOnly)
        XCTAssertEqual(controller.currentMode, .viewOnly)
    }

    @MainActor
    func testHostPerformanceControllerHonorsRequestedResolutionPreset() {
        let controller = HostPerformanceStateController()

        XCTAssertEqual(controller.setActivePreset(.ultra), .ultra)
        XCTAssertEqual(controller.profile.effectivePreset, .ultra)
    }

    @MainActor
    func testHostPerformanceControllerStillDowngradesRequestedPresetInLowPowerMode() {
        let controller = HostPerformanceStateController(lowPowerModeEnabled: true)

        XCTAssertEqual(controller.setActivePreset(.ultra), .balanced)
        XCTAssertEqual(controller.profile.throttleReason, .lowPower)
    }

    func testEventLogExportRedactsSensitiveMetadata() throws {
        let exporter = EventLogExportService()
        let item = EventLogItem(
            severity: .info,
            category: "Auth",
            message: "token=abc123 bearer xyz",
            metadata: [
                "fingerprint": "123456789",
                "note": "password=hunter2"
            ]
        )

        let url = try exporter.export(
            items: [item],
            destinationDirectory: FileManager.default.temporaryDirectory,
            filePrefix: "redaction-test"
        )
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("[REDACTED]"))
        XCTAssertFalse(text.contains("abc123"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("123456789"))
    }

    func testScreenshotServiceIsExplicitWhenUnsupported() throws {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        let service = SessionScreenshotService()

        #if canImport(UIKit)
        XCTAssertNoThrow(try service.capture(pixelBuffer: XCTUnwrap(pixelBuffer)))
        #else
        XCTAssertThrowsError(try service.capture(pixelBuffer: XCTUnwrap(pixelBuffer)))
        #endif
    }
}

final class SessionModeRouterTests: XCTestCase {
    @MainActor
    func testViewOnlyModeBlocksHostInputInjection() async throws {
        let sessionManager = RouterTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeController = HostSessionModeController(mode: .viewOnly)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeController
        )

        let sessionID = UUID()
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        try sessionManager.emit(
            try DataChannelEnvelope.controlAuth(
                ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
            )
        )
        let envelope = try DataChannelEnvelope.inputCommand(
            InputCommandMessage(
                sessionID: sessionID,
                command: .text(TextInputCommand(text: "blocked"))
            )
        ).authenticated(using: token, counter: 1)
        try sessionManager.emit(try XCTUnwrap(envelope))

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(inputService.snapshotCommands().isEmpty)
        XCTAssertEqual(router.commandsRejected, 1)
        router.stopListening()
    }
}

final class LockStateRouterTests: XCTestCase {
    @MainActor
    private func makeRouter(lockState: HostLockState = .unlockedActiveSession) -> (HostInputCommandRouter, RouterTestSessionManager, RecordingInputInjectionService, String) {
        let sessionManager = RouterTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeController = HostSessionModeController(mode: .fullControl)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeController
        )
        router.lockStateProvider = { lockState }
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        return (router, sessionManager, inputService, token)
    }

    @MainActor
    func testInputCommandPassesThroughWhenUnlocked() async throws {
        let (router, sessionManager, inputService, token) = makeRouter(lockState: .unlockedActiveSession)
        let sessionID = UUID()
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        try sessionManager.emit(try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ))
        let envelope = try DataChannelEnvelope.inputCommand(
            InputCommandMessage(sessionID: sessionID, command: .text(TextInputCommand(text: "hello")))
        ).authenticated(using: token, counter: 1)
        try sessionManager.emit(try XCTUnwrap(envelope))

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(inputService.snapshotCommands().isEmpty, "Command should be injected when unlocked")
        XCTAssertEqual(router.commandsRejected, 0)
        router.stopListening()
    }

    @MainActor
    func testInputCommandIsRejectedWhenLocked() async throws {
        let currentLockState = LockedTestValue<HostLockState>(.lockedOrLoginWindow)
        let sessionManager = RouterTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeController = HostSessionModeController(mode: .fullControl)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeController
        )
        router.lockStateProvider = { currentLockState.get() }
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        let sessionID = UUID()
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        try sessionManager.emit(try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ))
        let envelope = try DataChannelEnvelope.inputCommand(
            InputCommandMessage(sessionID: sessionID, command: .text(TextInputCommand(text: "password")))
        ).authenticated(using: token, counter: 1)
        try sessionManager.emit(try XCTUnwrap(envelope))

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(inputService.snapshotCommands().isEmpty, "Command must not be injected while Mac is locked")
        XCTAssertEqual(router.commandsRejected, 1)

        // Unlock and verify subsequent commands are accepted
        currentLockState.set(.unlockedActiveSession)
        let envelope2 = try DataChannelEnvelope.inputCommand(
            InputCommandMessage(sessionID: sessionID, command: .text(TextInputCommand(text: "hello")))
        ).authenticated(using: token, counter: 2)
        try sessionManager.emit(try XCTUnwrap(envelope2))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(inputService.snapshotCommands().isEmpty, "Command should be injected after unlock")

        router.stopListening()
    }

    @MainActor
    func testUnlockPasswordIsAcceptedWhenLocked() async throws {
        let sessionManager = RouterTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeController = HostSessionModeController(mode: .viewOnly)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeController
        )
        let recorder = PasswordRecorder()
        router.lockStateProvider = { .lockedOrLoginWindow }
        router.remoteUnlockEnabled = { true }
        router.onUnlockPassword = { password in
            await recorder.record(password)
        }

        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        let sessionID = UUID()
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        try sessionManager.emit(try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ))
        let envelope = try DataChannelEnvelope.unlockPassword(
            UnlockPasswordMessage(sessionID: sessionID, password: "correct horse")
        ).authenticated(using: token, counter: 1)
        try sessionManager.emit(try XCTUnwrap(envelope))

        try await Task.sleep(nanoseconds: 150_000_000)
        let recordedPasswords = await recorder.snapshot()
        XCTAssertEqual(recordedPasswords, ["correct horse"])
        XCTAssertTrue(inputService.snapshotCommands().isEmpty, "Unlock password should use the dedicated unlock handler")

        router.stopListening()
    }

    @MainActor
    func testUnlockPasswordIsIgnoredWhenRemoteUnlockDisabled() async throws {
        let sessionManager = RouterTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeController = HostSessionModeController(mode: .viewOnly)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeController
        )
        let recorder = PasswordRecorder()
        router.lockStateProvider = { .lockedOrLoginWindow }
        router.onUnlockPassword = { password in
            await recorder.record(password)
        }

        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        let sessionID = UUID()
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        try sessionManager.emit(try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ))
        let envelope = try DataChannelEnvelope.unlockPassword(
            UnlockPasswordMessage(sessionID: sessionID, password: "correct horse")
        ).authenticated(using: token, counter: 1)
        try sessionManager.emit(try XCTUnwrap(envelope))

        try await Task.sleep(nanoseconds: 150_000_000)
        let recordedPasswords = await recorder.snapshot()
        XCTAssertTrue(recordedPasswords.isEmpty)
        XCTAssertTrue(inputService.snapshotCommands().isEmpty)

        router.stopListening()
    }

    @MainActor
    func testRouterDoesNotCrashWhenLockStateChangesRapidly() async throws {
        let (router, sessionManager, _, token) = makeRouter(lockState: .unlockedActiveSession)
        let sessionID = UUID()
        let toggleState = LockedTestValue<HostLockState>(.unlockedActiveSession)
        router.lockStateProvider = { toggleState.get() }
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        try sessionManager.emit(try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ))

        // Rapid toggle lock/unlock 10 times while emitting commands
        for i in 0..<10 {
            toggleState.set(i.isMultiple(of: 2) ? .lockedOrLoginWindow : .unlockedActiveSession)
            let envelope = try DataChannelEnvelope.inputCommand(
                InputCommandMessage(sessionID: sessionID, command: .text(TextInputCommand(text: "x")))
            ).authenticated(using: token, counter: UInt64(i + 1))
            try sessionManager.emit(try XCTUnwrap(envelope))
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        // No crash; processed + rejected should equal total emitted
        XCTAssertEqual(router.commandsProcessed + router.commandsRejected, 10)
        router.stopListening()
    }
}

private actor PasswordRecorder {
    private var passwords: [String] = []

    func record(_ password: String) {
        passwords.append(password)
    }

    func snapshot() -> [String] {
        passwords
    }
}

private final class RouterTestSessionManager: WebRTCSessionManaging, @unchecked Sendable {
    var connectionState: ConnectionState = .connected
    var peerConnectionState: PeerConnectionState = .connected
    var dataChannelState: DataChannelState = .open
    var mediaChannelReadiness: MediaChannelReadiness = MediaChannelReadiness(dataChannelState: .open, videoTrackAttached: true, audioTrackAttached: false)
    var streamDiagnostics: StreamDiagnostics = StreamDiagnostics()
    var videoFrameSubscriberCount: Int = 0

    private let lock = NSLock()
    private var dataContinuation: AsyncStream<DataChannelEnvelope>.Continuation?
    private var pendingEnvelopes: [DataChannelEnvelope] = []

    func prepareSession(id: UUID, role: WebRTCSessionRole) async throws {}
    func createOffer(sessionID: UUID, qualityPreset: StreamQualityPreset, displayID: String?) async throws -> SessionOfferMessage {
        SessionOfferMessage(sessionID: sessionID, sdp: "", qualityPreset: qualityPreset)
    }
    func applyRemoteOffer(_ message: SessionOfferMessage) async throws -> SessionAnswerMessage {
        SessionAnswerMessage(sessionID: message.sessionID, sdp: "")
    }
    func applyRemoteAnswer(_ message: SessionAnswerMessage) async throws {}
    func addRemoteCandidate(_ message: ICECandidateMessage) async throws {}
    func closeSession() async {}
    func sendInputCommand(_ message: InputCommandMessage) async throws {}
    func sendDataMessage(_ message: DataChannelEnvelope) throws {}
    func configureControlChannelAuth(sessionTokenHex: String?) {}
    func localICECandidates() -> AsyncStream<ICECandidateMessage> {
        AsyncStream { continuation in continuation.finish() }
    }
    func attachVideoSource(_ source: (any VideoFrameSource)?) {}
    func sendVideoFrame(_ frame: VideoFrameData) throws {}
    func receivedVideoFrames() -> AsyncStream<VideoFrameData> {
        AsyncStream { continuation in continuation.finish() }
    }
    func connectionStateUpdates() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.connected)
        }
    }

    func dataChannelStateUpdates() -> AsyncStream<DataChannelState> {
        AsyncStream { continuation in
            continuation.yield(.open)
        }
    }

    func videoChannelStateUpdates() -> AsyncStream<DataChannelState> {
        AsyncStream { continuation in continuation.finish() }
    }

    func receiveDataMessages() -> AsyncStream<DataChannelEnvelope> {
        AsyncStream { continuation in
            let pending: [DataChannelEnvelope]
            lock.lock()
            dataContinuation = continuation
            pending = pendingEnvelopes
            pendingEnvelopes.removeAll()
            lock.unlock()
            pending.forEach { continuation.yield($0) }
        }
    }

    func emit(_ envelope: DataChannelEnvelope) throws {
        lock.lock()
        let continuation = dataContinuation
        if continuation == nil {
            pendingEnvelopes.append(envelope)
        }
        lock.unlock()
        continuation?.yield(envelope)
    }
}
