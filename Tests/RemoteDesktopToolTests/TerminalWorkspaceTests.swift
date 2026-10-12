import XCTest
@testable import ClientiOS
import SharedProtocol

@MainActor
final class TerminalWorkspaceTests: XCTestCase {
    func testChatSubmissionIsCanonicalAndProcessOutputStreamsIntoAReadableCard() {
        let chat = TerminalChatStore(tabTitle: "Build")

        XCTAssertEqual(chat.blocks.first?.text, "Build is opening a shell…")
        chat.recordChatSubmission("echo café", provider: nil)
        chat.appendOutput(Data("running build…\n✓ clean\n".utf8))
        chat.appendOutput(Data("\u{1B}[32m✓ verified\u{1B}[0m\n192% ".utf8))

        XCTAssertTrue(chat.blocks.contains {
            $0.role == .command && $0.title == "You · Shell" && $0.text == "$ echo café"
        })
        XCTAssertTrue(chat.blocks.contains { $0.role == .output && $0.text.contains("running build") })
        XCTAssertFalse(chat.blocks.contains { $0.role == .output && $0.text.contains("192%") })
        XCTAssertFalse(chat.blocks.contains { $0.text.contains("38;5") || $0.text.contains("\u{1B}") })
    }

    func testChatSubmissionPreservesSubmittedWhitespaceAndAgentIdentity() {
        let chat = TerminalChatStore(tabTitle: "Grok")
        let submitted = "  keep this spacing  "

        chat.recordChatSubmission(submitted, provider: .grok)

        XCTAssertTrue(chat.blocks.contains {
            $0.role == .command && $0.title == "You · Grok" && $0.text == submitted
        })
    }

    func testChatReadyAndCloseCardsAreIdempotentAndRetryIsVisible() {
        let chat = TerminalChatStore(tabTitle: "Terminal 1")

        chat.markReady()
        chat.markReady()
        XCTAssertEqual(chat.blocks.filter { $0.text == "Terminal 1 is connected." }.count, 0)
        XCTAssertEqual(chat.activityEvents.filter { $0.text == "PTY ready" }.count, 1)

        chat.markClosed(reason: "terminal-start-timeout")
        chat.markClosed(reason: "terminal-start-timeout")
        XCTAssertEqual(chat.blocks.filter { $0.role == .error }.count, 1)

        chat.prepareForRetry()
        XCTAssertTrue(chat.blocks.contains { $0.text == "Terminal 1 is trying again…" && $0.isStreaming })
        chat.markReady()
        XCTAssertEqual(chat.activityEvents.filter { $0.text == "PTY ready" }.count, 2)
    }

    func testRawTerminalInputAndOutputStayOutOfSemanticChat() {
        let chat = TerminalChatStore(tabTitle: "Terminal 1")
        chat.markReady()
        chat.recordInput(Data("echo ready\n".utf8))
        chat.appendOutput(Data("%\n~❯\n❯ echo ready\nready\n%\n~❯ ".utf8))

        XCTAssertFalse(chat.blocks.contains { $0.role == .command })
        XCTAssertFalse(chat.blocks.contains { $0.role == .output })
        XCTAssertTrue(chat.activityEvents.contains { $0.text.contains("bytes") })
    }

    func testChatConsumesTUIControlsWithoutLeakingANSIAndBoundsTheCard() {
        let chat = TerminalChatStore(tabTitle: "OpenCode")
        chat.markReady()
        chat.recordInput(Data("opencode\n".utf8))
        chat.recordChatSubmission("inspect the project", provider: .openCode)

        let repaint = Array(repeating: "\u{1B}(B\u{1B}[2K\u{1B}(B" + String(repeating: " ", count: 180) + "OpenCode", count: 120)
            .joined(separator: "\n")
        chat.appendOutput(Data(repaint.utf8))

        XCTAssertTrue(chat.blocks.contains { $0.role == .output && $0.text.contains("OpenCode") })
        XCTAssertFalse(chat.blocks.contains { $0.text.contains("\u{1B}") || $0.text.contains("[2K") })
        XCTAssertLessThanOrEqual(chat.blocks.first(where: { $0.role == .output })?.text.count ?? .max, 16_000)
        XCTAssertTrue(chat.activityEvents.contains { $0.text.contains("bytes") })
    }

