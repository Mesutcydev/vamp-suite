import XCTest
@testable import SharedModels

final class SessionStateMachineTests: XCTestCase {
    func testHappyPathTransitionsToControlling() throws {
        var machine = SessionStateMachine()

        try machine.apply(.discoveryStarted)
        XCTAssertEqual(machine.state, .discovering)

        try machine.apply(.hostSelected)
        XCTAssertEqual(machine.state, .connecting)

        try machine.apply(.signalingStarted)
        XCTAssertEqual(machine.state, .signaling)

        try machine.apply(.sessionReady)
        XCTAssertEqual(machine.state, .readyForMedia)

        try machine.apply(.mediaStarted)
        XCTAssertEqual(machine.state, .streaming)

        try machine.apply(.controlStarted)
        XCTAssertEqual(machine.state, .controlling)
    }

    func testPermissionGateTransitionsThroughAwaitingPermissions() throws {
        var machine = SessionStateMachine(initialState: .signaling)

        try machine.apply(.permissionsRequired)
        XCTAssertEqual(machine.state, .awaitingPermissions)

        try machine.apply(.permissionsSatisfied)
        XCTAssertEqual(machine.state, .readyForMedia)
    }

    func testReconnectPathReturnsToReadyForMedia() throws {
        var machine = SessionStateMachine(initialState: .streaming)

        try machine.apply(.reconnectRequested)
        XCTAssertEqual(machine.state, .reconnecting)

        try machine.apply(.reconnectSucceeded)
        XCTAssertEqual(machine.state, .readyForMedia)
    }

    func testInvalidTransitionThrows() {
        var machine = SessionStateMachine(initialState: .idle)

        XCTAssertThrowsError(try machine.apply(.mediaStarted)) { error in
            XCTAssertEqual(
                error as? InvalidSessionTransition,
                InvalidSessionTransition(from: .idle, event: .mediaStarted)
            )
        }
    }

    // MARK: - Reconnect Recovery Paths

    func testReconnectFromControllingReturnsToReadyForMedia() throws {
        var machine = SessionStateMachine(initialState: .controlling)
        try machine.apply(.reconnectRequested)
        XCTAssertEqual(machine.state, .reconnecting)
        try machine.apply(.reconnectSucceeded)
        XCTAssertEqual(machine.state, .readyForMedia)
    }

    func testReconnectFromReadyForMediaWorks() throws {
        var machine = SessionStateMachine(initialState: .readyForMedia)
        try machine.apply(.reconnectRequested)
        XCTAssertEqual(machine.state, .reconnecting)
    }

    func testReconnectViaSignalingGoesToSignaling() throws {
        var machine = SessionStateMachine(initialState: .reconnecting)
        try machine.apply(.signalingStarted)
        XCTAssertEqual(machine.state, .signaling)
    }

    func testReconnectFailureGoesToFailed() throws {
        var machine = SessionStateMachine(initialState: .reconnecting)
        try machine.apply(.failed)
        XCTAssertEqual(machine.state, .failed)
    }

    func testReconnectFromIdleIsInvalid() {
        var machine = SessionStateMachine(initialState: .idle)
        XCTAssertThrowsError(try machine.apply(.reconnectRequested))
    }

    // MARK: - Disconnect / Fail / Reset (global events)

    func testFailedFromAnyState() throws {
        for startState in SessionLifecycleState.allCases {
            var machine = SessionStateMachine(initialState: startState)
            try machine.apply(.failed)
            XCTAssertEqual(machine.state, .failed, "Failed from \(startState)")
        }
    }

    func testResetFromAnyState() throws {
        for startState in SessionLifecycleState.allCases {
            var machine = SessionStateMachine(initialState: startState)
            try machine.apply(.reset)
            XCTAssertEqual(machine.state, .idle, "Reset from \(startState)")
        }
    }

    func testDisconnectedFromAnyState() throws {
        for startState in SessionLifecycleState.allCases {
            var machine = SessionStateMachine(initialState: startState)
            try machine.apply(.disconnected)
            XCTAssertEqual(machine.state, .disconnected, "Disconnected from \(startState)")
        }
    }

    func testDisconnectedCanRediscover() throws {
        var machine = SessionStateMachine(initialState: .disconnected)
        try machine.apply(.discoveryStarted)
        XCTAssertEqual(machine.state, .discovering)
    }

    // MARK: - Control Toggle

    func testControlEndedReturnsToStreaming() throws {
        var machine = SessionStateMachine(initialState: .controlling)
        try machine.apply(.controlEnded)
        XCTAssertEqual(machine.state, .streaming)
    }

    // MARK: - Idle → Connecting (direct host selection)

    func testIdleCanDirectlySelectHost() throws {
        var machine = SessionStateMachine(initialState: .idle)
        try machine.apply(.hostSelected)
        XCTAssertEqual(machine.state, .connecting)
    }

    func testReconnectFromStreamingWorks() throws {
        var machine = SessionStateMachine(initialState: .streaming)
        try machine.apply(.reconnectRequested)
        XCTAssertEqual(machine.state, .reconnecting)
    }
}
