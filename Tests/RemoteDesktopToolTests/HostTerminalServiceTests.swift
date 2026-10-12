#if os(macOS)
import XCTest
import Network
@testable import HostApp
import SharedProtocol
import TransportWebRTC

final class HostTerminalServiceTests: XCTestCase {
    func testBrowserWebSocketOriginMustMatchHost() {
        XCTAssertTrue(HostBrowserControlService.isAllowedBrowserOrigin(nil, hostHeader: "127.0.0.1:9475"))
        XCTAssertTrue(HostBrowserControlService.isAllowedBrowserOrigin("http://127.0.0.1:9475", hostHeader: "127.0.0.1:9475"))
        XCTAssertTrue(HostBrowserControlService.isAllowedBrowserOrigin("https://mac.example.test", hostHeader: "mac.example.test"))
        XCTAssertFalse(HostBrowserControlService.isAllowedBrowserOrigin("null", hostHeader: "127.0.0.1:9475"))
        XCTAssertFalse(HostBrowserControlService.isAllowedBrowserOrigin("https://evil.example", hostHeader: "127.0.0.1:9475"))
    }

    func testBrowserRemoteAddressMustBeInsideTailscaleRanges() {
        XCTAssertTrue(HostBrowserControlService.isTailscaleAddress(.ipv4(IPv4Address("100.64.0.1")!)))
        XCTAssertTrue(HostBrowserControlService.isTailscaleAddress(.ipv4(IPv4Address("100.127.255.254")!)))
        XCTAssertFalse(HostBrowserControlService.isTailscaleAddress(.ipv4(IPv4Address("100.128.0.1")!)))
        XCTAssertFalse(HostBrowserControlService.isTailscaleAddress(.ipv4(IPv4Address("192.168.1.11")!)))
        XCTAssertTrue(HostBrowserControlService.isTailscaleAddress(.ipv6(IPv6Address("fd7a:115c:a1e0::1")!)))
        XCTAssertFalse(HostBrowserControlService.isTailscaleAddress(.ipv6(IPv6Address("fd00::1")!)))
    }

    func testBrowserPairingCodeAcceptsFormattedAndLocalizedDigits() {
        XCTAssertEqual(HostBrowserPairingCode.normalize(" 12-34·56-78-90-12 "), "123456789012")
        XCTAssertEqual(HostBrowserPairingCode.normalize("١٢٣٤٥٦٧٨٩٠١٢"), "123456789012")
        XCTAssertEqual(HostBrowserPairingCode.normalize("\u{200E}123456789012\u{2069}"), "123456789012")
        XCTAssertNil(HostBrowserPairingCode.normalize("123456"))
        XCTAssertNil(HostBrowserPairingCode.normalize("12a456789012"))
    }

    func testBrowserPairingCodeGenerateIsTwelveDigitsAndNormalizable() {
        for _ in 0..<64 {
            let code = HostBrowserPairingCode.generate()
            XCTAssertEqual(code.count, HostBrowserPairingCode.length)
            XCTAssertTrue(code.allSatisfy { $0.isNumber && $0.isASCII }, "code was \(code)")
            XCTAssertEqual(HostBrowserPairingCode.normalize(code), code)
        }
    }

    func testBrowserAssetKeepsPairingSurfaceStableAndViewportWorkCoalesced() {
        let source = BrowserControlWebAssets.indexHTML
        XCTAssertTrue(source.contains("<body class=\"pairing\">") )
        XCTAssertTrue(source.contains("class=\"field-label\" for=\"code\""))
        XCTAssertTrue(source.contains("maxlength=\"12\""))
        XCTAssertTrue(source.contains("body.pairing .modal#pair"))
        XCTAssertTrue(source.contains("backdrop-filter: none !important"))
        XCTAssertTrue(source.contains("const vampScheduleViewportUpdate"))
        XCTAssertFalse(source.contains("vampContentResizeObserver = new ResizeObserver(() =>"))
        XCTAssertTrue(source.contains("const existing = new Map([...navigation.querySelectorAll('.tab')"))
    }

