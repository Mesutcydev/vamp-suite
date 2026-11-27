import XCTest
@testable import Vamp_Stream

@MainActor
final class VampStreamSplashLifecycleTests: XCTestCase {
    func testPendingFirstFrameCoversTheRootWithoutStartingMotion() async {
        let splash = VampStreamSplashLifecycle(previewsFullSequence: true)
        let owner = UUID()
        XCTAssertTrue(splash.coversRoot(for: owner))
        splash.prepare(owner: owner)
        XCTAssertTrue(splash.coversRoot(for: owner))
        XCTAssertFalse(splash.isVisible(for: owner))
        XCTAssertEqual(splash.elapsed(at: 10), 0)
        XCTAssertNil(splash.deadline)
        XCTAssertTrue(splash.begin(owner: owner, at: 10, isActive: true, reduceMotion: false))
        XCTAssertTrue(splash.coversRoot(for: owner))
    }

    func testPendingCoverDoesNotDelayAnAlreadyUsableRoot() async {
        let splash = VampStreamSplashLifecycle()
        let owner = UUID()
        splash.prepare(owner: owner)
        splash.rootBecameUsable(at: 10)
        XCTAssertFalse(splash.coversRoot(for: owner))
        XCTAssertEqual(splash.phase, .finished)
        XCTAssertFalse(splash.begin(owner: owner, at: 10, isActive: true, reduceMotion: false))
    }

    func testReservedPendingCoverCannotBeTakenByAnotherWindowOrSurviveInactivity() async {
        let splash = VampStreamSplashLifecycle(previewsFullSequence: true)
        let owner = UUID()
        let other = UUID()
        splash.prepare(owner: owner)
        splash.prepare(owner: other)
        XCTAssertFalse(splash.coversRoot(for: other))
        XCTAssertFalse(splash.begin(owner: other, at: 0, isActive: true, reduceMotion: false))
        splash.becameInactive()
        XCTAssertFalse(splash.coversRoot(for: owner))
        XCTAssertFalse(splash.begin(owner: owner, at: 1, isActive: true, reduceMotion: false))
    }

    func testAlreadyUsableRootSkipsAndCannotReplay() async {
        let splash = VampStreamSplashLifecycle()
        let owner = UUID()
        splash.rootBecameUsable(at: 10)
        XCTAssertFalse(splash.begin(owner: owner, at: 11, isActive: true, reduceMotion: false))
        XCTAssertEqual(splash.phase, .finished)
        XCTAssertFalse(splash.isVisible(for: owner))
        XCTAssertNil(splash.deadline)
        XCTAssertFalse(splash.begin(owner: UUID(), at: 12, isActive: true, reduceMotion: false))
    }

    func testReadinessDuringEveryPhaseCancelsChoreographyWithin150Milliseconds() async throws {
        for readyAt in [0.1, 0.6, 1.0] {
            let splash = VampStreamSplashLifecycle()
            let owner = UUID()
            XCTAssertTrue(splash.begin(owner: owner, at: 0, isActive: true, reduceMotion: false))
            splash.rootBecameUsable(at: readyAt)
            XCTAssertEqual(splash.phase, .dismissing)
            let deadline = try XCTUnwrap(splash.deadline)
            XCTAssertEqual(deadline, readyAt + 0.15, accuracy: 0.00001)
            XCTAssertEqual(splash.elapsed(at: deadline), readyAt, accuracy: 0.00001)
            XCTAssertEqual(splash.opacity(at: readyAt), 1)
            XCTAssertEqual(splash.opacity(at: readyAt + 0.075), 0.5, accuracy: 0.00001)
            splash.advance(to: deadline)
            XCTAssertEqual(splash.phase, .finished)
            XCTAssertFalse(splash.isVisible(for: owner))
            XCTAssertNil(splash.deadline)
        }
    }

    func testLateReadinessCannotExtendTheHardCap() async throws {
        let splash = VampStreamSplashLifecycle()
        splash.begin(owner: UUID(), at: 100, isActive: true, reduceMotion: false)
        splash.rootBecameUsable(at: 101.3)
        XCTAssertEqual(try XCTUnwrap(splash.deadline), 101.35, accuracy: 0.00001)
        splash.advance(to: 101.35)
        XCTAssertEqual(splash.phase, .finished)
    }

    func testReadinessAfterTheDeadlineFinishesImmediately() async {
        let splash = VampStreamSplashLifecycle()
        splash.begin(owner: UUID(), at: 0, isActive: true, reduceMotion: false)
        splash.rootBecameUsable(at: 1.4)
        XCTAssertEqual(splash.phase, .finished)
        XCTAssertNil(splash.deadline)
    }