    func testSemanticChatPreservesPacketSplitCRLFAndRewritesStandaloneCarriageReturn() {
        let chat = TerminalChatStore(tabTitle: "Shell")
        chat.markReady()
        chat.recordChatSubmission("echo hello", provider: nil)

        chat.appendOutput(Data("prompt% echo hello\r".utf8))
        chat.appendOutput(Data("\nhello\r\n".utf8))
        XCTAssertTrue(chat.blocks.contains {
            $0.role == .output && $0.text == "hello"
        })

        chat.appendOutput(Data("Downloading 10%\rDownloading 50%".utf8))
        XCTAssertTrue(chat.blocks.contains {
            $0.role == .output && $0.text.hasSuffix("Downloading 50%")
        })
    }

    func testSupportedProviderChatIgnoresTUIRepaintsAndUsesSemanticEvents() {
        let chat = TerminalChatStore(tabTitle: "Grok")
        chat.markReady()
        chat.appendOutput(Data("startup banner\nold prompt".utf8), provider: .grok)
        chat.recordChatSubmission("build an animation", provider: .grok)

        // A full-screen TUI may clear/rewrite content that existed before the
        // command. The Chat response must still be derived from bytes received
        // after submission, not from a String index in the lifetime screen.
        chat.appendOutput(Data("\u{1B}[2J\u{1B}[HWorking on the animation…".utf8), provider: .grok)

        XCTAssertFalse(chat.blocks.contains {
            $0.role == .output && $0.text.contains("Working on the animation")
        })
        chat.applyProviderSemanticEvent(.messageDelta("Working on the animation…"), provider: .grok)
        XCTAssertTrue(chat.blocks.contains {
            $0.role == .output && $0.text.contains("Working on the animation")
        })
        XCTAssertFalse(chat.blocks.contains {
            $0.role == .output && $0.text.contains("startup banner")
        })
    }

    func testTaskPlanTransitionsStaySemanticAndKeepProgressOrdinal() {
        let sessionID = UUID()
        let terminalID = UUID()
        let first = SessionTask(order: 1, title: "Audit")
        let second = SessionTask(order: 2, title: "Implement")
        let third = SessionTask(order: 3, title: "Test")
        let plan = SessionTaskPlan(
            sessionID: sessionID,
            terminalID: terminalID,
            title: "Work plan",
            tasks: [first, second, third],
            source: .native
        )
        let chat = TerminalChatStore(tabTitle: "Claude", sessionID: UUID())

        chat.applyTaskPlanEvent(.planCreated(plan))
        XCTAssertEqual(chat.taskPlan?.progressLabel, "1 of 3")
        chat.applyTaskPlanEvent(.taskStarted(first.id))
        XCTAssertEqual(chat.taskPlan?.tasks.first?.status, .running)
        chat.applyTaskPlanEvent(.taskCompleted(first.id))
        chat.applyTaskPlanEvent(.taskStarted(second.id))
        XCTAssertEqual(chat.taskPlan?.progressLabel, "2 of 3")
        XCTAssertEqual(chat.taskPlan?.completedCount, 1)
        XCTAssertEqual(chat.taskPlan?.tasks.map(\.id), [first.id, second.id, third.id])

        chat.applyTaskPlanEvent(.taskFailed(id: second.id, reason: "provider stopped"))
        XCTAssertEqual(chat.taskPlan?.tasks[1].failureReason, "provider stopped")
        XCTAssertEqual(chat.taskPlan?.state, .failed)
        chat.applyTaskPlanEvent(.taskStarted(second.id))
        XCTAssertNil(chat.taskPlan?.tasks[1].failureReason)
        chat.applyTaskPlanEvent(.planPaused)
        XCTAssertEqual(chat.taskPlan?.state, .paused)
        chat.applyTaskPlanEvent(.planResumed)
        XCTAssertEqual(chat.taskPlan?.state, .running)
    }

    func testTaskPlanFullEventsRejectEmbeddedIdentityMismatch() {
        let sessionID = UUID()
        let terminalID = UUID()
        let plan = SessionTaskPlan(
            sessionID: UUID(),
            terminalID: terminalID,
            tasks: [SessionTask(order: 1, title: "Wrong session")],
            source: .native
        )

        XCTAssertFalse(SessionTaskEvent.planCreated(plan).isBound(toSessionID: sessionID, terminalID: terminalID))
        XCTAssertTrue(SessionTaskEvent.planPaused.isBound(toSessionID: sessionID, terminalID: terminalID))
    }

