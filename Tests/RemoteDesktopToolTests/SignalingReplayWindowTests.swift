import XCTest
@testable import Discovery
@testable import SharedModels
@testable import SharedProtocol

/// Signaling replay-window behavior. Envelope IDs must stay remembered for the
/// full acceptance window (replay window + clock-skew allowance); otherwise a
/// future-dated envelope's ID could be pruned while the envelope itself is
/// still within the skew tolerance, opening a replay gap.
final class SignalingReplayWindowTests: XCTestCase {
    private func makeMessage(id: UUID = UUID(), sentAt: Date = Date()) -> VersionedSignalingMessage {
        let envelope = SignalingEnvelope(
            id: id,
            protocolVersion: 1,
            sentAt: sentAt,
            sessionID: UUID(),
            sender: SignalingPeer(id: UUID(), role: .client, displayName: "Test Client"),
            event: .hostBusy(HostBusyMessage(hostID: UUID()))
        )
        return VersionedSignalingMessage(envelope: envelope)
    }

    func testFreshEnvelopeIsAcceptedOnceAndReplayIsRejected() {
        let service = BonjourSignalingService()
        let message = makeMessage()
        XCTAssertTrue(service.shouldAcceptMessage(message))
        // Same envelope ID again — a replay — must be rejected.
        XCTAssertFalse(service.shouldAcceptMessage(message))
    }

    func testDistinctEnvelopeIDsAreBothAccepted() {
        let service = BonjourSignalingService()
        XCTAssertTrue(service.shouldAcceptMessage(makeMessage()))
        XCTAssertTrue(service.shouldAcceptMessage(makeMessage()))
    }

    func testFutureDatedEnvelopeWithinSkewIsAcceptedButReplayIsRejected() {
        let service = BonjourSignalingService()
        // 20 seconds in the future: inside the 30-second clock-skew allowance.
        let future = makeMessage(sentAt: Date().addingTimeInterval(20))
        XCTAssertTrue(service.shouldAcceptMessage(future))
        XCTAssertFalse(service.shouldAcceptMessage(future))
    }

    func testEnvelopeBeyondClockSkewAllowanceIsRejected() {
        let service = BonjourSignalingService()
        // 40 seconds in the future exceeds the 30-second skew allowance.
        let tooFarFuture = makeMessage(sentAt: Date().addingTimeInterval(40))
        XCTAssertFalse(service.shouldAcceptMessage(tooFarFuture))
    }

    func testStaleEnvelopeBeyondReplayWindowIsRejected() {
        let service = BonjourSignalingService()
        // 40 seconds old exceeds the 30-second replay window.
        let stale = makeMessage(sentAt: Date().addingTimeInterval(-40))
        XCTAssertFalse(service.shouldAcceptMessage(stale))
    }
}
