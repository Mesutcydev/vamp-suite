#if os(macOS)
import XCTest
@testable import HostApp
import SharedModels

final class StoreHostSessionAvailabilityTests: XCTestCase {
    func testUnknownInactiveAndSleepingSnapshotsRemainBlocked() {
        let availability = StoreHostSessionAvailability()
        XCTAssertEqual(availability.state(isOnConsole: true, loginDone: true, displayAwake: true), .unlockedActiveSession)
        for onConsole: Bool? in [nil, false, true] {
            for loginDone: Bool? in [nil, false, true] {
                if onConsole == true && loginDone == true { continue }
                XCTAssertTrue(availability.state(isOnConsole: onConsole, loginDone: loginDone, displayAwake: true).blocksRemoteInput)
            }
        }
        XCTAssertTrue(availability.state(isOnConsole: true, loginDone: true, displayAwake: false).blocksRemoteInput)
    }

    func testWakeDoesNotClearInactiveUserSession() {
        var availability = StoreHostSessionAvailability()
        availability.handle(.sessionInactive)
        availability.handle(.screensSleep)
        availability.handle(.screensWake)
        availability.handle(.systemWake)
        XCTAssertTrue(availability.state(isOnConsole: true, loginDone: true, displayAwake: true).blocksRemoteInput)
        availability.handle(.sessionActive)
        XCTAssertFalse(availability.state(isOnConsole: true, loginDone: true, displayAwake: true).blocksRemoteInput)
    }

    func testSessionActivationDoesNotClearDisplayOrSystemSleep() {
        var availability = StoreHostSessionAvailability()
        availability.handle(.screensSleep)
        availability.handle(.systemSleep)
        availability.handle(.sessionActive)
        availability.handle(.screensWake)
        XCTAssertTrue(availability.state(isOnConsole: true, loginDone: true, displayAwake: true).blocksRemoteInput)
        availability.handle(.systemWake)
        XCTAssertFalse(availability.state(isOnConsole: true, loginDone: true, displayAwake: true).blocksRemoteInput)
    }

    func testWakeStillRequiresAnAvailableSnapshot() {
        var availability = StoreHostSessionAvailability()
        availability.handle(.systemSleep)
        availability.handle(.systemWake)
        availability.handle(.sessionActive)
        XCTAssertTrue(availability.state(isOnConsole: nil, loginDone: nil, displayAwake: true).blocksRemoteInput)
        XCTAssertTrue(availability.state(isOnConsole: true, loginDone: false, displayAwake: true).blocksRemoteInput)
    }
}
#endif
