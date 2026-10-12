import XCTest
@testable import InputControl
@testable import SharedModels

/// Remote unlock types the password while the Mac is at the login window, where the
/// display-layout query can throw or stall. Text and key injection must NOT depend on
/// the layout, or a failed query would silently abort the unlock keystrokes.
private final class RecordingBridge: PlatformInputBridge, @unchecked Sendable {
    var texts: [String] = []
    var keyCodes: [UInt16] = []
    func postMouseMove(to point: DesktopPoint) throws {}
    func postMouseMoveRelative(deltaX: Double, deltaY: Double) throws {}
    func postMouseButton(_ button: MouseButton, action: ButtonAction, at point: DesktopPoint?) throws {}
    func postScroll(deltaX: Double, deltaY: Double, isPrecise: Bool) throws {}
    func postKeyEvent(keyCode: UInt16, action: KeyAction, modifiers: KeyboardModifierFlags) throws { keyCodes.append(keyCode) }
    func postTextInput(_ text: String) throws { texts.append(text) }
}

private struct LayoutUnavailable: Error {}

final class HostInputInjectionLockScreenTests: XCTestCase {
    func testLoginWindowTextUsesPhysicalANSIKeyCodesForASCII() {
        XCTAssertEqual(CGEventInputBridge.physicalKey(for: "a"), .init(keyCode: 0, modifiers: []))
        XCTAssertEqual(CGEventInputBridge.physicalKey(for: "A"), .init(keyCode: 0, modifiers: .shift))
        XCTAssertEqual(CGEventInputBridge.physicalKey(for: "9"), .init(keyCode: 25, modifiers: []))
        XCTAssertEqual(CGEventInputBridge.physicalKey(for: "!"), .init(keyCode: 18, modifiers: .shift))
        XCTAssertNil(CGEventInputBridge.physicalKey(for: "ğ"))
    }

    private func makeService(_ bridge: RecordingBridge) -> HostInputInjectionService {
        HostInputInjectionService(
            bridge: bridge,
            accessibilityChecker: { true },
            layoutProvider: { throw LayoutUnavailable() }
        )
    }

    func testTextInjectionSucceedsWhenLayoutQueryFails() async throws {
        let bridge = RecordingBridge()
        try await makeService(bridge).inject(.text(TextInputCommand(text: "0310")))
        XCTAssertEqual(bridge.texts, ["0310"])
    }

    func testKeyInjectionSucceedsWhenLayoutQueryFails() async throws {
        let bridge = RecordingBridge()
        try await makeService(bridge).inject(.key(KeyCommand(keyCode: 36, action: .down)))
        XCTAssertEqual(bridge.keyCodes, [36])
    }

    func testPointerInjectionStillFailsWhenLayoutQueryFails() async {
        let bridge = RecordingBridge()
        let command = InputCommand.pointerMove(
            PointerMoveCommand(location: DesktopPoint(x: 1, y: 1), displayID: "x", isAbsolute: true)
        )
        do {
            try await makeService(bridge).inject(command)
            XCTFail("Pointer injection must surface a failed layout query, not silently pass")
        } catch {
            // expected — pointer commands legitimately need the layout
        }
    }
}
