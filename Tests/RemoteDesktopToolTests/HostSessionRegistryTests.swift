import XCTest
@testable import HostApp

// MARK: - Durable host session registry (Step B)

final class HostSessionRegistryTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vamp-registry-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
    }

    private func makeRegistry(signature: String = "test-process") -> HostSessionRegistry {
        HostSessionRegistry(rootURL: tempRoot, processSignature: signature)
    }

    private func makeTerminal(_ id: UUID = UUID()) -> HostSessionRegistry.TerminalRecord {
        HostSessionRegistry.TerminalRecord(
            terminalID: id,
            workspaceID: UUID(),
            workspacePath: "/Users/test/Projects/Demo",
            cols: 100,
            rows: 30,
            lastSequence: 42,
            state: .running,
            createdAt: Date(),
            lastActivityAt: Date()
        )
    }

    func testRoundTripAcrossInstancesInSameProcess() throws {
        let sessionID = UUID()
        let terminal = makeTerminal()

        let first = makeRegistry()
        first.upsertSession(sessionID)
        first.recordTerminalOpened(terminal, sessionID: sessionID)
        first.markSessionDetached(sessionID)

        // Same process signature: a reload must preserve state exactly.
        let second = makeRegistry()
        second.load(reapedGrace: 3600)

        let record = try XCTUnwrap(second.sessionRecord(sessionID))
        XCTAssertEqual(record.state, .detached)
        XCTAssertEqual(record.terminals.count, 1)
        XCTAssertEqual(record.terminals.first?.terminalID, terminal.terminalID)
        XCTAssertEqual(record.terminals.first?.lastSequence, 42)
        XCTAssertEqual(record.terminals.first?.workspacePath, "/Users/test/Projects/Demo")
    }

    func testPreviousProcessRecordsAreReconciledToReaped() throws {
        let sessionID = UUID()

        let stale = makeRegistry(signature: "older-process")
        stale.upsertSession(sessionID)
        stale.recordTerminalOpened(makeTerminal(), sessionID: sessionID)

        // A NEW process loads the same directory: PTYs died with the old
        // process, so the record must be reconciled to reaped — clients must
        // learn the truth instead of believing the shell is still alive.
        let fresh = makeRegistry(signature: "newer-process")
        fresh.load(reapedGrace: 60 * 60)

        let record = try XCTUnwrap(fresh.sessionRecord(sessionID))
        XCTAssertEqual(record.state, .reaped, "stale-process sessions must reconcile to reaped")
        XCTAssertTrue(record.terminals.allSatisfy { $0.state == .reaped })
    }

    func testReapedGracePrunesStaleRecordsOnLoad() throws {
        let sessionID = UUID()

        let stale = makeRegistry(signature: "older-process")
        stale.upsertSession(sessionID)

        let fresh = makeRegistry(signature: "newer-process")
        fresh.load(reapedGrace: 0)  // no grace: prune immediately
        XCTAssertNil(fresh.sessionRecord(sessionID))
    }

    func testDetachedRetentionQuery() throws {
        let registry = makeRegistry()
        let aliveSession = UUID()
        let expiredSession = UUID()

        registry.upsertSession(aliveSession)
        registry.upsertSession(expiredSession)
        registry.markSessionDetached(aliveSession)
        registry.markSessionDetached(expiredSession)

        // Retention 0 flags every detached session; a 24 h retention flags
        // none of these freshly-detached ones.
        let expiredNow = registry.expiredDetachedSessions(now: Date(), retention: 0)
        XCTAssertTrue(expiredNow.contains(expiredSession), "retention 0 must flag every detached session")
        XCTAssertTrue(expiredNow.contains(aliveSession))

        let noneExpired = registry.expiredDetachedSessions(now: Date(), retention: 24 * 3600)
        XCTAssertFalse(noneExpired.contains(expiredSession), "fresh detached sessions must not be expired")
    }

    func testAllTerminalsReapedMarksSessionReapedAndRemoveDeletesFile() throws {
        let registry = makeRegistry()
        let sessionID = UUID()
        let terminalA = UUID()
        let terminalB = UUID()

        registry.upsertSession(sessionID)
        registry.recordTerminalOpened(makeTerminal(terminalA), sessionID: sessionID)
        registry.recordTerminalOpened(makeTerminal(terminalB), sessionID: sessionID)

        registry.markTerminalReaped(sessionID: sessionID, terminalID: terminalA, lastSequence: 7)
        XCTAssertEqual(registry.sessionRecord(sessionID)?.state, .running,
                       "session stays running while one terminal survives")

        registry.markTerminalReaped(sessionID: sessionID, terminalID: terminalB, lastSequence: 9)
        XCTAssertEqual(registry.sessionRecord(sessionID)?.state, .reaped,
                       "all terminals reaped must mark the session reaped")

        let file = tempRoot.appendingPathComponent("\(sessionID.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        registry.removeSession(sessionID)
        XCTAssertNil(registry.sessionRecord(sessionID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCorruptedRegistryFileIsSkippedGracefully() throws {
        let sessionID = UUID()
        let good = makeRegistry()
        good.upsertSession(sessionID)

        // Plant a garbage file next to the valid one.
        try Data("{not json".utf8).write(to: tempRoot.appendingPathComponent("broken.json"))

        let reloaded = makeRegistry()
        reloaded.load()
        XCTAssertNotNil(reloaded.sessionRecord(sessionID), "valid records must survive a corrupt neighbour")
        XCTAssertEqual(reloaded.allSessionRecords().count, 1)
    }

    func testDetachedMarkingCascadesToRunningTerminals() throws {
        let registry = makeRegistry()
        let sessionID = UUID()
        registry.upsertSession(sessionID)
        registry.recordTerminalOpened(makeTerminal(), sessionID: sessionID)

        registry.markSessionDetached(sessionID)
        let record = try XCTUnwrap(registry.sessionRecord(sessionID))
        XCTAssertEqual(record.state, .detached)
        XCTAssertEqual(record.terminals.first?.state, .detached)

        registry.markSessionAttached(sessionID)
        let attached = try XCTUnwrap(registry.sessionRecord(sessionID))
        XCTAssertEqual(attached.state, .running)
        XCTAssertEqual(attached.terminals.first?.state, .running)
    }
}
