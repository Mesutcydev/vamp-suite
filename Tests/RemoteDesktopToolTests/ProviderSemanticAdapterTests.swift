import XCTest
import SharedProtocol

final class ProviderSemanticAdapterTests: XCTestCase {
    private let sessionID = UUID()
    private let terminalID = UUID()

    func testGrokAdapterFramesSplitNDJSONAndEmitsText() {
        let adapter = GrokAdapter()
        XCTAssertTrue(adapter.consume(Data(#"{"type":"te"# .utf8), sessionID: sessionID, terminalID: terminalID).isEmpty)
        let events = adapter.consume(Data("xt\",\"data\":\"Hello\"}\n{\"type\":\"end\",\"sessionId\":\"grok-session\"}\n".utf8), sessionID: sessionID, terminalID: terminalID)
        XCTAssertTrue(events.contains(.messageDelta("Hello")))
        XCTAssertTrue(events.contains(.sessionIdentifier("grok-session")))
        XCTAssertTrue(events.contains(.completed))
    }

    func testOpenCodeAdapterEmitsMessageAndCompletion() {
        let adapter = OpenCodeAdapter()
        let data = Data((
            #"{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"Done"}}"# + "\n" +
            #"{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"stop"}}"# + "\n"
        ).utf8)
        let events = adapter.consume(data, sessionID: sessionID, terminalID: terminalID)
        XCTAssertTrue(events.contains(.messageDelta("Done")))
        XCTAssertTrue(events.contains(.sessionIdentifier("ses_1")))
        XCTAssertTrue(events.contains(.completed))
        XCTAssertEqual(events.filter {
            if case .sessionIdentifier = $0 { return true }
            return false
        }.count, 1)
    }

    func testOpenCodeDuplicateStopBoundaryCompletesOnlyOnce() {
        let adapter = OpenCodeAdapter()
        let sessionID = UUID()
        let terminalID = UUID()
        let line = "{\"type\":\"step_finish\",\"part\":{\"reason\":\"stop\"}}\n"
        let events = adapter.consume(Data((line + line).utf8), sessionID: sessionID, terminalID: terminalID)
        XCTAssertEqual(events.filter { $0 == .completed }.count, 1)
    }

    func testOpenCodeToolBoundaryDoesNotCompleteTheTurnAndParsesTodos() throws {
        let adapter = OpenCodeAdapter()
        let tool = Data((#"{"type":"tool_use","sessionID":"ses_1","part":{"type":"tool","tool":"todowrite","state":{"status":"completed","input":{"todos":[{"content":"Audit","status":"completed"},{"content":"Test","status":"in_progress"}]}}}}"# + "\n").utf8)
        let boundary = Data((#"{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"tool-calls"}}"# + "\n").utf8)

        guard case .taskPlan(.planCreated(let plan)) = try XCTUnwrap(
            adapter.consume(tool, sessionID: sessionID, terminalID: terminalID).first
        ) else { return XCTFail("Expected OpenCode todo plan") }
        let events = adapter.consume(boundary, sessionID: sessionID, terminalID: terminalID)

        XCTAssertEqual(plan.tasks.map(\.status), [.completed, .running])
        XCTAssertFalse(events.contains(.completed))
    }

    func testClaudeAdapterConsumesStreamJSONDelta() {
        let adapter = ClaudeAdapter()
        let data = Data((
            #"{"type":"stream_event","session_id":"claude-1","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Fixed"}}}"# + "\n" +
            #"{"type":"result","session_id":"claude-1","is_error":false,"result":"Fixed"}"# + "\n"
        ).utf8)
        let events = adapter.consume(data, sessionID: sessionID, terminalID: terminalID)
        XCTAssertTrue(events.contains(.messageDelta("Fixed")))
        XCTAssertTrue(events.contains(.sessionIdentifier("claude-1")))
        XCTAssertTrue(events.contains(.completed))
        XCTAssertEqual(events.filter {
            if case .sessionIdentifier = $0 { return true }
            return false
        }.count, 1)
    }

    func testClaudeResultProvidesFallbackWhenNoTextDelta() {
        let adapter = ClaudeAdapter()
        let sessionID = UUID()
        let terminalID = UUID()
        let line = #"{"type":"result","is_error":false,"result":"VAMP_OK"}"# + "\n"

        let events = adapter.consume(Data(line.utf8), sessionID: sessionID, terminalID: terminalID)

        XCTAssertEqual(events, [.messageDelta("VAMP_OK"), .completed])
    }

    func testClaudeResultDoesNotDuplicateStreamedText() {
        let adapter = ClaudeAdapter()
        let sessionID = UUID()
        let terminalID = UUID()
        let delta = #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"VAMP_OK"}}}"# + "\n"
        let result = #"{"type":"result","is_error":false,"result":"VAMP_OK"}"# + "\n"

        _ = adapter.consume(Data(delta.utf8), sessionID: sessionID, terminalID: terminalID)
        let events = adapter.consume(Data(result.utf8), sessionID: sessionID, terminalID: terminalID)

        XCTAssertEqual(events, [.completed])
    }

    func testKimiAdapterConsumesAssistantMessagesAndCompletion() {
        let adapter = KimiAdapter()
        let data = Data((
            #"{"session_id":"kimi-1","role":"assistant","content":"Hello"}"# + "\n" +
            #"{"type":"end"}"# + "\n"
        ).utf8)
        let events = adapter.consume(data, sessionID: sessionID, terminalID: terminalID)
        XCTAssertTrue(events.contains(.sessionIdentifier("kimi-1")))
        XCTAssertTrue(events.contains(.messageDelta("Hello")))
        XCTAssertTrue(events.contains(.completed))
    }

    func testQwenAdapterConsumesPartialEventsAndResult() {
        let adapter = QwenAdapter()
        let data = Data((
            #"{"type":"stream_event","session_id":"qwen-1","event":{"delta":{"type":"text_delta","text":"Hi"}}}"# + "\n" +
            #"{"type":"result","is_error":false}"# + "\n"
        ).utf8)
        let events = adapter.consume(data, sessionID: sessionID, terminalID: terminalID)
        XCTAssertTrue(events.contains(.sessionIdentifier("qwen-1")))
        XCTAssertTrue(events.contains(.messageDelta("Hi")))
        XCTAssertTrue(events.contains(.completed))
    }

    func testAiderAdapterFramesPlainText() {
        let adapter = AiderAdapter()
        XCTAssertEqual(
            adapter.consume(Data("Aider answer\n".utf8), sessionID: sessionID, terminalID: terminalID),
            [.messageDelta("Aider answer\n")]
        )
        XCTAssertEqual(
            adapter.finish(sessionID: sessionID, terminalID: terminalID),
            []
        )
    }

    func testGeminiAdapterConsumesMessagesAndResult() {
        let adapter = GeminiAdapter()
        let lines = [
            #"{"type":"init","session_id":"gemini-1"}"#,
            #"{"type":"message","role":"assistant","content":"Ready"}"#,
            #"{"type":"result"}"#,
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let events = adapter.consume(data, sessionID: sessionID, terminalID: terminalID)
        XCTAssertTrue(events.contains(.sessionIdentifier("gemini-1")))
        XCTAssertTrue(events.contains(.messageDelta("Ready")))
        XCTAssertTrue(events.contains(.completed))
    }

    func testClaudeCurrentTaskResultSchemaKeepsStableTasks() throws {
        let adapter = ClaudeAdapter()
        let createAudit = Data((#"{"type":"user","tool_use_result":{"task":{"id":"1","subject":"Audit"}}}"# + "\n").utf8)
        let createTest = Data((#"{"type":"user","tool_use_result":{"task":{"id":"2","subject":"Test"}}}"# + "\n").utf8)
        let completeAudit = Data((#"{"type":"user","tool_use_result":{"success":true,"taskId":"1","statusChange":{"from":"pending","to":"completed"}}}"# + "\n").utf8)
        let startTest = Data((#"{"type":"user","tool_use_result":{"success":true,"taskId":"2","statusChange":{"from":"pending","to":"in_progress"}}}"# + "\n").utf8)

        _ = adapter.consume(createAudit, sessionID: sessionID, terminalID: terminalID)
        _ = adapter.consume(createTest, sessionID: sessionID, terminalID: terminalID)
        _ = adapter.consume(completeAudit, sessionID: sessionID, terminalID: terminalID)
        guard case .taskPlan(.planUpdated(let plan)) = try XCTUnwrap(
            adapter.consume(startTest, sessionID: sessionID, terminalID: terminalID).first
        ) else { return XCTFail("Expected Claude task update") }

        XCTAssertEqual(plan.tasks.map(\.title), ["Audit", "Test"])
        XCTAssertEqual(plan.tasks.map(\.status), [.completed, .running])
        XCTAssertEqual(Set(plan.tasks.map(\.id)).count, 2)
    }

    func testCodexAdapterConsumesJSONLEvents() {
        let adapter = CodexAdapter()
        let lines = [
            #"{"type":"thread.started","thread_id":"thread-1"}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"Ready"}}"#,
            #"{"type":"turn.completed"}"#,
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let events = adapter.consume(data, sessionID: sessionID, terminalID: terminalID)
        XCTAssertTrue(events.contains(.sessionIdentifier("thread-1")))
        XCTAssertTrue(events.contains(.messageDelta("Ready")))
        XCTAssertTrue(events.contains(.completed))
    }

    func testCodexCurrentTodoListSchemaStreamsPlanUpdates() throws {
        let adapter = CodexAdapter()
        let first = Data((#"{"type":"item.started","item":{"id":"item_0","type":"todo_list","items":[{"text":"Audit","completed":false},{"text":"Test","completed":false}]}}"# + "\n").utf8)
        let second = Data((#"{"type":"item.updated","item":{"id":"item_0","type":"todo_list","items":[{"text":"Audit","completed":true},{"text":"Test","completed":false}]}}"# + "\n").utf8)

        guard case .taskPlan(.planCreated(let initial)) = try XCTUnwrap(
            adapter.consume(first, sessionID: sessionID, terminalID: terminalID).first
        ) else { return XCTFail("Expected Codex todo plan") }
        guard case .taskPlan(.planUpdated(let updated)) = try XCTUnwrap(
            adapter.consume(second, sessionID: sessionID, terminalID: terminalID).first
        ) else { return XCTFail("Expected Codex todo update") }

        XCTAssertEqual(initial.tasks.map(\.status), [.pending, .pending])
        XCTAssertEqual(updated.tasks.map(\.status), [.completed, .pending])
        XCTAssertEqual(initial.tasks.map(\.id), updated.tasks.map(\.id))
    }

    func testProviderTodoEventsCreateStableAdapterPlan() throws {
        let adapter = GrokAdapter()
        let first = Data((#"{"type":"tool_call","name":"todo_write","arguments":{"todos":[{"id":"a","content":"Audit","status":"in_progress"},{"id":"b","content":"Test","status":"pending"}]}}"# + "\n").utf8)
        let second = Data((#"{"type":"tool_call","name":"todo_write","arguments":{"todos":[{"id":"a","content":"Audit","status":"completed"},{"id":"b","content":"Test","status":"in_progress"}]}}"# + "\n").utf8)
        let firstEvents = adapter.consume(first, sessionID: sessionID, terminalID: terminalID)
        let secondEvents = adapter.consume(second, sessionID: sessionID, terminalID: terminalID)

        guard case .taskPlan(.planCreated(let initial)) = try XCTUnwrap(firstEvents.first) else {
            return XCTFail("Expected provider-created plan")
        }
        guard case .taskPlan(.planUpdated(let updated)) = try XCTUnwrap(secondEvents.first) else {
            return XCTFail("Expected provider plan update")
        }
        XCTAssertEqual(initial.source, .adapter)
        XCTAssertEqual(initial.id, updated.id)
        XCTAssertEqual(initial.tasks.map(\.id), updated.tasks.map(\.id))
        XCTAssertEqual(updated.tasks.map(\.status), [.completed, .running])
    }

    func testGrokCurrentToolAndPlanSchemasProduceTaskCards() throws {
        let adapter = GrokAdapter()
        let toolCall = Data((#"{"type":"tool_call","toolName":"todo_write","rawInput":{"todos":[{"id":"audit","content":"Audit","status":"completed"},{"id":"test","content":"Test","status":"in_progress"}]}}"# + "\n").utf8)
        let livePlan = Data((#"{"type":"plan","entries":[{"content":"Audit","priority":"medium","status":"completed"},{"content":"Test","priority":"medium","status":"completed"}]}"# + "\n").utf8)

        guard case .taskPlan(.planCreated(let initial)) = try XCTUnwrap(
            adapter.consume(toolCall, sessionID: sessionID, terminalID: terminalID).first
        ) else { return XCTFail("Expected Grok tool-call plan") }
        guard case .taskPlan(.planUpdated(let updated)) = try XCTUnwrap(
            adapter.consume(livePlan, sessionID: sessionID, terminalID: terminalID).first
        ) else { return XCTFail("Expected Grok top-level plan update") }

        XCTAssertEqual(initial.tasks.map(\.title), ["Audit", "Test"])
        XCTAssertEqual(initial.tasks.map(\.status), [.completed, .running])
        XCTAssertEqual(updated.tasks.map(\.status), [.completed, .completed])
        XCTAssertEqual(initial.tasks.map(\.id), updated.tasks.map(\.id))
        XCTAssertEqual(updated.state, .completed)
    }

    func testGrokToolResultWithoutIDsKeepsTaskIdentityAndSuppressesDuplicateSnapshot() throws {
        let adapter = GrokAdapter()
        let toolCall = Data((#"{"type":"tool_call","toolName":"todo_write","rawInput":{"todos":[{"id":"audit","content":"Audit","status":"completed"},{"id":"verify","content":"Verify","status":"in_progress"}]}}"# + "\n").utf8)
        let toolResult = Data((#"{"type":"tool_call_update","toolName":"todo_write","rawOutput":{"TodosUpdated":{"todos":[{"content":"Audit","status":"completed"},{"content":"Verify","status":"in_progress"}]}}}"# + "\n").utf8)
        let planSnapshot = Data((#"{"type":"plan","entries":[{"content":"Audit","status":"completed"},{"content":"Verify","status":"in_progress"}]}"# + "\n").utf8)

        guard case .taskPlan(.planCreated(let initial)) = try XCTUnwrap(
            adapter.consume(toolCall, sessionID: sessionID, terminalID: terminalID).first
        ) else { return XCTFail("Expected initial Grok plan") }
        let duplicateResult = adapter.consume(toolResult, sessionID: sessionID, terminalID: terminalID)
        let duplicateSnapshot = adapter.consume(planSnapshot, sessionID: sessionID, terminalID: terminalID)

        XCTAssertEqual(initial.tasks.map(\.title), ["Audit", "Verify"])
        XCTAssertTrue(duplicateResult.isEmpty)
        XCTAssertTrue(duplicateSnapshot.isEmpty)
    }

    func testOnlyCompletionAndFailureEndAProviderTurn() {
        XCTAssertFalse(ProviderSemanticEvent.messageDelta("Done").isTerminalProviderEvent)
        XCTAssertFalse(ProviderSemanticEvent.thinkingDelta("Checking").isTerminalProviderEvent)
        XCTAssertFalse(ProviderSemanticEvent.sessionIdentifier("session").isTerminalProviderEvent)
        XCTAssertTrue(ProviderSemanticEvent.completed.isTerminalProviderEvent)
        XCTAssertTrue(ProviderSemanticEvent.failed("No access").isTerminalProviderEvent)
    }

    func testPiAdapterConsumesJSONEventStream() {
        let adapter = PiAdapter()
        let lines = [
            #"{"type":"session","version":3,"id":"pi-1","cwd":"/tmp"}"#,
            #"{"type":"agent_start"}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hello"}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"Reasoning"}}"#,
            #"{"type":"agent_end","messages":[]}"#,
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let events = adapter.consume(data, sessionID: sessionID, terminalID: terminalID)
        XCTAssertTrue(events.contains(.sessionIdentifier("pi-1")))
        XCTAssertTrue(events.contains(.messageDelta("Hello")))
        XCTAssertTrue(events.contains(.thinkingDelta("Reasoning")))
        XCTAssertTrue(events.contains(.completed))
    }

    func testPiAdapterParsesSplitLinesAndErrors() {
        let adapter = PiAdapter()
        XCTAssertTrue(adapter.consume(Data(#"{"type":"sessio"# .utf8), sessionID: sessionID, terminalID: terminalID).isEmpty)
        let events = adapter.consume(
            Data(("n\"}\n" + #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"ok"}}"# + "\n").utf8),
            sessionID: sessionID,
            terminalID: terminalID
        )
        XCTAssertTrue(events.contains(.messageDelta("ok")))
        let failed = adapter.consume(
            Data((#"{"type":"error","message":"boom"}"# + "\n").utf8),
            sessionID: sessionID,
            terminalID: terminalID
        )
        XCTAssertTrue(failed.contains(.failed("boom")))
    }

    func testCommandCodeAdapterStreamsPlainTextLines() {
        let adapter = CommandCodeAdapter()
        let first = adapter.consume(Data("Here is the answer:\n".utf8), sessionID: sessionID, terminalID: terminalID)
        XCTAssertTrue(first.contains(.messageDelta("Here is the answer:\n")))
        let partial = adapter.consume(Data("still typing".utf8), sessionID: sessionID, terminalID: terminalID)
        XCTAssertTrue(partial.isEmpty)
        let finished = adapter.finish(sessionID: sessionID, terminalID: terminalID)
        XCTAssertTrue(finished.contains(.messageDelta("still typing")))
    }

    func testCommandCodeAdapterStripsCarriageReturns() {
        let adapter = CommandCodeAdapter()
        let events = adapter.consume(Data("Line one\r\nLine two\r\n".utf8), sessionID: sessionID, terminalID: terminalID)
        XCTAssertTrue(events.contains(.messageDelta("Line one\nLine two\n")))
    }
}