    func testBrowserPairingCodeExpiryUsesTheExactLifetimeBoundary() {
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(HostBrowserPairingCode.isExpired(
            issuedAt: issuedAt,
            at: Date(timeIntervalSince1970: 1_599),
            lifetime: 600
        ))
        XCTAssertTrue(HostBrowserPairingCode.isExpired(
            issuedAt: issuedAt,
            at: Date(timeIntervalSince1970: 1_600),
            lifetime: 600
        ))
    }

    func testBrowserPairingLinkStripsPairCodeWithoutDroppingOtherQueryItems() {
        let link = HostBrowserPairingLink.make(
            baseURL: "https://mac.example.test/workspace?source=qr&pair=000000000000"
        )

        XCTAssertEqual(link, "https://mac.example.test/workspace?source=qr")
    }

    func testBrowserPairingLinkRejectsHostURLWithoutScheme() {
        XCTAssertNil(HostBrowserPairingLink.make(baseURL: "127.0.0.1:9475"))
        XCTAssertEqual(HostBrowserPairingLink.make(baseURL: "http://127.0.0.1:9475"), "http://127.0.0.1:9475")
    }

    func testBrowserControlBindErrorNamesOccupantAndSkipsSelf() {
        let inUse = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EADDRINUSE),
            userInfo: [NSLocalizedDescriptionKey: "Address already in use"]
        )
        XCTAssertTrue(HostBrowserControlBindError.isAddressInUse(inUse))
        XCTAssertEqual(
            HostBrowserControlBindError.message(port: 9475, error: inUse, occupantName: "BeetCode"),
            "Port 9475 is already in use by BeetCode. Quit that app, then tap Retry so Safari control can start."
        )
        XCTAssertTrue(
            HostBrowserControlBindError.message(port: 9475, error: inUse, occupantName: "Vamp Terminal Host")
                .contains("Only one Mac host")
        )
        XCTAssertFalse(HostBrowserControlBindError.isAddressInUse(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))))
        XCTAssertEqual(
            HostBrowserControlBindError.parseLsofFieldOutput("p12\ncVamp Host\np57953\ncBeetCode\n", excludingPID: 12),
            "BeetCode"
        )
    }

    func testBrowserPairingCompletesHTTPTokenExchangeAndWebSocketHandshake() async throws {
        let service = HostBrowserControlService()
        service.terminalModeProvider = { true }
        let port: UInt16 = 19075
        service.start(port: port)
        defer { service.stop() }

        let deadline = Date().addingTimeInterval(3)
        var status = service.currentStatus()
        while !status.running && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
            status = service.currentStatus()
        }
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.port, port)
        XCTAssertFalse(status.pairingCode.isEmpty)

        var crossOriginRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/pair")!)
        crossOriginRequest.httpMethod = "POST"
        crossOriginRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        crossOriginRequest.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        crossOriginRequest.httpBody = Data("{\"code\":\"\(status.pairingCode)\"}".utf8)
        let (_, crossOriginResponse) = try await URLSession.shared.data(for: crossOriginRequest)
        XCTAssertEqual((crossOriginResponse as? HTTPURLResponse)?.statusCode, 403)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/pair")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"code\":\"\(status.pairingCode)\"}".utf8)
        let (body, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        struct PairResponse: Decodable { let token: String }
        let firstToken = try JSONDecoder().decode(PairResponse.self, from: body).token

        // Keep the first browser session alive while pairing again. This is
        // the race that previously made a valid QR/manual code appear broken:
        // the second HTTP exchange succeeded, but its WebSocket was rejected
        // because the old socket still occupied the single browser slot.
        // The bearer token rides in the Sec-WebSocket-Protocol handshake
        // header (fixed name + token), never in the URL.
        var firstSocketRequest = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/socket")!)
        firstSocketRequest.setValue("vamp-auth, \(firstToken)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let firstSocket = URLSession.shared.webSocketTask(with: firstSocketRequest)
        firstSocket.resume()
        _ = try await firstSocket.receive()

        var manualRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/pair")!)
        manualRequest.httpMethod = "POST"
        manualRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        manualRequest.httpBody = Data("{\"code\":\"\(status.pairingCode)\"}".utf8)
        let (manualBody, manualResponse) = try await URLSession.shared.data(for: manualRequest)
        XCTAssertEqual((manualResponse as? HTTPURLResponse)?.statusCode, 200)
        let token = try JSONDecoder().decode(PairResponse.self, from: manualBody).token

        var socketRequest = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/socket")!)
        socketRequest.setValue("vamp-auth, \(token)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let socket = URLSession.shared.webSocketTask(with: socketRequest)
        socket.resume()
        let hello = try await socket.receive()
        guard case let .string(helloJSON) = hello,
              let helloData = helloJSON.data(using: .utf8) else {
            XCTFail("Expected a JSON hello message")
            return
        }
        struct HelloMessage: Decodable {
            struct Features: Decodable {
                let chat: Bool
                let taskPlans: Bool
                let workspaces: Bool
            }
            let maxTerminals: Int
            let features: Features
            let capabilities: [String]
        }
        let helloMessage = try JSONDecoder().decode(HelloMessage.self, from: helloData)
        XCTAssertEqual(helloMessage.maxTerminals, HostTerminalService.maxActiveTerminals)
        XCTAssertTrue(helloMessage.capabilities.contains("multiple-terminals"))
        XCTAssertTrue(helloMessage.capabilities.contains("chat"))
        XCTAssertTrue(helloMessage.capabilities.contains("task-plans"))
        XCTAssertFalse(helloMessage.capabilities.contains("workspaces"))
        XCTAssertTrue(helloMessage.features.chat)
        XCTAssertTrue(helloMessage.features.taskPlans)
        XCTAssertFalse(helloMessage.features.workspaces)

        // Exercise a real browser open command whose JSON payload crosses the
        // 125-byte WebSocket boundary. Safari includes the selected working
        // directory, so a broken extended-length decoder otherwise leaves the
        // UI stuck at Opening with no PTY child and no error event.
        let terminalID = UUID()
        let openJSON = """
        {"type":"open","terminalID":"\(terminalID.uuidString.lowercased())","cols":42,"rows":24,"term":"xterm-256color","workingDirectory":"\(NSHomeDirectory())"}
        """
        XCTAssertGreaterThan(openJSON.utf8.count, 125)
        try await socket.send(.string(openJSON))
        var receivedReady = false
        for _ in 0..<4 {
            let message = try await socket.receive()
            guard case let .string(json) = message,
                  let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if object["type"] as? String == "ready",
               (object["terminalID"] as? String)?.lowercased() == terminalID.uuidString.lowercased() {
                receivedReady = true
                break
            }
        }
        XCTAssertTrue(receivedReady)

        // Exercise the complete browser composer path after terminal-ready.
        // A browser can otherwise look connected while input is silently
        // dropped between the WebSocket adapter and HostTerminalService.
        let marker = "vamp-browser-roundtrip-\(UUID().uuidString.lowercased())"
        let inputData = Data("printf '\(marker)\\n'\r".utf8).base64EncodedString()
        let inputJSON = """
        {"type":"input","terminalID":"\(terminalID.uuidString.lowercased())","data":"\(inputData)"}
        """
        try await socket.send(.string(inputJSON))
        var receivedMarker = false
        for _ in 0..<12 {
            let message = try await socket.receive()
            guard case let .string(json) = message,
                  let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "output",
                  (object["terminalID"] as? String)?.lowercased() == terminalID.uuidString.lowercased(),
                  let encoded = object["data"] as? String,
                  let output = Data(base64Encoded: encoded),
                  let text = String(data: output, encoding: .utf8) else { continue }
            if text.contains(marker) {
                receivedMarker = true
                break
            }
        }
        XCTAssertTrue(receivedMarker, "Browser input must execute and stream output over the same terminal ID")
        firstSocket.cancel(with: .goingAway, reason: nil)
        socket.cancel(with: .goingAway, reason: nil)
    }

    func testBrowserWebSocketRejectsTokenInURLQueryAndMissingSubprotocol() async throws {
        let service = HostBrowserControlService()
        service.terminalModeProvider = { true }
        let port: UInt16 = 19076
        service.start(port: port)
        defer { service.stop() }

        let deadline = Date().addingTimeInterval(3)
        var status = service.currentStatus()
        while !status.running && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
            status = service.currentStatus()
        }
        XCTAssertTrue(status.running)

        var pairRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/pair")!)
        pairRequest.httpMethod = "POST"
        pairRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        pairRequest.httpBody = Data("{\"code\":\"\(status.pairingCode)\"}".utf8)
        let (body, response) = try await URLSession.shared.data(for: pairRequest)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        struct PairResponse: Decodable { let token: String }
        let token = try JSONDecoder().decode(PairResponse.self, from: body).token

        // The legacy path put the bearer token in the URL query. It must no
        // longer authenticate: URLs leak to history, referrers, and logs.
        let legacySocket = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/socket?token=\(token)")!
        )
        legacySocket.resume()
        do {
            _ = try await legacySocket.receive()
            XCTFail("A token in the URL query must not authenticate the WebSocket")
        } catch {
            // Expected: the upgrade is refused (401) so the task fails to open.
        }

        // A handshake offering no auth subprotocol at all must also be refused.
        let bareSocket = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/socket")!
        )
        bareSocket.resume()
        do {
            _ = try await bareSocket.receive()
            XCTFail("A WebSocket without the auth subprotocol must not open")
        } catch {
            // Expected.
        }
    }

    func testIndependentTerminalsCanResizeInterleaveOutputAndCloseOne() throws {
        let service = HostTerminalService()
        let recorder = EnvelopeRecorder()
        service.sendEnvelope = { recorder.append($0) }
        defer { service.sessionDidEnd() }

        let sessionID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        service.handleOpen(TerminalOpenMessage(sessionID: sessionID, terminalID: firstID, cols: 80, rows: 24))
        service.handleOpen(TerminalOpenMessage(sessionID: sessionID, terminalID: secondID, cols: 100, rows: 30))

        let ready = try waitFor(recorder) { envelopes in
            readyIDs(in: envelopes).isSuperset(of: [firstID, secondID])
        }
        let readyMessages = try ready.compactMap { envelope -> TerminalReadyMessage? in
            guard envelope.kind == .terminalReady else { return nil }
            return try envelope.decodeTerminalReady()
        }
        XCTAssertEqual(Set(readyMessages.map(\.terminalID)), [firstID, secondID])
        XCTAssertEqual(readyMessages.first(where: { $0.terminalID == firstID })?.cols, 80)
        XCTAssertEqual(readyMessages.first(where: { $0.terminalID == secondID })?.rows, 30)

        // Verify that resize is applied to one PTY only: `stty size` reports rows first.
        service.handleResize(TerminalResizeMessage(
            sessionID: sessionID,
            terminalID: firstID,
            cols: 120,
            rows: 42
        ))
        service.handleInput(TerminalInputMessage(
            sessionID: sessionID,
            terminalID: firstID,
            data: Data("stty size\n".utf8)
        ))
        service.handleInput(TerminalInputMessage(
            sessionID: sessionID,
            terminalID: secondID,
            data: Data("printf 'vamp-second-alive\\n'\n".utf8)
        ))
        // Mobile/Web composers submit the PTY Enter key as carriage return.
        // Keep this covered separately from script-style LF input so a host
        // termios regression cannot degrade into an echoed-but-unrun command.
        service.handleInput(TerminalInputMessage(
            sessionID: sessionID,
            terminalID: firstID,
            data: Data("printf 'vamp-carriage-return-ok\\n'\r".utf8)
        ))

        let output = try waitFor(recorder) { envelopes in
            outputText(for: firstID, in: envelopes).contains("42 120")
                && outputText(for: firstID, in: envelopes).contains("vamp-carriage-return-ok")
                && outputText(for: secondID, in: envelopes).contains("vamp-second-alive")
        }
        let outputTerminalIDs = Set(output.compactMap { envelope -> UUID? in
            guard envelope.kind == .terminalOutput,
                  let message = try? envelope.decodeTerminalOutput() else { return nil }
            return message.terminalID
        })
        XCTAssertTrue(outputTerminalIDs.contains(firstID))
        XCTAssertTrue(outputTerminalIDs.contains(secondID))

        // Closing the first terminal must not tear down the second one.
        service.handleClose(TerminalCloseMessage(
            sessionID: sessionID,
            terminalID: firstID,
            reason: "user-closed"
        ))
        service.handleInput(TerminalInputMessage(
            sessionID: sessionID,
            terminalID: secondID,
            data: Data("printf 'vamp-second-still-open\\n'\n".utf8)
        ))
        _ = try waitFor(recorder) { envelopes in
            outputText(for: secondID, in: envelopes).contains("vamp-second-still-open")
        }
    }

    func testEightTerminalLimitAndSessionCleanup() throws {
        XCTAssertEqual(HostTerminalService.maxActiveTerminals, 8)

        let service = HostTerminalService()
        let recorder = EnvelopeRecorder()
        service.sendEnvelope = { recorder.append($0) }
        defer { service.sessionDidEnd() }

        let sessionID = UUID()
        let terminalIDs = (0..<HostTerminalService.maxActiveTerminals).map { _ in UUID() }
        for terminalID in terminalIDs {
            service.handleOpen(TerminalOpenMessage(
                sessionID: sessionID,
                terminalID: terminalID,
                cols: 80,
                rows: 24
            ))
        }

        _ = try waitFor(recorder) { envelopes in
            readyIDs(in: envelopes) == Set(terminalIDs)
        }

        let rejectedID = UUID()
        service.handleOpen(TerminalOpenMessage(
            sessionID: sessionID,
            terminalID: rejectedID,
            cols: 80,
            rows: 24
        ))
        _ = try waitFor(recorder) { envelopes in
            envelopes.contains { envelope in
                guard envelope.kind == .terminalClose,
                      let message = try? envelope.decodeTerminalClose() else { return false }
                return message.terminalID == rejectedID && message.reason == "terminal-capacity"
            }
        }

        // Session teardown removes every active PTY, allowing a fresh terminal
        // to open without relying on shell exit timing.
        service.sessionDidEnd()
        let replacementID = UUID()
        service.handleOpen(TerminalOpenMessage(
            sessionID: sessionID,
            terminalID: replacementID,
            cols: 80,
            rows: 24
        ))
        _ = try waitFor(recorder) { envelopes in
            readyIDs(in: envelopes).contains(replacementID)
        }
    }

    func testTerminalDisablementClosesEveryActiveTerminalWithReason() throws {
        let service = HostTerminalService()
        let recorder = EnvelopeRecorder()
        service.sendEnvelope = { recorder.append($0) }
        defer { service.sessionDidEnd() }

        let sessionID = UUID()
        let terminalIDs = [UUID(), UUID()]
        for terminalID in terminalIDs {
            service.handleOpen(TerminalOpenMessage(
                sessionID: sessionID,
                terminalID: terminalID,
                cols: 80,
                rows: 24
            ))
        }

        _ = try waitFor(recorder) { envelopes in
            readyIDs(in: envelopes) == Set(terminalIDs)
        }

        service.sessionDidEnd(notifyClient: true, reason: "terminal-disabled")
        _ = try waitFor(recorder) { envelopes in
            let disabledIDs = Set(envelopes.compactMap { envelope -> UUID? in
                guard envelope.kind == .terminalClose,
                      let message = try? envelope.decodeTerminalClose(),
                      message.reason == "terminal-disabled" else { return nil }
                return message.terminalID
            })
            return disabledIDs == Set(terminalIDs)
        }
    }

    func testSemanticTaskPlanEventsRouteOnlyToTheMatchingTerminalSession() throws {
        let service = HostTerminalService()
        let recorder = EnvelopeRecorder()
        service.sendEnvelope = { recorder.append($0) }
        defer { service.sessionDidEnd() }

        let sessionID = UUID()
        let terminalID = UUID()
        service.handleOpen(TerminalOpenMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            cols: 80,
            rows: 24
        ))

        _ = try waitFor(recorder) { readyIDs(in: $0).contains(terminalID) }

        let first = SessionTask(order: 1, title: "Audit the terminal")
        let second = SessionTask(order: 2, title: "Run regression tests")
        let plan = SessionTaskPlan(
            sessionID: sessionID,
            terminalID: terminalID,
            title: "Work plan",
            tasks: [first, second],
            source: .native
        )
        service.publishTaskPlanEvent(SessionTaskEventMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            event: .planCreated(plan)
        ))
        // A stale session must not be able to mutate this terminal's plan.
        service.publishTaskPlanEvent(SessionTaskEventMessage(
            sessionID: UUID(),
            terminalID: terminalID,
            event: .taskStarted(first.id)
        ))
        service.publishTaskPlanEvent(SessionTaskEventMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            event: .planUpdated(SessionTaskPlan(
                sessionID: UUID(),
                terminalID: terminalID,
                title: "Wrong session",
                tasks: [first, second],
                source: .native
            ))
        ))

        let events = try waitFor(recorder) { envelopes in
            envelopes.contains { envelope in
                guard envelope.kind == .taskPlanEvent,
                      let message = try? envelope.decodeTaskPlanEvent() else { return false }
                if case .planCreated(let received) = message.event {
                    return message.sessionID == sessionID
                        && message.terminalID == terminalID
                        && received.tasks.map(\.id) == [first.id, second.id]
                }
                return false
            }
        }
        let taskPlanEvents = events.filter { $0.kind == .taskPlanEvent }
        XCTAssertEqual(taskPlanEvents.count, 1)
    }

    func testSemanticTaskPlanFallbackRequiresStrongPlanSyntax() throws {
        let service = HostTerminalService()
        let recorder = EnvelopeRecorder()
        service.sendEnvelope = { recorder.append($0) }
        defer { service.sessionDidEnd() }

        let sessionID = UUID()
        let terminalID = UUID()
        service.handleOpen(TerminalOpenMessage(sessionID: sessionID, terminalID: terminalID, cols: 80, rows: 24))
        _ = try waitFor(recorder) { readyIDs(in: $0).contains(terminalID) }

        service.consumeSemanticAgentOutput(
            "1. One paragraph\n2. Another paragraph",
            sessionID: sessionID,
            terminalID: terminalID
        )
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertFalse(recorder.snapshot().contains { $0.kind == .taskPlanEvent })

        service.consumeSemanticAgentOutput(
            "Implementation plan:\n1. Audit the terminal\n2. Run regression tests",
            sessionID: sessionID,
            terminalID: terminalID
        )
        _ = try waitFor(recorder) { envelopes in
            envelopes.contains { envelope in
                guard envelope.kind == .taskPlanEvent,
                      let message = try? envelope.decodeTaskPlanEvent() else { return false }
                if case .planCreated(let plan) = message.event {
                    return plan.source == .inferred && plan.tasks.count == 2
                }
                return false
            }
        }
    }

    private func waitFor(
        _ recorder: EnvelopeRecorder,
        timeout: TimeInterval = 8,
        condition: ([DataChannelEnvelope]) -> Bool
    ) throws -> [DataChannelEnvelope] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = recorder.snapshot()
            if condition(snapshot) { return snapshot }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("Condition was not satisfied within \(timeout) seconds")
        throw NSError(domain: "HostTerminalServiceTests", code: 1)
    }

    private func readyIDs(in envelopes: [DataChannelEnvelope]) -> Set<UUID> {
        Set(envelopes.compactMap { envelope in
            guard envelope.kind == .terminalReady,
                  let message = try? envelope.decodeTerminalReady() else { return nil }
            return message.terminalID
        })
    }

    private func outputText(for terminalID: UUID, in envelopes: [DataChannelEnvelope]) -> String {
        envelopes.compactMap { envelope in
            guard envelope.kind == .terminalOutput,
                  let message = try? envelope.decodeTerminalOutput(),
                  message.terminalID == terminalID else { return nil }
            return String(decoding: message.data, as: UTF8.self)
        }.joined()
    }

    private final class EnvelopeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var envelopes: [DataChannelEnvelope] = []

        func append(_ envelope: DataChannelEnvelope) {
            lock.lock()
            envelopes.append(envelope)
            lock.unlock()
        }

        func snapshot() -> [DataChannelEnvelope] {
            lock.lock()
            defer { lock.unlock() }
            return envelopes
        }
    }
}
#endif
