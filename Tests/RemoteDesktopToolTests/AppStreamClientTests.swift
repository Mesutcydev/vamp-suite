import XCTest
@testable import ClientiOS
import SharedModels
import SharedProtocol

@MainActor
final class AppStreamClientTests: XCTestCase {

    func testNewestSizingChoiceSurvivesOlderRequestCompletion() {
        var intent = AppStreamSizingIntent()
        let adaptive = intent.request()
        intent.markSent(adaptive)
        let restore = intent.request()
        intent.markSent(adaptive)
        XCTAssertTrue(intent.pending, "Sending an older request must not consume Restore")
        XCTAssertFalse(intent.accepts(adaptive))
        XCTAssertTrue(intent.accepts(restore))
        intent.markSent(restore)
        XCTAssertFalse(intent.pending)
        XCTAssertTrue(intent.accepts(restore), "The latest sent request can still complete")
    }

    func testCanceledSizingCannotApplyLateRepliesOrConsumeNextChoice() {
        var intent = AppStreamSizingIntent()
        let old = intent.request()
        intent.cancel()
        XCTAssertFalse(intent.pending)
        XCTAssertFalse(intent.accepts(old))
        let next = intent.request()
        intent.markSent(old)
        XCTAssertTrue(intent.pending)
        XCTAssertTrue(intent.accepts(next))
    }

