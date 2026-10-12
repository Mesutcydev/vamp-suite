import XCTest

final class MacMenuBarControllerTests: XCTestCase {
    func testRepeatedSemanticStateIsDeduplicated() {
        var gate = MacMenuBarStateGate()

        XCTAssertTrue(gate.accept(.disconnected))
        XCTAssertFalse(gate.accept(.disconnected))
        XCTAssertFalse(gate.accept(.disconnected))

        XCTAssertEqual(gate.effectiveUpdateCount, 1)
    }

    func testOnlySemanticTransitionsAreAccepted() {
        var gate = MacMenuBarStateGate()
        for _ in 0..<500 {
            _ = gate.accept(.connected)
        }
        XCTAssertEqual(gate.current, .connected)
        XCTAssertEqual(gate.effectiveUpdateCount, 1)

        XCTAssertTrue(gate.accept(.warning))
        XCTAssertEqual(gate.effectiveUpdateCount, 2)
    }
}
