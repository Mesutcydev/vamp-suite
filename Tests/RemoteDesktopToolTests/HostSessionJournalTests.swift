import XCTest
import SharedProtocol
@testable import HostApp

// MARK: - Durable semantic journal (Step C)

final class HostSessionJournalTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vamp-journal-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
    }

    private func makeJournal() -> HostSessionJournal {
        HostSessionJournal(rootURL: tempRoot)
    }

    private func event(_ journal: HostSessionJournal, sessionID: UUID, type: HostSessionJournal.EventType) -> UInt64 {
        journal.append(sessionID: sessionID, type: type, payload: Data("payload-\(type.rawValue)".utf8))
    }

    func testMonotonicSequencesAndReplayDelta() {
        let journal = makeJournal()
        let sessionID = UUID()

        let first = event(journal, sessionID: sessionID, type: .taskPlan)
        let second = event(journal, sessionID: sessionID, type: .providerSemantic)
        let third = event(journal, sessionID: sessionID, type: .agentPrompt)

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(third, 3)
        XCTAssertEqual(journal.lastSequence(sessionID: sessionID), 3)

        // Replay the delta after sequence 1: only 2 and 3.
        let delta = journal.events(sessionID: sessionID, after: 1)
        XCTAssertEqual(delta.map(\.sequence), [2, 3])
        XCTAssertEqual(delta.map(\.type), [.providerSemantic, .agentPrompt])

        // Nothing after the latest sequence.
        XCTAssertTrue(journal.events(sessionID: sessionID, after: 3).isEmpty)
    }

    func testSequencesContinueAcrossInstances() {
        let sessionID = UUID()

        let first = makeJournal()
        _ = event(first, sessionID: sessionID, type: .taskPlan)
        _ = event(first, sessionID: sessionID, type: .agentPrompt)
        first.flush(sessionID: sessionID)

        // A new instance in the same directory must continue numbering.
        let second = makeJournal()
        second.load()
        let next = event(second, sessionID: sessionID, type: .providerSemantic)
        XCTAssertEqual(next, 3, "journal must continue sequences across reloads")
        XCTAssertEqual(second.lastSequence(sessionID: sessionID), 3)
        XCTAssertEqual(second.events(sessionID: sessionID, after: 0).count, 3)
    }

    func testPayloadRoundTripForWireMessages() throws {
        let journal = makeJournal()
        let sessionID = UUID()

        let plan = SessionTaskEventMessage(
            sessionID: sessionID,
            terminalID: UUID(),
            event: .planPaused
        )
        let payload = try JSONEncoder().encode(plan)
        journal.append(sessionID: sessionID, type: .taskPlan, payload: payload)

        let replay = try XCTUnwrap(journal.events(sessionID: sessionID, after: 0).first)
        let decoded = try JSONDecoder().decode(SessionTaskEventMessage.self, from: replay.payload)
        XCTAssertEqual(decoded.sessionID, sessionID)
        guard case .planPaused = decoded.event else {
            return XCTFail("expected planPaused event")
        }
    }

    func testCompactionKeepsNewestEventsUnderBudget() {
        let journal = makeJournal()
        let sessionID = UUID()

        // The byte budget (2 MB) is far away; use many large events so the
        // file grows, then verify the tail survives compaction by checking
        // sequence continuity through a fresh instance.
        let big = Data(repeating: 0x61, count: 8 * 1024)
        for _ in 0..<400 {
            journal.append(sessionID: sessionID, type: .providerSemantic, payload: big)
        }
        let last = journal.append(sessionID: sessionID, type: .agentPrompt, payload: Data("final".utf8))
        journal.flush(sessionID: sessionID)

        let reloaded = makeJournal()
        reloaded.load()
        XCTAssertEqual(reloaded.lastSequence(sessionID: sessionID), last)
        // The final event must be readable regardless of compaction.
        let tail = reloaded.events(sessionID: sessionID, after: last - 1)
        XCTAssertEqual(tail.count, 1)
        XCTAssertEqual(tail.first?.type, .agentPrompt)
        XCTAssertEqual(tail.first.map { String(data: $0.payload, encoding: .utf8) }, "final")
    }

    func testRemoveDeletesFileAndStopsReplay() {
        let journal = makeJournal()
        let sessionID = UUID()
        _ = event(journal, sessionID: sessionID, type: .taskPlan)

        journal.remove(sessionID: sessionID)
        XCTAssertEqual(journal.lastSequence(sessionID: sessionID), 0)
        XCTAssertTrue(journal.events(sessionID: sessionID, after: 0).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("\(sessionID.uuidString).jsonl").path))
    }
}
