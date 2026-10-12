import XCTest
@testable import HostApp
@testable import SharedModels
@testable import TransportWebRTC

@MainActor
final class InProcessPipelineIntegrationTests: XCTestCase {
    private var harness: InProcessPipelineHarness?

    override func tearDown() async throws {
        if let harness {
            await harness.stop()
        }
        harness = nil
        try await super.tearDown()
    }

    func testHostAndClientNegotiateSessionOverLoopbackSignaling() async throws {
        let harness = try await InProcessPipelineHarness()
        self.harness = harness

        try await harness.startConnectedSession()

        XCTAssertEqual(harness.hostWebRTC.connectionState, .connected)
        XCTAssertEqual(harness.clientWebRTC.connectionState, .connected)
        XCTAssertEqual(harness.hostWebRTC.dataChannelState, .open)
        XCTAssertEqual(harness.clientWebRTC.dataChannelState, .open)
        XCTAssertEqual(harness.streamingPhase, .bridgeActive)
        XCTAssertNotNil(harness.activeSessionID)
        XCTAssertTrue(harness.hostCapture.isCapturing)
        XCTAssertTrue(harness.hostEncoder.isEncoding)
        XCTAssertTrue(harness.hostInputRouter.isEnabled)
    }

    func testStreamingPipelineDeliversFirstFrameToClient() async throws {
        let harness = try await InProcessPipelineHarness()
        self.harness = harness

        try await harness.startConnectedSession()
        try await harness.emitVideoFrame(sequenceNumber: 1)

        XCTAssertEqual(harness.clientWebRTC.streamDiagnostics.framesReceived, 1)
        XCTAssertEqual(harness.hostWebRTC.streamDiagnostics.framesSent, 1)
        XCTAssertEqual(harness.clientWebRTC.streamDiagnostics.receivingState, .receiving)
    }

    func testClientInputCommandReachesHostInputInjectionService() async throws {
        let harness = try await InProcessPipelineHarness()
        self.harness = harness

        try await harness.startConnectedSession()
        let command = InputCommand.key(KeyCommand(keyCode: 36, action: .down))

        try await harness.sendInputCommand(command)
        do {
            try await waitUntil(timeout: 3.0) {
                !harness.hostInput.snapshotCommands().isEmpty
            }
        } catch {
            XCTFail(harness.debugTrace())
            throw error
        }

        XCTAssertEqual(harness.hostInput.snapshotCommands(), [command])
        XCTAssertEqual(harness.hostInputRouter.commandsProcessed, 1)
        XCTAssertEqual(harness.hostInputRouter.commandsRejected, 0)
    }

    func testStreamingResumesAfterInProcessReconnect() async throws {
        let harness = try await InProcessPipelineHarness()
        self.harness = harness

        try await harness.startConnectedSession()
        try await harness.emitVideoFrame(sequenceNumber: 1)

        harness.simulateDisconnect()
        try await waitUntil(timeout: 3.0) {
            harness.hostWebRTC.connectionState == .disconnected
                && harness.clientWebRTC.connectionState == .disconnected
        }

        harness.simulateReconnect()
        try await waitUntil(timeout: 3.0) {
            harness.hostWebRTC.connectionState == .connected
                && harness.clientWebRTC.connectionState == .connected
        }

        try await waitUntil(timeout: 3.0) {
            await MainActor.run {
                harness.streamingPhase == .bridgeActive
            }
        }

        try await harness.emitVideoFrame(sequenceNumber: 2)

        XCTAssertEqual(harness.clientWebRTC.streamDiagnostics.framesReceived, 2)
        XCTAssertEqual(harness.hostWebRTC.streamDiagnostics.framesSent, 2)
    }
}