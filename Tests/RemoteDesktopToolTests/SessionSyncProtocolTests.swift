import XCTest
import SharedProtocol
import TransportWebRTC

// MARK: - Session sync protocol (Step D)

final class SessionSyncProtocolTests: XCTestCase {

    func testSyncMessagesRoundTripThroughEnvelopes() throws {
        let sessionID = UUID()

        let request = SessionSyncRequestMessage(sessionID: sessionID, afterSequence: 18472)
        let requestEnvelope = try DataChannelEnvelope.sessionSyncRequest(request)
        XCTAssertEqual(requestEnvelope.kind, .sessionSyncRequest)
        XCTAssertEqual(try requestEnvelope.decodeSessionSyncRequest(), request)

        let snapshot = SessionSnapshotMessage(
            sessionID: sessionID,
            sessionState: "detached",
            lastJournalSequence: 18531,
            terminals: [
                SessionSnapshotMessage.TerminalSnapshot(
                    terminalID: UUID(),
                    workspaceID: UUID(),
                    workspacePath: "/Users/air/Projects/Vamp",
                    cols: 100,
                    rows: 30,
                    state: "running",
                    lastSequence: 9912
                )
            ]
        )
        let snapshotEnvelope = try DataChannelEnvelope.sessionSnapshot(snapshot)
        XCTAssertEqual(snapshotEnvelope.kind, .sessionSnapshot)
        XCTAssertEqual(try snapshotEnvelope.decodeSessionSnapshot(), snapshot)

        let event = SessionSyncEventMessage(
            sessionID: sessionID,
            journalSequence: 18473,
            kind: "taskPlan",
            payload: Data("{}".utf8)
        )
        let eventEnvelope = try DataChannelEnvelope.sessionSyncEvent(event)
        XCTAssertEqual(eventEnvelope.kind, .sessionSyncEvent)
        XCTAssertEqual(try eventEnvelope.decodeSessionSyncEvent(), event)
    }

    func testSyncKindsRequireControlChannelAuthentication() {
        XCTAssertTrue(DataChannelMessageKind.sessionSyncRequest.requiresControlChannelAuthentication)
        XCTAssertTrue(DataChannelMessageKind.sessionSnapshot.requiresControlChannelAuthentication)
        XCTAssertTrue(DataChannelMessageKind.sessionSyncEvent.requiresControlChannelAuthentication)
    }

    /// Older peers do not send `journalSequence`; decoding must default to 0
    /// so a mixed fleet keeps working.
    func testJournalSequenceIsBackwardCompatible() throws {
        let sessionID = UUID()
        let terminalID = UUID()

        let plan = SessionTaskEventMessage(sessionID: sessionID, terminalID: terminalID, event: .planPaused)
        let planObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any]
        )
        var legacyPlanObject = planObject
        legacyPlanObject.removeValue(forKey: "journalSequence")
        let legacyPlanData = try JSONSerialization.data(withJSONObject: legacyPlanObject)
        let decodedPlan = try JSONDecoder().decode(SessionTaskEventMessage.self, from: legacyPlanData)
        XCTAssertEqual(decodedPlan.journalSequence, 0)

        let provider = ProviderSemanticEventMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            provider: .claude,
            event: .completed
        )
        let providerObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(provider)) as? [String: Any]
        )
        var legacyProviderObject = providerObject
        legacyProviderObject.removeValue(forKey: "journalSequence")
        let legacyProviderData = try JSONSerialization.data(withJSONObject: legacyProviderObject)
        let decodedProvider = try JSONDecoder().decode(ProviderSemanticEventMessage.self, from: legacyProviderData)
        XCTAssertEqual(decodedProvider.journalSequence, 0)
        guard case .completed = decodedProvider.event else {
            return XCTFail("expected completed event")
        }
    }

    /// The live messages round-trip their stamped sequence.
    func testLiveMessagesCarryJournalSequence() throws {
        let sessionID = UUID()
        let terminalID = UUID()
        let plan = SessionTaskEventMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            event: .planPaused,
            journalSequence: 42
        )
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(SessionTaskEventMessage.self, from: data)
        XCTAssertEqual(decoded.journalSequence, 42)
    }
}
