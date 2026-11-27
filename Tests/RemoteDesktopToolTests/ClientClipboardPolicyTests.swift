import XCTest
@testable import ClientiOS
import SharedProtocol

@MainActor
final class ClientClipboardPolicyTests: XCTestCase {
    func testHostClipboardIsIgnoredUnlessTheUserAskedForIt() {
        let manager = ClientClipboardSyncManager()
        let sessionID = UUID()
        manager.activate(sessionID: sessionID) { _ in }

        // The host only ever answers a request. An unsolicited push must not touch the clipboard.
        manager.receive(ClipboardSyncMessage(sessionID: sessionID, text: "unsolicited", source: "host"))

        XCTAssertNil(manager.lastSyncedText)
    }
}
