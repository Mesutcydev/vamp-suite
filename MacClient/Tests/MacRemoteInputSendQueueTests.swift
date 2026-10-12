import SharedModels
import SharedProtocol
import XCTest

final class MacRemoteInputSendQueueTests: XCTestCase {
    private let sessionID = UUID()

    func testPausingDropsQueuedInputButPreservesReleases() {
        var queue = MacRemoteInputSendQueue()
        queue.enqueue(message(.key(KeyCommand(keyCode: 126, action: .down, modifiers: []))))
        queue.enqueue(message(.key(KeyCommand(keyCode: 126, action: .up, modifiers: []))))
        queue.enqueue(message(move(x: 10)))
        queue.enqueue(message(.pointerButton(PointerButtonCommand(button: .left, action: .up))))
        queue.discardPendingInteractions()
        XCTAssertEqual(queue.messages.count, 2)
        guard case .key(let key) = queue.popFirst()?.command,
              case .pointerButton(let button) = queue.popFirst()?.command else {
            return XCTFail("Only releases should remain")
        }
        XCTAssertEqual(key.action, .up)
        XCTAssertEqual(button.action, .up)
    }

    func testPointerBacklogKeepsOnlyLatestPosition() {
        var queue = MacRemoteInputSendQueue()
        for x in 0..<500 {
            queue.enqueue(message(.pointerMove(PointerMoveCommand(
                location: DesktopPoint(x: Double(x), y: 20),
                displayID: "1",
                isAbsolute: true
            ))))
        }

        XCTAssertEqual(queue.messages.count, 1)
        guard case .pointerMove(let move) = queue.popFirst()?.command else {
            return XCTFail("Expected pointer move")
        }
        XCTAssertEqual(move.location.x, 499)
    }

    func testClickIsAnOrderingBarrierForPointerCoalescing() {
        var queue = MacRemoteInputSendQueue()
        queue.enqueue(message(move(x: 10)))
        queue.enqueue(message(.pointerButton(PointerButtonCommand(button: .left, action: .down))))
        queue.enqueue(message(move(x: 20)))
        queue.enqueue(message(move(x: 30)))

        XCTAssertEqual(queue.messages.count, 3)
        guard case .pointerMove(let before) = queue.messages[0].command,
              case .pointerButton = queue.messages[1].command,
              case .pointerMove(let after) = queue.messages[2].command else {
            return XCTFail("Expected move, button, move")
        }
        XCTAssertEqual(before.location.x, 10)
        XCTAssertEqual(after.location.x, 30)
    }

    func testQueuedScrollSamplesAccumulateWithoutCrossingKeyBarrier() {
        var queue = MacRemoteInputSendQueue()
        queue.enqueue(message(.scroll(ScrollCommand(deltaX: 1, deltaY: 2, isPrecise: true))))
        queue.enqueue(message(.scroll(ScrollCommand(deltaX: 3, deltaY: 4, isPrecise: true))))
        queue.enqueue(message(.key(KeyCommand(keyCode: 0, action: .down))))
        queue.enqueue(message(.scroll(ScrollCommand(deltaX: 5, deltaY: 6, isPrecise: false))))

        XCTAssertEqual(queue.messages.count, 3)
        guard case .scroll(let first) = queue.messages[0].command,
              case .scroll(let last) = queue.messages[2].command else {
            return XCTFail("Expected scroll commands around key barrier")
        }
        XCTAssertEqual(first.deltaX, 4)
        XCTAssertEqual(first.deltaY, 6)
        XCTAssertTrue(first.isPrecise)
        XCTAssertEqual(last.deltaX, 5)
        XCTAssertFalse(last.isPrecise)
    }

    func testContinuousInputFromDifferentSessionsNeverCoalesces() {
        var queue = MacRemoteInputSendQueue()
        queue.enqueue(message(move(x: 10)))
        queue.enqueue(InputCommandMessage(sessionID: UUID(), command: move(x: 20)))

        XCTAssertEqual(queue.messages.count, 2)
    }

    private func message(_ command: InputCommand) -> InputCommandMessage {
        InputCommandMessage(sessionID: sessionID, command: command)
    }

    private func move(x: Double) -> InputCommand {
        .pointerMove(PointerMoveCommand(
            location: DesktopPoint(x: x, y: 0),
            displayID: "1",
            isAbsolute: true
        ))
    }
}
