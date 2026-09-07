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

    func testOpeningModelRequestsPortraitAdaptiveSizingByDefault() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "Portrait Regression Test")
        let model = AppStreamViewModel(environment: environment)
        model.updateClientViewport(size: CGSize(width: 390, height: 720))
        XCTAssertEqual(model.sizingMode, .adaptive)
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

    // MARK: - Measured viewport (client → host geometry source of truth)

    /// The portrait ordering must survive measurement untouched. A portrait container measured as
    /// 390x794 has to reach the host as a portrait aspect; sorting or min/max'ing the pair would
    /// silently turn the request landscape and letterbox the picture.
    func testPortraitViewportKeepsItsOrderingAndAspect() throws {
        let measured = try XCTUnwrap(AppStreamViewModel.measuredViewport(
            size: CGSize(width: 390, height: 794), previous: .zero))
        XCTAssertEqual(measured.size, CGSize(width: 390, height: 794))
        XCTAssertEqual(measured.aspect, 390.0 / 794.0, accuracy: 0.0001)
        XCTAssertLessThan(measured.aspect, 1, "portrait viewport must stay a portrait aspect")

        let landscape = try XCTUnwrap(AppStreamViewModel.measuredViewport(
            size: CGSize(width: 794, height: 390), previous: .zero))
        XCTAssertEqual(landscape.aspect, 794.0 / 390.0, accuracy: 0.0001)
        XCTAssertGreaterThan(landscape.aspect, 1, "landscape viewport must stay a landscape aspect")
    }

    /// Invalid measurements must never reach the host: the first layout pass reports `.zero`, and a
    /// non-finite or degenerate size would produce a meaningless resize request.
    func testInvalidViewportMeasurementsAreRejected() {
        let invalid: [CGSize] = [
            .zero,
            CGSize(width: 0, height: 794),
            CGSize(width: 390, height: 0),
            CGSize(width: -390, height: 794),
            CGSize(width: CGFloat.nan, height: 794),
            CGSize(width: 390, height: CGFloat.infinity),
        ]
        for size in invalid {
            XCTAssertNil(AppStreamViewModel.measuredViewport(size: size, previous: .zero),
                "\(size) must be rejected")
        }
        // Aspect outside the supported 0.25...4 window is rejected too.
        XCTAssertNil(AppStreamViewModel.measuredViewport(
            size: CGSize(width: 10, height: 794), previous: .zero), "aspect 0.013 is too extreme")
        XCTAssertNil(AppStreamViewModel.measuredViewport(
            size: CGSize(width: 7_940, height: 10), previous: .zero), "aspect 794 is too extreme")
    }

    /// Layout noise must coalesce. Control overlays appearing/disappearing and keyboard animation
    /// move the video container by a point or two; letting that through would drive a window-resize
    /// loop on the Mac for every animation frame.
    func testLayoutNoiseCoalescesButRealChangesPass() {
        let baseline = CGSize(width: 390, height: 794)
        // Sub-2pt jitter on either axis is noise.
        XCTAssertNil(AppStreamViewModel.measuredViewport(
            size: CGSize(width: 390.5, height: 795), previous: baseline))
        XCTAssertNil(AppStreamViewModel.measuredViewport(
            size: CGSize(width: 389, height: 793.5), previous: baseline))
        XCTAssertNil(AppStreamViewModel.measuredViewport(
            size: baseline, previous: baseline), "an unchanged size is not a change")

        // A genuine viewport change (rotation, split view, keyboard taking real space) passes.
        XCTAssertNotNil(AppStreamViewModel.measuredViewport(
            size: CGSize(width: 390, height: 500), previous: baseline),
            "keyboard/split-view height change must be honored")
        XCTAssertNotNil(AppStreamViewModel.measuredViewport(
            size: CGSize(width: 794, height: 390), previous: baseline), "rotation must be honored")
    }

    /// An accepted measurement becomes the new baseline, so a second identical reading coalesces
    /// while continued drift still accumulates into a real change.
    func testAcceptedMeasurementBecomesTheNextBaseline() throws {
        let first = try XCTUnwrap(AppStreamViewModel.measuredViewport(
            size: CGSize(width: 390, height: 794), previous: .zero))
        XCTAssertNil(AppStreamViewModel.measuredViewport(
            size: first.size, previous: first.size), "the same reading must not re-request")
        let second = try XCTUnwrap(AppStreamViewModel.measuredViewport(
            size: CGSize(width: 390, height: 400), previous: first.size))
        XCTAssertEqual(second.size.height, 400)
    }

    // MARK: - Wire fields (what the host actually receives)

    /// Width/height go out in measured order, and a portrait viewport yields a portrait
    /// `clientViewportAspect`. This is the field the host feeds to `AdaptiveWindowSizing`, so an
    /// inversion here is exactly the letterbox regression.
    func testSizingRequestFieldsPreservePortraitOrdering() throws {
        let portrait = CGSize(width: 390, height: 794)
        let fields = AppStreamViewModel.sizingRequestFields(
            viewport: portrait, aspect: 390.0 / 794.0, mode: .adaptive, hostAcknowledgedSizing: true)
        let width = try XCTUnwrap(fields.width)
        let height = try XCTUnwrap(fields.height)
        XCTAssertEqual(width, 390)
        XCTAssertEqual(height, 794)
        XCTAssertLessThan(width, height, "portrait request must not be reordered into landscape")
        XCTAssertEqual(try XCTUnwrap(fields.aspect), 390.0 / 794.0, accuracy: 0.0001)
    }

    /// The legacy aspect hint must be withheld until the host acknowledges sizing support, and in
    /// Original mode. Otherwise an older Sync performs the historical narrow-window resize, or a
    /// user's explicit Original Size choice is silently overridden.
    func testSizingRequestFieldsGateTheLegacyAspectHint() {
        let viewport = CGSize(width: 390, height: 794)
        let aspect = 390.0 / 794.0

        XCTAssertNil(AppStreamViewModel.sizingRequestFields(
            viewport: viewport, aspect: aspect, mode: .adaptive, hostAcknowledgedSizing: false).aspect,
            "a host that has not acknowledged sizing must not get the legacy aspect hint")
        XCTAssertNil(AppStreamViewModel.sizingRequestFields(
            viewport: viewport, aspect: aspect, mode: .original, hostAcknowledgedSizing: true).aspect,
            "Original mode must not carry a resize aspect")
        XCTAssertNotNil(AppStreamViewModel.sizingRequestFields(
            viewport: viewport, aspect: aspect, mode: .adaptive, hostAcknowledgedSizing: true).aspect)

        // Dimensions still travel in every case: they are metadata, not a resize command.
        for acknowledged in [true, false] {
            for mode: AppWindowSizingMode in [.adaptive, .original] {
                let fields = AppStreamViewModel.sizingRequestFields(
                    viewport: viewport, aspect: aspect, mode: mode, hostAcknowledgedSizing: acknowledged)
                XCTAssertEqual(fields.width, 390)
                XCTAssertEqual(fields.height, 794)
            }
        }
    }

    /// A not-yet-measured viewport must send no dimensions rather than zeros, so the host keeps its
    /// window instead of resizing it to a degenerate size.
    func testSizingRequestFieldsOmitUnmeasuredDimensions() {
        let fields = AppStreamViewModel.sizingRequestFields(
            viewport: .zero, aspect: nil, mode: .adaptive, hostAcknowledgedSizing: true)
        XCTAssertNil(fields.width)
        XCTAssertNil(fields.height)
        XCTAssertNil(fields.aspect)
    }

    // MARK: - Host resize request wiring

    /// A portrait viewport must produce a portrait desired size for every real Stream viewport and
    /// every host display Stream supports. This is the end-to-end geometry the client asks for and
    /// the Sync host applies server-side with the same shared policy.
    func testPortraitViewportYieldsPortraitWindowOnEveryDisplay() throws {
        let viewports: [(Double, Double)] = [
            (320, 568), (375, 667), (390, 794), (390, 844), (393, 852), (430, 932), (440, 956),
        ]
        let displays: [(Double, Double)] = [(1366, 768), (1440, 900), (1920, 1080), (2560, 1440)]
        for (vw, vh) in viewports {
            let measured = try XCTUnwrap(AppStreamViewModel.measuredViewport(
                size: CGSize(width: vw, height: vh), previous: .zero))
            let fields = AppStreamViewModel.sizingRequestFields(
                viewport: CGSize(width: vw, height: vh),
                aspect: measured.aspect,
                mode: .adaptive,
                hostAcknowledgedSizing: true)
            let requestedAspect = try XCTUnwrap(fields.aspect)
            XCTAssertLessThan(requestedAspect, 1, "\(Int(vw))x\(Int(vh)) must request a portrait aspect")
            for (dw, dh) in displays {
                let available = DesktopSize(width: dw - 48, height: dh - 76)
                let size = AdaptiveWindowSizing.size(
                    original: DesktopSize(width: 1100, height: 700),
                    available: available,
                    viewport: DesktopSize(width: vw, height: vh),
                    bundleIdentifier: "com.openai.codex")
                let context = "\(Int(vw))x\(Int(vh)) on \(Int(dw))x\(Int(dh))"
                XCTAssertLessThan(size.width, size.height, context)
                XCTAssertEqual(size.width / size.height, requestedAspect, accuracy: 0.02,
                    "\(context): host result must match the requested aspect")
            }
        }
    }
}