    func testTaskPlanInferenceRequiresAStableChecklistAndNeverAcceptsVTBytes() {
        let sessionID = UUID()
        let terminalID = UUID()
        let inferred = SessionTaskPlanDetector.infer(
            from: "Implementation plan:\n1. Audit terminal\n2. Implement reducer\n3. Run tests",
            sessionID: sessionID,
            terminalID: terminalID
        )
        XCTAssertEqual(inferred?.source, .inferred)
        XCTAssertEqual(inferred?.tasks.count, 3)
        XCTAssertNil(SessionTaskPlanDetector.infer(
            from: "\u{1B}[38;5;255m1. Audit\u{1B}[0m\n2. Test",
            sessionID: sessionID,
            terminalID: terminalID
        ))
        XCTAssertNil(SessionTaskPlanDetector.infer(
            from: "I have 1. thing and 2. another thing.",
            sessionID: sessionID,
            terminalID: terminalID
        ))
    }

    func testTabsKeepStableIdentityAndRenameCloseImmediately() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "Workspace Test")
        let workspace = TerminalWorkspaceViewModel(coordinator: environment.sessionCoordinator)
        workspace.activate(sessionID: UUID())
        XCTAssertTrue(workspace.createTab())

        XCTAssertEqual(workspace.tabs.count, 1)
        let firstID = workspace.tabs[0].id
        XCTAssertTrue(workspace.createTab())
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.tabs[0].id, firstID)
        XCTAssertEqual(workspace.selectedTabID, workspace.tabs[1].id)

        workspace.rename(tabID: firstID, title: "Build")
        XCTAssertEqual(workspace.tabs.first?.title, "Build")

        workspace.close(tabID: firstID)
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNotEqual(workspace.tabs.first?.id, firstID)
    }

    func testBackgroundOutputMarksOnlyTheInactiveTabUnread() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "Unread Test")
        let workspace = TerminalWorkspaceViewModel(coordinator: environment.sessionCoordinator)
        workspace.activate(sessionID: UUID())
        XCTAssertTrue(workspace.createTab())
        XCTAssertTrue(workspace.createTab())

        let first = workspace.tabs[0]
        let second = workspace.tabs[1]
        workspace.select(tabID: second.id)
        XCTAssertEqual(workspace.selectedTabID, second.id)

        guard let terminalID = first.session.terminalID,
              let sessionID = workspace.activeSessionID else {
            return XCTFail("Test tabs should have active terminal IDs")
        }
        environment.sessionCoordinator.onTerminalOutput?(TerminalOutputMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            data: Data("while away".utf8),
            sequence: 1
        ))

        XCTAssertTrue(workspace.tabs[0].hasUnreadOutput)
        XCTAssertFalse(workspace.tabs[1].hasUnreadOutput)
        workspace.select(tabID: first.id)
        XCTAssertFalse(workspace.tabs[0].hasUnreadOutput)
    }

    func testWorkspaceStopsAtEightStableTabs() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "Capacity Test")
        let workspace = TerminalWorkspaceViewModel(coordinator: environment.sessionCoordinator)
        workspace.activate(sessionID: UUID())
        XCTAssertTrue(workspace.createTab())

        for _ in 1..<TerminalWorkspaceViewModel.maxTabs {
            XCTAssertTrue(workspace.createTab())
        }

        XCTAssertEqual(workspace.tabs.count, TerminalWorkspaceViewModel.maxTabs)
        XCTAssertEqual(workspace.tabCountLabel, "8/8")
        XCTAssertFalse(workspace.createTab())
    }

    func testDefaultTabNamesStayUniqueAfterClosingAndCreatingTabs() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "Tab Naming Test")
        let workspace = TerminalWorkspaceViewModel(coordinator: environment.sessionCoordinator)
        workspace.activate(sessionID: UUID())
        XCTAssertTrue(workspace.createTab())
        XCTAssertTrue(workspace.createTab())

        let firstID = workspace.tabs[0].id
        let originalNames = Set(workspace.tabs.map(\.title))
        XCTAssertEqual(originalNames, ["Terminal 1", "Terminal 2"])

        workspace.close(tabID: firstID)
        XCTAssertTrue(workspace.createTab())

        let names = workspace.tabs.map(\.title)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(Set(names), ["Terminal 1", "Terminal 2"])
    }

    func testChatComposerUsesPTYCarriageReturnForEnter() throws {
        let source = try String(contentsOfFile: "Sources/ClientiOS/TerminalWorkspaceViewModel.swift")
        XCTAssertTrue(source.contains(#"Data((command + "\r").utf8)"#))
        XCTAssertFalse(source.contains(#"Data((command + "\n").utf8)"#))
    }

    func testFreshConnectionWaitsForWorkspaceSelection() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "Launch Flow Test")
        let workspace = TerminalWorkspaceViewModel(coordinator: environment.sessionCoordinator)
        workspace.activate(sessionID: UUID())
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertNil(workspace.selectedTabID)
    }
}