    func testUnavailableLocalStartupStillRevealsFallbackAtTheCap() async {
        let splash = VampStreamSplashLifecycle()
        let owner = UUID()
        splash.begin(owner: owner, at: 10, isActive: true, reduceMotion: false)
        splash.advance(to: 11.349)
        XCTAssertTrue(splash.isVisible(for: owner))
        splash.advance(to: 11.35)
        XCTAssertEqual(splash.phase, .finished)
        XCTAssertFalse(splash.isVisible(for: owner))
        XCTAssertFalse(splash.rootIsUsable)
    }

    func testReducedMotionStartsWithOnlyTheShortDismissal() async throws {
        let splash = VampStreamSplashLifecycle()
        splash.begin(owner: UUID(), at: 50, isActive: true, reduceMotion: true)
        XCTAssertEqual(splash.phase, .dismissing)
        XCTAssertEqual(try XCTUnwrap(splash.deadline), 50.15, accuracy: 0.00001)
        XCTAssertEqual(splash.elapsed(at: 50.1), 0)
        splash.advance(to: 50.15)
        XCTAssertEqual(splash.phase, .finished)
    }

    func testInactiveLaunchDoesNotPresent() async {
        let splash = VampStreamSplashLifecycle()
        let owner = UUID()
        XCTAssertFalse(splash.begin(owner: owner, at: 0, isActive: false, reduceMotion: false))
        XCTAssertEqual(splash.phase, .pending)
        XCTAssertFalse(splash.isVisible(for: owner))
        XCTAssertTrue(splash.begin(owner: owner, at: 1, isActive: true, reduceMotion: false))
    }

    func testBackgroundingEveryPhaseFinishesWithoutReplay() async {
        for time in [0.1, 0.6, 1.0] {
            let splash = VampStreamSplashLifecycle()
            let owner = UUID()
            splash.begin(owner: owner, at: 0, isActive: true, reduceMotion: false)
            splash.advance(to: time)
            splash.becameInactive()
            XCTAssertEqual(splash.phase, .finished)
            XCTAssertNil(splash.deadline)
            XCTAssertFalse(splash.begin(owner: owner, at: 2, isActive: true, reduceMotion: false))
            splash.rootBecameUsable(at: 2)
            splash.advance(to: 3)
            XCTAssertEqual(splash.phase, .finished)
        }
    }

    func testCancellationAndLateCallbacksAreIdempotent() async {
        for time in [0.1, 0.6, 1.0] {
            let splash = VampStreamSplashLifecycle()
            let owner = UUID()
            splash.begin(owner: owner, at: 0, isActive: true, reduceMotion: false)
            splash.cancel(owner: owner)
            splash.cancel(owner: owner)
            splash.dismiss(at: time)
            splash.rootBecameUsable(at: time)
            splash.advance(to: 5)
            XCTAssertEqual(splash.phase, .finished)
            XCTAssertNil(splash.deadline)
            XCTAssertFalse(splash.isVisible(for: owner))
        }
    }

    func testAdditionalWindowCannotOwnOrCancelTheFirstWindowsSplash() async {
        let splash = VampStreamSplashLifecycle()
        let first = UUID()
        let second = UUID()
        splash.begin(owner: first, at: 0, isActive: true, reduceMotion: false)
        XCTAssertFalse(splash.begin(owner: second, at: 0.1, isActive: true, reduceMotion: false))
        XCTAssertFalse(splash.isVisible(for: second))
        splash.cancel(owner: second)
        XCTAssertTrue(splash.isVisible(for: first))
        splash.cancel(owner: first)
        XCTAssertFalse(splash.begin(owner: second, at: 2, isActive: true, reduceMotion: false))
    }

    func testRepeatedDismissalDoesNotResetOrExtendTheFade() async throws {
        let splash = VampStreamSplashLifecycle()
        splash.begin(owner: UUID(), at: 0, isActive: true, reduceMotion: false)
        splash.dismiss(at: 0.2)
        splash.dismiss(at: 0.3)
        splash.rootBecameUsable(at: 0.31)
        XCTAssertEqual(try XCTUnwrap(splash.deadline), 0.35, accuracy: 0.00001)
        XCTAssertEqual(splash.elapsed(at: 0.34), 0.2, accuracy: 0.00001)
        splash.advance(to: 0.35)
        XCTAssertEqual(splash.opacity(at: 0.4), 0)
    }

    func testDebugReferenceFixtureCanExerciseTheFullSequenceWithoutChangingNormalReadiness() async {
        let splash = VampStreamSplashLifecycle(previewsFullSequence: true)
        let owner = UUID()
        splash.rootBecameUsable(at: 0)
        XCTAssertTrue(splash.begin(owner: owner, at: 0, isActive: true, reduceMotion: false))
        splash.rootBecameUsable(at: 0.5)
        XCTAssertEqual(splash.phase, .playing)
        splash.advance(to: 1.35)
        XCTAssertFalse(splash.isVisible(for: owner))
    }
}
