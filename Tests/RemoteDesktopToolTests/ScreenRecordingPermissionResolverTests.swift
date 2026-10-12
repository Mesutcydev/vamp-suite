import XCTest
@testable import Permissions
@testable import SharedModels

final class ScreenRecordingPermissionResolverTests: XCTestCase {
    func testGrantedPreflightWinsOverShareableContentError() {
        let state = ScreenRecordingPermissionResolver.resolve(
            preflight: .granted,
            shareableContent: .error,
            timedOut: false
        )
        XCTAssertEqual(state, .granted)
    }

    func testGrantedShareableContentWinsOverDeniedPreflight() {
        let state = ScreenRecordingPermissionResolver.resolve(
            preflight: .denied,
            shareableContent: .granted,
            timedOut: false
        )
        XCTAssertEqual(state, .granted)
    }

    func testShareableContentErrorDoesNotDenyBeforePreflightReturns() {
        let state = ScreenRecordingPermissionResolver.resolve(
            preflight: nil,
            shareableContent: .error,
            timedOut: false
        )
        XCTAssertNil(state)
    }

    func testDeniedWhenBothProbesReject() {
        let state = ScreenRecordingPermissionResolver.resolve(
            preflight: .denied,
            shareableContent: .error,
            timedOut: false
        )
        XCTAssertEqual(state, .denied)
    }

    func testEmptyDisplaysIsDenied() {
        let state = ScreenRecordingPermissionResolver.resolve(
            preflight: nil,
            shareableContent: .deniedEmptyDisplays,
            timedOut: false
        )
        XCTAssertEqual(state, .denied)
    }

    func testTimeoutWithHungPreflightIsUnknown() {
        let state = ScreenRecordingPermissionResolver.resolve(
            preflight: nil,
            shareableContent: .error,
            timedOut: true
        )
        XCTAssertEqual(state, .unknown)
    }

    func testTimeoutWithDeniedPreflightIsDenied() {
        let state = ScreenRecordingPermissionResolver.resolve(
            preflight: .denied,
            shareableContent: nil,
            timedOut: true
        )
        XCTAssertEqual(state, .denied)
    }

    func testStillWaitingWhenNothingFinished() {
        let state = ScreenRecordingPermissionResolver.resolve(
            preflight: nil,
            shareableContent: nil,
            timedOut: false
        )
        XCTAssertNil(state)
    }
}
