#if os(macOS)
import XCTest
import Darwin
import SharedProtocol
import TransportWebRTC
@testable import HostApp
@testable import ClientiOS

// MARK: - Persistent terminal reattach (Step A)

/// Regression tests for decoupling PTY/session ownership from the transport:
/// a transport loss must never kill remote shells, and a reconnect presenting
/// the same session/terminal IDs must reattach to the same PTY with its
/// bounded output tail replayed (sequence-deduped).
final class PersistentTerminalReattachTests: XCTestCase {

    // MARK: Helpers

    private final class EnvelopeSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _envelopes: [DataChannelEnvelope] = []

        func append(_ envelope: DataChannelEnvelope) {
            lock.lock()
            _envelopes.append(envelope)
            lock.unlock()
        }

        func drain() -> [DataChannelEnvelope] {
            lock.lock()
            defer { lock.unlock() }
            let all = _envelopes
            _envelopes.removeAll(keepingCapacity: true)
            return all
        }

        func all(where kind: DataChannelMessageKind) -> [DataChannelEnvelope] {
            lock.lock()
            defer { lock.unlock() }
            return _envelopes.filter { $0.kind == kind }
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return _envelopes.count
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 8,
        message: String = "condition not met in time",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            usleep(20_000)
        }
        XCTFail(message, file: file, line: line)
    }

    private func makeService(retention: Double = 6 * 60 * 60) -> (HostTerminalService, EnvelopeSink) {
        let service = HostTerminalService(workspaceService: nil, detachedRetentionSeconds: retention)
        let sink = EnvelopeSink()
        service.sendEnvelope = { sink.append($0) }
        return (service, sink)
    }

    /// Opens a `cat`-backed PTY (never exits on its own) and waits for ready.
    private func openCatTerminal(
        _ service: HostTerminalService,
        sink: EnvelopeSink,
        sessionID: UUID,
        terminalID: UUID
    ) {
        service.handleOpen(TerminalOpenMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            cols: 80,
            rows: 24,
            term: nil,
            startupCommand: nil,
            workspaceID: nil,
            workingDirectory: nil,
            launchExecutable: "cat",
            launchArguments: []
        ))
        waitUntil(timeout: 8, message: "terminal \(terminalID.uuidString) did not become ready") {
            sink.all(where: .terminalReady).contains { envelope in
                (try? envelope.decodeTerminalReady())?.terminalID == terminalID
            }
        }
    }

    /// Sends raw input into a terminal and waits until an output chunk
    /// containing `needle` (as text) is emitted.
    private func feedAndExpectOutput(
        _ service: HostTerminalService,
        sink: EnvelopeSink,
        sessionID: UUID,
        terminalID: UUID,
        input: String,
        needle: String
    ) {
        service.handleInput(TerminalInputMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            data: Data((input + "\r").utf8)
        ))
        waitUntil(timeout: 8, message: "expected output containing \(needle)") {
            sink.all(where: .terminalOutput).contains { envelope in
                guard let message = try? envelope.decodeTerminalOutput(),
                      message.terminalID == terminalID else { return false }
                return String(data: message.data, encoding: .utf8)?.contains(needle) == true
            }
        }
    }

    // MARK: Host: detach keeps the PTY alive

    func testTransportDetachKeepsPTYAliveAndReattachReusesIt() throws {
        let (service, sink) = makeService()
        let sessionID = UUID()
        let terminalID = UUID()

        openCatTerminal(service, sink: sink, sessionID: sessionID, terminalID: terminalID)
        feedAndExpectOutput(service, sink: sink, sessionID: sessionID, terminalID: terminalID,
                            input: "hello", needle: "hello")

        // Transport drops. No close may be emitted and the PTY must keep
        // answering input.
        service.transportDetached(sessionID: sessionID)
        XCTAssertEqual(sink.all(where: .terminalClose).count, 0,
                       "transport detach must not send terminal close notices")
        feedAndExpectOutput(service, sink: sink, sessionID: sessionID, terminalID: terminalID,
                            input: "still-alive", needle: "still-alive")
        XCTAssertEqual(service.activeTerminalCount, 1)

        // Capture every sequence the host assigned while we were away.
        let originalSequences = sink.all(where: .terminalOutput).compactMap {
            try? $0.decodeTerminalOutput()
        }.filter { $0.terminalID == terminalID }.map(\.sequence)
        XCTAssertFalse(originalSequences.isEmpty)

        // Reattach with the same IDs: ready must be a reopen, no second PTY
        // may be spawned, and the bounded output tail must replay with the
        // ORIGINAL sequence numbers so the client can dedupe. Poll
        // non-destructively: the replay chunks arrive right after the ready
        // envelope and must not be thrown away.
        let outputCountBefore = sink.all(where: .terminalOutput).count
        service.transportAttached(sessionID: sessionID)
        service.handleOpen(TerminalOpenMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            cols: 80,
            rows: 24,
            term: nil,
            startupCommand: nil,
            workspaceID: nil,
            workingDirectory: nil,
            launchExecutable: nil,
            launchArguments: []
        ))

        waitUntil(timeout: 8, message: "reattach ready must be marked isReopen") {
            sink.all(where: .terminalReady).contains {
                (try? $0.decodeTerminalReady())?.isReopen == true
            }
        }
        let reattachReady = try XCTUnwrap(sink.all(where: .terminalReady).last).decodeTerminalReady()
        XCTAssertEqual(reattachReady.terminalID, terminalID)
        XCTAssertEqual(service.activeTerminalCount, 1, "reattach must not spawn a second PTY")

        waitUntil(timeout: 8, message: "reattach should replay the buffered output tail") {
            sink.all(where: .terminalOutput).count > outputCountBefore
        }
        let replayedSequences = sink.all(where: .terminalOutput)
            .dropFirst(outputCountBefore)
            .compactMap { try? $0.decodeTerminalOutput() }
            .filter { $0.terminalID == terminalID }
            .map(\.sequence)
        XCTAssertFalse(replayedSequences.isEmpty, "reattach should replay the buffered output tail")
        let originalSet = Set(originalSequences)
        XCTAssertTrue(replayedSequences.allSatisfy { originalSet.contains($0) },
                      "replayed chunks must reuse original sequences; replay=\(replayedSequences) original=\(originalSequences)")
    }

    func testRetentionExpiryTearsDownOnlyTheDetachedSession() {
        let (service, sink) = makeService(retention: 0.3)
        let sessionA = UUID()
        let sessionB = UUID()
        openCatTerminal(service, sink: sink, sessionID: sessionA, terminalID: UUID())
        openCatTerminal(service, sink: sink, sessionID: sessionB, terminalID: UUID())
        XCTAssertEqual(service.activeTerminalCount, 2)

        service.transportDetached(sessionID: sessionA)
        waitUntil(timeout: 5, message: "detached session A should be reaped by retention") {
            service.activeTerminalCount == 1
        }
        // Session B survives untouched.
        XCTAssertEqual(service.activeTerminalCount, 1)
    }

    func testPerSessionTerminalCapacity() throws {
        let (service, sink) = makeService()
        let sessionA = UUID()
        let sessionB = UUID()

        for index in 0..<HostTerminalService.maxActiveTerminals {
            openCatTerminal(service, sink: sink, sessionID: sessionA, terminalID: UUID())
            waitUntil(timeout: 8, message: "terminal \(index) never opened") {
                sink.all(where: .terminalReady).count == index + 1
            }
        }

        // A different session is not blocked by session A's tabs.
        let terminalB = UUID()
        service.handleOpen(TerminalOpenMessage(
            sessionID: sessionB, terminalID: terminalB, cols: 80, rows: 24,
            term: nil, startupCommand: nil, workspaceID: nil, workingDirectory: nil,
            launchExecutable: "cat", launchArguments: []
        ))
        waitUntil(timeout: 8, message: "session B terminal should open") {
            sink.all(where: .terminalReady).contains {
                (try? $0.decodeTerminalReady())?.terminalID == terminalB
            }
        }

        // The ninth tab for session A must be rejected.
        sink.drain()
        service.handleOpen(TerminalOpenMessage(
            sessionID: sessionA, terminalID: UUID(), cols: 80, rows: 24,
            term: nil, startupCommand: nil, workspaceID: nil, workingDirectory: nil,
            launchExecutable: "cat", launchArguments: []
        ))
        waitUntil(timeout: 8, message: "ninth terminal for session A should be rejected") {
            sink.all(where: .terminalClose).contains {
                (try? $0.decodeTerminalClose())?.reason == "terminal-capacity"
            }
        }
    }

    // MARK: Client: suspend/reattach identity

    @MainActor
    func testSuspendKeepsTerminalIdentityAndReattachReusesIt() throws {
        final class SendLog: @unchecked Sendable {
            let lock = NSLock()
            var envelopes: [DataChannelEnvelope] = []
            func add(_ e: DataChannelEnvelope) { lock.lock(); envelopes.append(e); lock.unlock() }
            func all() -> [DataChannelEnvelope] { lock.lock(); defer { lock.unlock() }; return envelopes }
        }

        let manager = ClientTerminalSessionManager()
        let sessionID = UUID()
        let log = SendLog()
        manager.activate(sessionID: sessionID) { envelope in
            log.add(envelope)
        }

        XCTAssertTrue(manager.open(cols: 80, rows: 24, startupCommand: "tmux attach -t work"))
        let firstOpen = try XCTUnwrap(log.all().first(where: { $0.kind == .terminalOpen }))
        let firstTerminalID = try XCTUnwrap(try firstOpen.decodeTerminalOpen().terminalID)

        // Host acknowledges the fresh PTY.
        let ready = TerminalReadyMessage(sessionID: sessionID, terminalID: firstTerminalID, cols: 80, rows: 24, isReopen: false)
        XCTAssertTrue(manager.receiveReady(ready))

        // Transport loss: no polite close may be sent.
        let closesBefore = log.all().filter { $0.kind == .terminalClose }.count
        manager.suspendForReattach()
        XCTAssertEqual(log.all().filter { $0.kind == .terminalClose }.count, closesBefore,
                       "suspend must not send a terminal close")

        // Reattach reuses the SAME terminal ID.
        manager.reattach(sessionID: sessionID) { envelope in log.add(envelope) }
        let reattachOpens = log.all().filter { $0.kind == .terminalOpen }
        XCTAssertEqual(reattachOpens.count, 2)
        let secondTerminalID = try XCTUnwrap(try reattachOpens[1].decodeTerminalOpen().terminalID)
        XCTAssertEqual(firstTerminalID, secondTerminalID, "reattach must reuse the terminal ID")

        // The reopen acknowledgement keeps the sequence baseline.
        let reopenReady = TerminalReadyMessage(sessionID: sessionID, terminalID: firstTerminalID, cols: 80, rows: 24, isReopen: true)
        XCTAssertTrue(manager.receiveReady(reopenReady))

        // Explicit deactivate DOES send a polite close; suppressed variant does not.
        let beforeExplicit = log.all().filter { $0.kind == .terminalClose }.count
        manager.deactivate(notifyHost: true)
        XCTAssertEqual(log.all().filter { $0.kind == .terminalClose }.count, beforeExplicit + 1)

        manager.activate(sessionID: sessionID) { envelope in log.add(envelope) }
        XCTAssertTrue(manager.open(cols: 80, rows: 24))
        let beforeSuppressed = log.all().filter { $0.kind == .terminalClose }.count
        manager.deactivate(notifyHost: false)
        XCTAssertEqual(log.all().filter { $0.kind == .terminalClose }.count, beforeSuppressed,
                       "suppressed deactivate must not send a terminal close")
    }

    @MainActor
    func testSequenceBaselineSurvivesReopenAndResetsOnFreshPTY() {
        let manager = ClientTerminalSessionManager()
        let sessionID = UUID()
        manager.activate(sessionID: sessionID) { _ in }
        XCTAssertTrue(manager.open(cols: 80, rows: 24))
        let terminalID = manager.terminalID!

        XCTAssertTrue(manager.receiveReady(TerminalReadyMessage(
            sessionID: sessionID, terminalID: terminalID, cols: 80, rows: 24, isReopen: false
        )))
        XCTAssertTrue(manager.receiveOutput(TerminalOutputMessage(
            sessionID: sessionID, terminalID: terminalID, data: Data("abc".utf8), sequence: 7
        )))
        // Duplicate at or below the baseline is dropped.
        XCTAssertFalse(manager.receiveOutput(TerminalOutputMessage(
            sessionID: sessionID, terminalID: terminalID, data: Data("dup".utf8), sequence: 7
        )))
        XCTAssertTrue(manager.receiveOutput(TerminalOutputMessage(
            sessionID: sessionID, terminalID: terminalID, data: Data("next".utf8), sequence: 8
        )))

        // Reopen keeps the baseline: replayed sequence 8 is still dropped.
        _ = manager.reattach(sessionID: sessionID) { _ in }
        XCTAssertTrue(manager.receiveReady(TerminalReadyMessage(
            sessionID: sessionID, terminalID: terminalID, cols: 80, rows: 24, isReopen: true
        )))
        XCTAssertFalse(manager.receiveOutput(TerminalOutputMessage(
            sessionID: sessionID, terminalID: terminalID, data: Data("replay".utf8), sequence: 8
        )))

        // A FRESH PTY (isReopen false) resets the baseline so the new shell's
        // low sequence numbers are accepted again.
        _ = manager.reattach(sessionID: sessionID) { _ in }
        XCTAssertTrue(manager.receiveReady(TerminalReadyMessage(
            sessionID: sessionID, terminalID: terminalID, cols: 80, rows: 24, isReopen: false
        )))
        XCTAssertTrue(manager.receiveOutput(TerminalOutputMessage(
            sessionID: sessionID, terminalID: terminalID, data: Data("fresh".utf8), sequence: 2
        )))
    }

    // MARK: Waiters

    private func waitForEnvelope(
        _ kind: DataChannelMessageKind,
        sink: EnvelopeSink,
        timeout: TimeInterval = 8
    ) -> DataChannelEnvelope? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let envelope = sink.all(where: kind).last {
                return envelope
            }
            usleep(20_000)
        }
        return nil
    }
}
#endif
