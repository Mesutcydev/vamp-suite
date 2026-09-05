import XCTest
import UIKit
import SharedModels
@testable import Vamp_Stream

@MainActor
final class AppStreamGesturePolicyTests: XCTestCase {
    private func coordinator(adjusting: Bool) -> AppStreamGestureView.Coordinator {
        let view = AppStreamGestureView(
            allowsViewportAdjustment: adjusting,
            onTap: { _ in }, onDoubleTap: { _ in }, onRightClick: { _ in },
            onMiddleClick: { _ in }, onPointerMove: { _ in }, onPointerEnded: {},
            onScroll: { _, _ in }, onLongPress: { _ in }, onHoverDelta: { _, _ in })
        return view.makeCoordinator()
    }

    func testControlModeRejectsPinchButAllowsScrollingAtAnyZoom() {
        let sut = coordinator(adjusting: false)
        sut.viewportZoom = 3
        let scroll = UIPanGestureRecognizer()
        scroll.minimumNumberOfTouches = 2
        XCTAssertFalse(sut.gestureRecognizerShouldBegin(UIPinchGestureRecognizer()))
        XCTAssertTrue(sut.gestureRecognizerShouldBegin(scroll))
        XCTAssertTrue(sut.gestureRecognizerShouldBegin(UITapGestureRecognizer()))
    }

    func testAdjustmentModeAllowsPinchAndPanWithoutRemoteClicks() {
        let sut = coordinator(adjusting: true)
        let pan = UIPanGestureRecognizer()
        pan.minimumNumberOfTouches = 2
        XCTAssertTrue(sut.gestureRecognizerShouldBegin(UIPinchGestureRecognizer()))
        XCTAssertTrue(sut.gestureRecognizerShouldBegin(pan))
        XCTAssertFalse(sut.gestureRecognizerShouldBegin(UITapGestureRecognizer()))
        XCTAssertFalse(sut.gestureRecognizerShouldBegin(UILongPressGestureRecognizer()))
        XCTAssertTrue(sut.gestureRecognizerShouldBegin(UIPanGestureRecognizer()))
    }
    func testOneFingerAdjustmentMovesPictureWithoutSendingMacInput() {
        var pans: [CGSize] = []
        var pointerEvents = 0
        var view = AppStreamGestureView(
            allowsViewportAdjustment: true,
            onTap: { _ in }, onDoubleTap: { _ in }, onRightClick: { _ in },
            onMiddleClick: { _ in }, onPointerMove: { _ in pointerEvents += 1 },
            onPointerEnded: { pointerEvents += 1 }, onScroll: { _, _ in },
            onLongPress: { _ in }, onHoverDelta: { _, _ in })
        view.onViewportPan = { pans.append($0) }
        let sut = view.makeCoordinator()
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let pan = TestPanRecognizer()
        surface.addGestureRecognizer(pan)
        pan.testState = .began
        sut.onPointerPan(pan)
        pan.testState = .changed
        pan.testTranslation = CGPoint(x: 30, y: 45)
        sut.onPointerPan(pan)
        pan.testTranslation = CGPoint(x: 50, y: 55)
        sut.onPointerPan(pan)
        pan.testState = .ended
        sut.onPointerPan(pan)
        XCTAssertEqual(pans, [CGSize(width: 30, height: 45), CGSize(width: 20, height: 10)])
        XCTAssertEqual(pointerEvents, 0)
    }

    private final class TestPanRecognizer: UIPanGestureRecognizer {
        var testState: UIGestureRecognizer.State = .possible
        var testTranslation: CGPoint = .zero
        override var state: UIGestureRecognizer.State {
            get { testState }
            set { testState = newValue }
        }
        override func translation(in view: UIView?) -> CGPoint { testTranslation }
    }

    func testInputSuspensionReleasesDragAndRejectsNewDrag() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "Input suspension test")
        let input = AppStreamInputController(webRTC: environment.webRTCSessionManager)
        let descriptor = DisplayDescriptor(id: "42", name: "Window",
            frame: DesktopRect(origin: .zero, size: DesktopSize(width: 800, height: 600)),
            pixelSize: DesktopSize(width: 1600, height: 1200), scaleFactor: 2,
            isPrimary: true, isActive: true)
        input.setWindow(descriptor)
        input.setViewSize(DesktopSize(width: 400, height: 600))
        input.toggleDragLock(at: DesktopPoint(x: 200, y: 300))
        XCTAssertFalse(input.dragLocked)
        input.isEnabled = true
        input.toggleDragLock(at: DesktopPoint(x: 200, y: 300))
        XCTAssertTrue(input.dragLocked)
        input.isEnabled = false
        XCTAssertFalse(input.dragLocked)
        input.toggleDragLock(at: DesktopPoint(x: 200, y: 300))
        XCTAssertFalse(input.dragLocked)
        XCTAssertEqual(input.commandsSent, 0, "No attachment means no commands leave the controller")
    }

    func testFailedConnectionDoesNotKeepSessionScreenVisible() {
        let allocatedID = UUID()
        XCTAssertFalse(VampStreamRootView.shouldPresentSession(sessionID: allocatedID, phase: .error))
        XCTAssertFalse(VampStreamRootView.shouldPresentSession(sessionID: allocatedID, phase: .idle))
        XCTAssertFalse(VampStreamRootView.shouldPresentSession(sessionID: nil, phase: .waitingForMedia))
        XCTAssertTrue(VampStreamRootView.shouldPresentSession(sessionID: allocatedID, phase: .waitingForMedia))
        XCTAssertTrue(VampStreamRootView.shouldPresentSession(sessionID: allocatedID, phase: .receiving))
    }

    func testFirstFrameClearsStallBeforeTheNextTimerTick() {
        XCTAssertTrue(AppStreamVideoHealth.isStalled(lastDecodedAt: nil, now: 100))
        XCTAssertFalse(AppStreamVideoHealth.isStalled(lastDecodedAt: 100.2, now: 100))
        XCTAssertFalse(AppStreamVideoHealth.needsRecovery(lastDecodedAt: 106.2, startedAt: 100, now: 106))
    }

    func testRecoveryIsQuietDuringStartupButAppearsForGenuineStalls() {
        XCTAssertFalse(AppStreamVideoHealth.needsRecovery(lastDecodedAt: nil, startedAt: 100, now: 102))
        XCTAssertFalse(AppStreamVideoHealth.needsRecovery(lastDecodedAt: 50, startedAt: 100, now: 102))
        XCTAssertTrue(AppStreamVideoHealth.needsRecovery(lastDecodedAt: nil, startedAt: 100, now: 106))
        XCTAssertTrue(AppStreamVideoHealth.needsRecovery(lastDecodedAt: 110, startedAt: 100, now: 116))
        XCTAssertFalse(AppStreamVideoHealth.needsRecovery(lastDecodedAt: 116.1, startedAt: 100, now: 116))
    }

    func testStreamSupportsOnlyPortrait() {
        let delegate = VampStreamAppDelegate()
        XCTAssertEqual(delegate.application(.shared, supportedInterfaceOrientationsFor: nil), .portrait)
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["UISupportedInterfaceOrientations"] as? [String], ["UIInterfaceOrientationPortrait"])
    }

}