    func testOpeningModelPreservesWindowSizeByDefault() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "Portrait Regression Test")
        let model = AppStreamViewModel(environment: environment)
        model.updateClientViewport(size: CGSize(width: 390, height: 720))
        XCTAssertEqual(model.sizingMode, .original)
        XCTAssertFalse(model.isResizing)
    }

    func testTerminalApplicationProfileRecognizesKnownAndNamedTerminals() {
        XCTAssertTrue(AppStreamApplicationProfile.isTerminal(
            bundleIdentifier: "com.apple.Terminal", name: "Terminal"))
        XCTAssertTrue(AppStreamApplicationProfile.isTerminal(
            bundleIdentifier: nil, name: "Ghostty Nightly"))
        XCTAssertFalse(AppStreamApplicationProfile.isTerminal(
            bundleIdentifier: "com.apple.Safari", name: "Safari"))
    }

    private func result(_ status: DisplaySwitchStatus, target: StreamTarget = .application("com.apple.Terminal"), reason: String? = nil) -> StreamTargetSwitchResultMessage {
        StreamTargetSwitchResultMessage(
            sessionID: UUID(),
            resolvedTarget: target,
            senderDeviceID: UUID(),
            status: status,
            reason: reason,
            startedAt: Date()
        )
    }

    // MARK: - State machine (pure reduce)

    func testLateLaunchCompletionDoesNotReopenBrowser() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "App Stream Audit Test")
        let model = AppStreamViewModel(environment: environment)
        model.backToApps()
        let browserStatus = model.status

        model.apply(StreamTargetSwitchResultMessage(
            sessionID: UUID(),
            resolvedTarget: .window("42"),
            senderDeviceID: UUID(),
            status: .completed,
            width: 800,
            height: 600,
            scaleFactor: 2,
            startedAt: Date()
        ))

        XCTAssertEqual(model.status, browserStatus)
        XCTAssertNil(model.streamedWindow)
    }

    func testLateLaunchAcceptanceDoesNotRestartStoppedModel() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "App Stream Audit Test")
        let model = AppStreamViewModel(environment: environment)
        model.stop()
        model.apply(result(.accepted))
        XCTAssertEqual(model.status, .idle)
    }

    func testAcceptedGoesToLaunching() {
        let next = AppStreamViewModel.reduce(status: .browsing, result: result(.accepted), pendingName: "Terminal")
        XCTAssertEqual(next, .launching(name: "Terminal"))
    }

    func testCompletedGoesToStreaming() {
        let next = AppStreamViewModel.reduce(
            status: .launching(name: "Terminal"),
            result: result(.completed, target: .window("42")),
            pendingName: "Terminal"
        )
        XCTAssertEqual(next, .streaming(target: .window("42"), name: "Terminal"))
    }

    func testFailureWhileLaunchingIsFailed() {
        let next = AppStreamViewModel.reduce(
            status: .launching(name: "Xcode"),
            result: result(.failed, reason: "No streamable window yet."),
            pendingName: "Xcode"
        )
        XCTAssertEqual(next, .failed(reason: "No streamable window yet."))
    }

    func testFailureWhileStreamingIsTargetLost() {
        // The host sends an unsolicited failed result when the window closes / app quits.
        let next = AppStreamViewModel.reduce(
            status: .streaming(target: .window("42"), name: "Terminal"),
            result: result(.failed, target: .window("42"), reason: "The application window is no longer available."),
            pendingName: "Terminal"
        )
        XCTAssertEqual(next, .targetLost(reason: "The application window is no longer available."))
    }

    func testRejectedIsFailed() {
        let next = AppStreamViewModel.reduce(status: .browsing, result: result(.rejected, reason: "Not running."), pendingName: "Safari")
        XCTAssertEqual(next, .failed(reason: "Not running."))
    }

    func testReconnectRequiresSameHostAndExactWindow() {
        let apps = [RemoteApplication(bundleIdentifier: "com.apple.Safari", name: "Safari",
            isRunning: true, isActive: true, windowIDs: ["42", "43"])]
        XCTAssertTrue(AppStreamViewModel.canResume(applicationID: "com.apple.Safari", windowID: "42",
            expectedFingerprint: "test-host", connectedFingerprint: "test-host", applications: apps))
        XCTAssertFalse(AppStreamViewModel.canResume(applicationID: "com.apple.Safari", windowID: "41",
            expectedFingerprint: "test-host", connectedFingerprint: "test-host", applications: apps))
        XCTAssertFalse(AppStreamViewModel.canResume(applicationID: "com.apple.Safari", windowID: "42",
            expectedFingerprint: "test-host", connectedFingerprint: "other-host", applications: apps))
    }

    func testResizeQueueRespectsHostControlRateLimit() {
        XCTAssertEqual(AppStreamViewModel.controlRequestDelay(last: nil, now: 10), 0)
        XCTAssertEqual(AppStreamViewModel.controlRequestDelay(last: 10, now: 10.3), 1.8, accuracy: 0.001)
        XCTAssertEqual(AppStreamViewModel.controlRequestDelay(last: 10, now: 13), 0)
    }

    func testUnsolicitedEventsMustMatchActiveWindow() {
        let state = AppStreamViewModel.Status.streaming(target: .window("42"), name: "Terminal")
        XCTAssertFalse(AppStreamViewModel.accepts(result(.failed, target: .window("41")), status: state, pendingRequestID: nil, isResizing: false))
        XCTAssertFalse(AppStreamViewModel.accepts(result(.completed, target: .window("41")), status: state, pendingRequestID: nil, isResizing: false))
        XCTAssertTrue(AppStreamViewModel.accepts(result(.completed, target: .window("42")), status: state, pendingRequestID: nil, isResizing: false))
        XCTAssertTrue(AppStreamViewModel.accepts(result(.failed, target: .window("42")), status: state, pendingRequestID: nil, isResizing: false))
    }

    func testPendingResizeRejectsUnsolicitedAndSupersededReplies() {
        let pending = UUID()
        let state = AppStreamViewModel.Status.streaming(target: .window("42"), name: "Terminal")
        var reply = result(.completed, target: .window("42"))
        XCTAssertFalse(AppStreamViewModel.accepts(reply, status: state, pendingRequestID: pending, isResizing: true))
        reply.requestID = UUID()
        XCTAssertFalse(AppStreamViewModel.accepts(reply, status: state, pendingRequestID: pending, isResizing: true))
        reply.requestID = pending
        XCTAssertTrue(AppStreamViewModel.accepts(reply, status: state, pendingRequestID: pending, isResizing: true))
        XCTAssertFalse(AppStreamViewModel.accepts(reply, status: .browsing, pendingRequestID: pending, isResizing: false))
    }

    func testOldWindowLossCannotFailNewLaunch() {
        XCTAssertFalse(AppStreamViewModel.accepts(result(.failed, target: .window("42")),
            status: .launching(name: "Safari"), pendingRequestID: UUID(), isResizing: false))
    }

    func testAdaptiveRequestMetadataIsOptionalAndRoundTrips() throws {
        let request = StreamTargetSwitchRequestMessage(sessionID: UUID(), target: .window("42"),
            senderDeviceID: UUID(), clientViewportAspect: 0.5, viewportWidth: 390, viewportHeight: 780,
            sizingMode: .original, requestID: UUID())
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(StreamTargetSwitchRequestMessage.self, from: data), request)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["viewportWidth", "viewportHeight", "sizingMode"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(StreamTargetSwitchRequestMessage.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.sizingMode)
        XCTAssertNil(decoded.viewportWidth)
        XCTAssertEqual(decoded.clientViewportAspect, 0.5)
    }

    // MARK: - Capability negotiation

    func testAppStreamingNegotiatesOnlyWhenBothPeersSupportIt() {
        let hostWith: HostCapabilityFlags = [.supportsH264, .supportsAppStreaming]
        let hostWithout: HostCapabilityFlags = [.supportsH264]
        let client: HostCapabilityFlags = [.supportsH264, .supportsAppStreaming]

        XCTAssertTrue(CapabilityNegotiator.negotiate(host: hostWith, client: client)?.supportsAppStreaming == true)
        XCTAssertTrue(CapabilityNegotiator.negotiate(host: hostWithout, client: client)?.supportsAppStreaming == false)
    }

    func testCurrentClientAdvertisesAppStreaming() {
        XCTAssertTrue(HostCapabilityFlags.currentClient(isMacClient: false).contains(.supportsAppStreaming))
    }
}
