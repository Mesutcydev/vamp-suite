import XCTest
@testable import Vamp_Stream

/// The keyboard decks emit Mac virtual keycodes; Vamp Assistant's HTTP input protocol takes
/// key *names*. Every shortcut on the decks used to fall through to "keyNN" and be dropped.
final class AppStreamKeyNameTests: XCTestCase {

    func testShortcutKeycodesResolveToCharacterNames() {
        XCTAssertEqual(AppStreamKeyboardOverlayView.character(forKeyCode: 8), "c")   // ⌘C / ⌃C
        XCTAssertEqual(AppStreamKeyboardOverlayView.character(forKeyCode: 9), "v")   // ⌘V
        XCTAssertEqual(AppStreamKeyboardOverlayView.character(forKeyCode: 0), "a")   // ⌘A
        XCTAssertEqual(AppStreamKeyboardOverlayView.character(forKeyCode: 6), "z")   // ⌘Z
        XCTAssertEqual(AppStreamKeyboardOverlayView.character(forKeyCode: 37), "l")  // ⌃L
        XCTAssertEqual(AppStreamKeyboardOverlayView.character(forKeyCode: 20), "3")  // ⌘⇧3
    }

    func testNamedKeysAreNotCharacters() {
        // Return/Tab/Escape/arrows are named separately and must not collide with the table.
        for keyCode: UInt16 in [36, 53, 123, 124, 125, 126, 115, 119, 116, 121] {
            XCTAssertNil(AppStreamKeyboardOverlayView.character(forKeyCode: keyCode),
                         "keycode \(keyCode) must stay a named key")
        }
    }
}
