#if os(macOS)
import XCTest
import Carbon
@testable import InputControl
import SharedModels

@MainActor
final class LoginWindowInputServiceTests: XCTestCase {
    private typealias Key = LoginWindowInputService.Key

    @MainActor private final class Fixture {
        var locked = true
        var accessibility = true
        var events: [(Key, KeyAction)] = []
        var waits: [Duration] = []
        var onWait: (() throws -> Void)?
        var keys = [Key(code: 18), Key(code: 19, modifiers: .shift)]

        func service() -> LoginWindowInputService {
            LoginWindowInputService(
                isLocked: { self.locked },
                hasAccessibility: { self.accessibility },
                resolveKeys: { $0 == "a" ? [Key(code: 0)] : self.keys },
                postKey: { self.events.append(($0, $1)) },
                sleep: { duration in
                    self.waits.append(duration)
                    try self.onWait?()
                }
            )
        }
    }

    func testWakesAndReplacesPreviousEntryBeforeSubmittingPhysicalKeys() async throws {
        let fixture = Fixture()
        let service = fixture.service()
        for _ in 0..<2 {
            fixture.events = []
            try await service.submit(password: "example")
            let downs = fixture.events.filter { $0.1 == .down }.map(\.0)
            XCTAssertEqual(downs, [Key(code: 49), Key(code: 0, modifiers: .command),
                                   Key(code: 51)] + fixture.keys + [Key(code: 36)])
            XCTAssertEqual(fixture.events.count, downs.count * 2)
            for index in stride(from: 0, to: fixture.events.count, by: 2) {
                XCTAssertEqual(fixture.events[index].0, fixture.events[index + 1].0)
                XCTAssertEqual(fixture.events[index + 1].1, .up)
            }
        }
        XCTAssertTrue(fixture.waits.contains(.milliseconds(750)))
    }

    func testLocalUnlockDuringWakeStopsBeforePasswordAndBalancesKey() async {
        let fixture = Fixture()
        fixture.onWait = { fixture.locked = false }
        do {
            try await fixture.service().submit(password: "example")
            XCTFail("Must stop when the Mac unlocks locally")
        } catch {
            XCTAssertEqual(fixture.events.map(\.0.code), [49, 49])
            XCTAssertEqual(fixture.events.last?.1, .up)
        }
    }

    func testAccessibilityRevocationStopsBeforePassword() async {
        let fixture = Fixture()
        fixture.onWait = { fixture.accessibility = false }
        do {
            try await fixture.service().submit(password: "example")
            XCTFail("Must stop when permission is revoked")
        } catch {
            XCTAssertEqual(fixture.events.map(\.0.code), [49, 49])
        }
    }

    func testCancellationReleasesKeyWithoutSubmittingPassword() async {
        let fixture = Fixture()
        fixture.onWait = { throw CancellationError() }
        do {
            try await fixture.service().submit(password: "example")
            XCTFail("Must propagate cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertEqual(fixture.events.map(\.0.code), [49, 49])
            XCTAssertEqual(fixture.events.last?.1, .up)
        }
    }

    func testUnsupportedLayoutDoesNotPostAnyInputOrIncludePasswordInError() async {
        var posted = false
        let service = LoginWindowInputService(
            isLocked: { true }, hasAccessibility: { true },
            resolveKeys: { _ in throw InputInjectionError.invalidCommand("Unsupported keyboard layout") },
            postKey: { _, _ in posted = true }, sleep: { _ in }
        )
        do {
            try await service.submit(password: "example")
            XCTFail("Must reject unsupported input before wake or submission")
        } catch {
            XCTAssertFalse(posted)
            XCTAssertFalse(error.localizedDescription.contains("example"))
        }
    }

    func testUnavailablePermissionOrUnlockedMacPostsNothing() async {
        for locked in [false, true] {
            let fixture = Fixture()
            fixture.locked = locked
            fixture.accessibility = !locked
            do {
                try await fixture.service().submit(password: "example")
                XCTFail("Must refuse input")
            } catch {
                XCTAssertTrue(fixture.events.isEmpty)
            }
        }
    }

    func testUSAndTurkishLayoutsResolveDifferentPhysicalKeys() throws {
        func layout(_ id: String) throws -> CFData {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            let sources = try XCTUnwrap(TISCreateInputSourceList(filter, true)).takeRetainedValue() as NSArray
            let source = try XCTUnwrap(sources.firstObject) as! TISInputSource
            let raw = try XCTUnwrap(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData))
            return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        }
        let us = try layout("com.apple.keylayout.US")
        let turkish = try layout("com.apple.keylayout.Turkish-QWERTY-PC")
        XCTAssertEqual(try LoginWindowInputService.keys("i", layoutData: us), [Key(code: 34, unicodeString: "i")])
        XCTAssertEqual(try LoginWindowInputService.keys("ı", layoutData: turkish), [Key(code: 34, unicodeString: "ı")])
        XCTAssertNotEqual(try LoginWindowInputService.keys("i", layoutData: turkish), [Key(code: 34, unicodeString: "i")])
        XCTAssertEqual(try LoginWindowInputService.keys("şğıİç", layoutData: turkish).count, 5)
        XCTAssertThrowsError(try LoginWindowInputService.keys("🙂", layoutData: us))
    }
}
#endif
