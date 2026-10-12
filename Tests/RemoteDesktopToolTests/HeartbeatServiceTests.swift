import XCTest
@testable import TransportWebRTC
import SharedProtocol

final class HeartbeatServiceTests: XCTestCase {

    // MARK: - Mock Transport

    actor MockHeartbeatTransport: HeartbeatService.HeartbeatTransport {
        var sentPings: [PingMessage] = []
        var sentPongs: [PongMessage] = []
        var shouldFailSend = false

        func sendPing(_ message: PingMessage) async throws {
            if shouldFailSend { throw MockError.sendFailed }
            sentPings.append(message)
        }

        func sendPong(_ message: PongMessage) async throws {
            if shouldFailSend { throw MockError.sendFailed }
            sentPongs.append(message)
        }

        func setShouldFail(_ fail: Bool) {
            shouldFailSend = fail
        }

        enum MockError: Error { case sendFailed }
    }

    // MARK: - State Tests

    func testInitialStateIsIdle() async {
        let transport = MockHeartbeatTransport()
        let service = HeartbeatService(transport: transport)
        let state = await service.currentState
        XCTAssertEqual(state, .idle)
    }

    func testStartTransitionsToRunning() async {
        let transport = MockHeartbeatTransport()
        let service = HeartbeatService(transport: transport)
        await service.start()
        let state = await service.currentState
        XCTAssertEqual(state, .running)
        await service.stop()
    }

    func testStopTransitionsToStopped() async {
        let transport = MockHeartbeatTransport()
        let service = HeartbeatService(transport: transport)
        await service.start()
        await service.stop()
        let state = await service.currentState
        XCTAssertEqual(state, .stopped)
    }

    func testReceivedPongResetsMissedCount() async {
        let transport = MockHeartbeatTransport()
        let service = HeartbeatService(transport: transport)
        await service.start()

        let ping = PingMessage()
        let pong = PongMessage(id: ping.id, sentAt: ping.sentAt)
        await service.receivedPong(pong)

        let missed = await service.currentMissedPongs
        XCTAssertEqual(missed, 0)
        await service.stop()
    }

    func testReceivedPingRepliesWithPong() async {
        let transport = MockHeartbeatTransport()
        let service = HeartbeatService(transport: transport)
        await service.start()

        let ping = PingMessage()
        await service.receivedPing(ping)

        let pongs = await transport.sentPongs
        XCTAssertEqual(pongs.count, 1)
        XCTAssertEqual(pongs.first?.id, ping.id)
        await service.stop()
    }

    func testPongIncrementsDiagnosticCounter() async {
        let transport = MockHeartbeatTransport()
        let service = HeartbeatService(transport: transport)
        await service.start()

        let pong1 = PongMessage(id: UUID(), sentAt: Date())
        let pong2 = PongMessage(id: UUID(), sentAt: Date())
        await service.receivedPong(pong1)
        await service.receivedPong(pong2)

        let count = await service.pongsReceived
        XCTAssertEqual(count, 2)
        await service.stop()
    }

    func testStaleDetectionViaStateStream() async {
        // Use very short intervals for testing
        let config = HeartbeatService.Configuration(
            pingInterval: 0.05,
            pongTimeout: 0.01,
            maxMissedPongs: 2
        )
        let transport = MockHeartbeatTransport()
        let service = HeartbeatService(configuration: config, transport: transport)

        // Subscribe to state updates
        let stateStream = await service.stateUpdates()

        await service.start()

        // Wait enough for missed pongs to accumulate
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        var sawStale = false
        var stateCount = 0
        for await state in stateStream {
            stateCount += 1
            if state == .stale { sawStale = true; break }
            if stateCount > 20 { break } // Safety limit
        }

        XCTAssertTrue(sawStale, "Expected heartbeat to report stale state after missed pongs")
        await service.stop()
    }

    func testPongRecoverFromStale() async {
        let config = HeartbeatService.Configuration(
            pingInterval: 0.05,
            pongTimeout: 0.01,
            maxMissedPongs: 1
        )
        let transport = MockHeartbeatTransport()
        let service = HeartbeatService(configuration: config, transport: transport)
        await service.start()

        // Let it go stale
        try? await Task.sleep(nanoseconds: 300_000_000)

        let stateAfterStale = await service.currentState
        XCTAssertEqual(stateAfterStale, .stale)

        // Receive a pong to recover
        await service.receivedPong(PongMessage(id: UUID(), sentAt: Date()))
        let stateAfterRecovery = await service.currentState
        XCTAssertEqual(stateAfterRecovery, .running)

        await service.stop()
    }

    func testRestartAfterStop() async {
        let transport = MockHeartbeatTransport()
        let service = HeartbeatService(transport: transport)
        await service.start()
        await service.stop()

        let stoppedState = await service.currentState
        XCTAssertEqual(stoppedState, .stopped)

        await service.start()
        let restartedState = await service.currentState
        XCTAssertEqual(restartedState, .running)
        await service.stop()
    }
}
