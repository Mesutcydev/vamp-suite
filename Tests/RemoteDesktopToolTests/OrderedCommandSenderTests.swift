import XCTest
import SharedUtilities

@MainActor
final class OrderedCommandSenderTests: XCTestCase {
    func testBurstPreservesEveryCommandIncludingFinalRelease() async {
        var received: [Int] = []
        let delivered = expectation(description: "All commands delivered")
        let sender = OrderedCommandSender<Int>(send: { value in
            received.append(value)
            if value == 300 { delivered.fulfill() }
        }, onFailure: { XCTFail($0) })
        // The sender cannot run until this MainActor turn yields. This burst exceeds
        // the old 128-slot queue and models a final key-up after buffered commands.
        for value in 0...300 { XCTAssertTrue(sender.enqueue(value)) }
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertEqual(received, Array(0...300))
    }

    func testOverflowFailsOnceAndRejectsFurtherInput() {
        var failures: [String] = []
        let sender = OrderedCommandSender<Int>(capacity: 2, send: { _ in }, onFailure: { failures.append($0) })
        XCTAssertTrue(sender.enqueue(1))
        XCTAssertTrue(sender.enqueue(2))
        XCTAssertFalse(sender.enqueue(3))
        XCTAssertFalse(sender.enqueue(4))
        XCTAssertEqual(failures.count, 1)
    }
}
