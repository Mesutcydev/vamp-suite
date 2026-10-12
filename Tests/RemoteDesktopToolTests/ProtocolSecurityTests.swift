import XCTest
@testable import TransportWebRTC
@testable import InputControl
@testable import SharedModels
@testable import SharedProtocol

// MARK: - Data Channel Payload Size Tests

final class DataChannelPayloadSizeTests: XCTestCase {

    func testWireDecodeRejectsOversizedPayload() throws {
        // Create a payload that exceeds the 1 MB limit
        let oversized = Data(repeating: 0x41, count: DataChannelEnvelope.maxWirePayloadBytes + 1)
        XCTAssertThrowsError(try DataChannelEnvelope.wireDecode(oversized)) { error in
            guard let err = error as? DataChannelEnvelopeError,
                  case .oversizedPayload(let actual, let limit) = err else {
                XCTFail("Expected oversizedPayload, got \(error)")
                return
            }
            XCTAssertGreaterThan(actual, limit)
        }
    }

    func testWireDecodeAcceptsPayloadAtLimit() throws {
        // A valid but minimal envelope at exactly max size would pass the size check
        // (JSON decoding may still fail; we're testing the size gate only)
        let atLimit = Data(repeating: 0x41, count: DataChannelEnvelope.maxWirePayloadBytes)
        XCTAssertThrowsError(try DataChannelEnvelope.wireDecode(atLimit)) { error in
            // Should fail on JSON decoding, NOT on size limit
            XCTAssertFalse(error is DataChannelEnvelopeError, "Should not be a size error at the exact limit")
        }
    }

    func testWireDecodeAcceptsSmallValidPayload() throws {
        let message = PingMessage()
        let envelope = try DataChannelEnvelope.ping(message)
        let wireData = try envelope.wireEncode()
        let decoded = try DataChannelEnvelope.wireDecode(wireData)
        XCTAssertEqual(decoded.kind, .ping)
    }
}

// MARK: - Envelope Timestamp Tests

final class EnvelopeTimestampTests: XCTestCase {

    func testFreshEnvelopeHasAcceptableTimestamp() throws {
        let envelope = DataChannelEnvelope(kind: .ping, timestamp: Date(), payload: Data())
        XCTAssertTrue(envelope.hasAcceptableTimestamp, "An envelope timestamped now should be acceptable")
    }

    func testSlightlyOldEnvelopeIsAcceptable() throws {
        let slightlyOld = Date().addingTimeInterval(-10)
        let envelope = DataChannelEnvelope(kind: .ping, timestamp: slightlyOld, payload: Data())
        XCTAssertTrue(envelope.hasAcceptableTimestamp, "10-second-old envelope should still be acceptable")
    }

    func testStaleEnvelopeIsRejected() throws {
        let stale = Date().addingTimeInterval(-(DataChannelEnvelope.maxTimestampAgeSeconds + 1))
        let envelope = DataChannelEnvelope(kind: .ping, timestamp: stale, payload: Data())
        XCTAssertFalse(envelope.hasAcceptableTimestamp, "Envelope older than maxTimestampAge should be rejected")
    }

    func testFutureEnvelopeIsRejected() throws {
        let far_future = Date().addingTimeInterval(DataChannelEnvelope.maxTimestampFutureSeconds + 1)
        let envelope = DataChannelEnvelope(kind: .ping, timestamp: far_future, payload: Data())
        XCTAssertFalse(envelope.hasAcceptableTimestamp, "Envelope timestamped in the future should be rejected")
    }

    func testNearFutureEnvelopeIsAccepted() throws {
        // Within the tolerance window (clock skew)
        let nearFuture = Date().addingTimeInterval(DataChannelEnvelope.maxTimestampFutureSeconds - 1)
        let envelope = DataChannelEnvelope(kind: .ping, timestamp: nearFuture, payload: Data())
        XCTAssertTrue(envelope.hasAcceptableTimestamp, "Envelope within future tolerance should be accepted")
    }

    func testExactlyAtStaleBoundaryIsRejected() {
        // Exactly at the boundary (30 s old) — should be rejected
        let boundary = Date().addingTimeInterval(-DataChannelEnvelope.maxTimestampAgeSeconds)
        // Allow 100ms tolerance for test execution
        let envelope = DataChannelEnvelope(kind: .ping, timestamp: boundary.addingTimeInterval(-0.1), payload: Data())
        XCTAssertFalse(envelope.hasAcceptableTimestamp, "Envelope at/past age boundary should be rejected")
    }
}

// MARK: - Scroll Delta Validation Tests

final class ScrollDeltaValidationTests: XCTestCase {

    func testRejectsScrollDeltaExceedingMax() {
        let scroll = ScrollCommand(
            deltaX: Double(11_000),
            deltaY: 0,
            isPrecise: false
        )
        let rejection = InputCommandValidation.validateContent(.scroll(scroll))
        XCTAssertNotNil(rejection, "Scroll delta exceeding maxScrollDelta should be rejected")
    }

    func testRejectsNegativeScrollDeltaExceedingMax() {
        let scroll = ScrollCommand(
            deltaX: 0,
            deltaY: -11_000,
            isPrecise: false
        )
        let rejection = InputCommandValidation.validateContent(.scroll(scroll))
        XCTAssertNotNil(rejection, "Negative scroll delta exceeding maxScrollDelta should be rejected")
    }

    func testAcceptsScrollDeltaWithinMax() {
        let scroll = ScrollCommand(
            deltaX: 100,
            deltaY: -50,
            isPrecise: true
        )
        let rejection = InputCommandValidation.validateContent(.scroll(scroll))
        XCTAssertNil(rejection, "Normal scroll delta should be accepted")
    }

    func testAcceptsScrollDeltaAtExactMax() {
        let scroll = ScrollCommand(
            deltaX: 10_000,
            deltaY: 10_000,
            isPrecise: false
        )
        let rejection = InputCommandValidation.validateContent(.scroll(scroll))
        XCTAssertNil(rejection, "Scroll delta at exactly maxScrollDelta should be accepted")
    }
}

// MARK: - Malformed Packet Tests

final class MalformedPacketTests: XCTestCase {

    func testWireDecodeRejectsEmptyData() {
        XCTAssertThrowsError(try DataChannelEnvelope.wireDecode(Data())) { _ in }
    }

    func testWireDecodeRejectsRandomGarbage() {
        let garbage = Data([0xFF, 0xFE, 0x00, 0x01, 0xAB, 0xCD])
        XCTAssertThrowsError(try DataChannelEnvelope.wireDecode(garbage)) { _ in }
    }

    func testWireDecodeRejectsTruncatedJSON() {
        let truncated = Data("{\"kind\":\"ping\"".utf8)
        XCTAssertThrowsError(try DataChannelEnvelope.wireDecode(truncated)) { _ in }
    }

    func testWireDecodeRejectsUnknownKind() throws {
        // An envelope with an unknown kind string should fail decoding
        let json = """
        {"kind":"unknownKind","timestamp":"2024-01-01T00:00:00Z","payload":""}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try DataChannelEnvelope.wireDecode(json)) { _ in }
    }

    func testRoundTripIntegrity() throws {
        let ping = PingMessage()
        let envelope = try DataChannelEnvelope.ping(ping)
        let wireData = try envelope.wireEncode()
        let decoded = try DataChannelEnvelope.wireDecode(wireData)
        XCTAssertEqual(decoded.kind, .ping)
        XCTAssertEqual(decoded.sessionID, envelope.sessionID)
    }
}

// MARK: - Input Routing: Duplicate Session ID Tests

final class InputRoutingDuplicateSessionTests: XCTestCase {

    func testMismatchedSessionIDAlwaysRejects() {
        let active = UUID()
        for _ in 0..<20 {
            let foreign = UUID()
            let result = InputCommandValidation.validateRouting(
                commandSessionID: foreign,
                activeSessionID: active,
                isRouterEnabled: true,
                connectionState: .connected
            )
            XCTAssertEqual(result, .sessionMismatch(expected: active, received: foreign))
        }
    }

    func testDisabledRouterRejectsAllCommands() {
        let id = UUID()
        // Even a matching session ID is rejected when the router is disabled
        let result = InputCommandValidation.validateRouting(
            commandSessionID: id,
            activeSessionID: id,
            isRouterEnabled: false,
            connectionState: .connected
        )
        XCTAssertEqual(result, .routerDisabled)
    }
}

// MARK: - Payload Limit Constants Tests

final class PayloadLimitConstantsTests: XCTestCase {

    func testMaxWirePayloadIsOneMegabyte() {
        XCTAssertEqual(DataChannelEnvelope.maxWirePayloadBytes, 1_048_576)
    }

    func testTimestampWindowsAreReasonable() {
        XCTAssertGreaterThan(DataChannelEnvelope.maxTimestampAgeSeconds, 0)
        XCTAssertLessThanOrEqual(DataChannelEnvelope.maxTimestampAgeSeconds, 60,
            "Replay window > 60s is too permissive")
        XCTAssertGreaterThan(DataChannelEnvelope.maxTimestampFutureSeconds, 0)
        XCTAssertLessThanOrEqual(DataChannelEnvelope.maxTimestampFutureSeconds, 30,
            "Forward-clock tolerance > 30s is too permissive")
    }
}
