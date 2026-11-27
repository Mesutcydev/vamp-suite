import Foundation
import Network
import XCTest
@testable import ClientiOS

/// A loopback HTTP server that answers from a script, so the Assistant client is exercised over real
/// sockets: the framing the Vamp Assistant host uses (Content-Length JSON, chunked and
/// `Connection: close` streams) and the ways a connection misbehaves.
private final class ScriptedServer: @unchecked Sendable {
    struct Received {
        let head: String
        let body: Data
    }

    enum Step {
        case bytes(Data)
        case pause(TimeInterval)
        case close
        case hang
    }

    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "scripted-server")
    private let lock = NSLock()
    private var _accepted = 0
    private var _closed = 0
    private var _received: [Received] = []
    private let script: @Sendable (Received) -> [Step]

    var accepted: Int { lock.lock(); defer { lock.unlock() }; return _accepted }
    var closedByClient: Int { lock.lock(); defer { lock.unlock() }; return _closed }
    var received: [Received] { lock.lock(); defer { lock.unlock() }; return _received }

    init(script: @escaping @Sendable (Received) -> [Step]) throws {
        self.script = script
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { _ in }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
        listener.newConnectionHandler = { [unowned self] connection in self.accept(connection) }
    }

    func stop() { listener.cancel() }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    private func accept(_ connection: NWConnection) {
        lock.lock(); _accepted += 1; lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.noteClosed() }
            if case .cancelled = state { self?.noteClosed() }
        }
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    private func noteClosed() { lock.lock(); _closed += 1; lock.unlock() }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer.subdata(in: 0..<end.lowerBound), as: UTF8.self)
                let length = head.lowercased().components(separatedBy: "\r\n")
                    .first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if buffer.count - end.upperBound >= length {
                    let body = buffer.subdata(in: end.upperBound..<(end.upperBound + length))
                    let leftover = buffer.subdata(in: (end.upperBound + length)..<buffer.count)
                    let request = Received(head: head, body: body)
                    self.lock.lock(); self._received.append(request); self.lock.unlock()
                    self.run(self.script(request)[...], on: connection) { self.readRequest(on: connection, buffer: leftover) }
                    return
                }
            }
            if error != nil || isComplete { self.noteClosed(); connection.cancel(); return }
            self.readRequest(on: connection, buffer: buffer)
        }
    }

    private func run(_ steps: ArraySlice<Step>, on connection: NWConnection, then next: @escaping () -> Void) {
        guard let step = steps.first else { next(); return }
        let rest = steps.dropFirst()
        switch step {
        case .bytes(let data):
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.run(rest, on: connection, then: next)
            })
        case .pause(let seconds):
            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.run(rest, on: connection, then: next) }
        case .close:
            connection.cancel()
        case .hang:
            // Say nothing, but notice when the client goes away.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
                if isComplete || error != nil { self?.noteClosed() }
            }
        }
    }
}

private func reply(_ status: String = "200 OK", headers: [String] = [], body: String = "") -> Data {
    Data(("HTTP/1.1 \(status)\r\n" + headers.map { $0 + "\r\n" }.joined()
          + "Content-Length: \(body.utf8.count)\r\n\r\n" + body).utf8)
}

private func get(_ url: URL, token: String? = nil, timeout: TimeInterval = 5) -> URLRequest {
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    return request
}

final class AssistantHTTPTests: XCTestCase {
    func testJSONRequestAndResponseOverALoopbackSocket() async throws {
        let server = try ScriptedServer { _ in [.bytes(reply(headers: ["Content-Type: application/json", "Connection: keep-alive"], body: "{\"ok\":true}"))] }
        defer { server.stop() }

        let (body, response) = try await AssistantHTTP.send(get(server.url("/api/control?x=1"), token: "abc123"))

        XCTAssertEqual(String(decoding: body, as: UTF8.self), "{\"ok\":true}")
        XCTAssertEqual(response.statusCode, 200)
        let head = try XCTUnwrap(server.received.first?.head)
        XCTAssertTrue(head.hasPrefix("GET /api/control?x=1 HTTP/1.1\r\n"), head)
        XCTAssertTrue(head.contains("Host: 127.0.0.1:\(server.port)"), head)
        XCTAssertTrue(head.contains("Authorization: Bearer abc123"), head)
        XCTAssertTrue(head.contains("Accept-Encoding: identity"), head)
    }

    func testPostSendsItsBodyAndLength() async throws {
        let server = try ScriptedServer { _ in [.bytes(reply(body: "{}"))] }
        defer { server.stop() }
        var request = get(server.url("/api/control/input"))
        request.httpMethod = "POST"
        request.httpBody = Data("{\"commands\":[1,2,3]}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        _ = try await AssistantHTTP.send(request)

        let seen = try XCTUnwrap(server.received.first)
        XCTAssertTrue(seen.head.hasPrefix("POST /api/control/input HTTP/1.1"))
        XCTAssertTrue(seen.head.contains("Content-Length: 20"))
        XCTAssertTrue(seen.head.contains("Content-Type: application/json"))
        XCTAssertEqual(String(decoding: seen.body, as: UTF8.self), "{\"commands\":[1,2,3]}")
    }

    func testErrorStatusIsReturnedAndARedirectIsNeverFollowed() async throws {
        let server = try ScriptedServer { _ in
            [.bytes(reply("302 Found", headers: ["Location: http://127.0.0.1:1/elsewhere"]))]
        }
        defer { server.stop() }

        let (_, response) = try await AssistantHTTP.send(get(server.url("/api/pair"), token: "secret"))

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(server.received.count, 1, "the bearer token must not be forwarded to a Location")
        XCTAssertEqual(server.accepted, 1)
    }

    func testChunkedStreamIsReassembledAndParsedIntoFrames() async throws {
        let boundary = "beet-test"
        let parameterSets = Data([0, 0, 0, 1, 0x67, 0x64])
        let avcc = Data([0, 0, 0, 2, 0x65, 0x01])
        var part = Data(
            "--\(boundary)\r\nContent-Type: video/avc\r\nContent-Length: \(parameterSets.count + avcc.count)\r\nX-Beet-Keyframe: 1\r\nX-Beet-Params-Length: \(parameterSets.count)\r\nX-Beet-Image-Width: 1920\r\nX-Beet-Image-Height: 1080\r\n\r\n".utf8
        )
        part.append(parameterSets)
        part.append(avcc)
        part.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let server = try ScriptedServer { _ in
            var steps: [ScriptedServer.Step] = [.bytes(Data((
                "HTTP/1.1 200 OK\r\nContent-Type: multipart/mixed; boundary=\(boundary)\r\nTransfer-Encoding: chunked\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            ).utf8))]
            // The chunk framing is cut at arbitrary points, as TCP is free to do.
            var framed = Data()
            var offset = 0
            for size in [5, 9, 7, part.count] where offset < part.count {
                let piece = part.subdata(in: offset..<min(offset + size, part.count))
                framed.append(Data((String(piece.count, radix: 16) + "\r\n").utf8) + piece + Data("\r\n".utf8))
                offset += piece.count
            }
            framed.append(Data("0\r\n\r\n".utf8))
            var cut = 0
            while cut < framed.count {
                let next = min(cut + 11, framed.count)
                steps.append(.bytes(framed.subdata(in: cut..<next)))
                steps.append(.pause(0.005))
                cut = next
            }
            steps.append(.close)
            return steps
        }
        defer { server.stop() }

        var parser = BeetCodeScreenStreamParser()
        var frames: [BeetCodeScreenFrame] = []
        for try await event in AssistantHTTP.stream(get(server.url("/api/control/screen/stream"), token: "t")) {
            switch event {
            case .head(let response):
                XCTAssertEqual(response.value(forHTTPHeaderField: "Transfer-Encoding"), "chunked")
                try parser.configure(response: response)
            case .body(let data):
                frames.append(contentsOf: try parser.append(data))
            }
        }

        let frame = try XCTUnwrap(frames.first)
        guard case let .h264(data, keyframe, params) = frame.payload else { return XCTFail("expected H.264") }
        XCTAssertEqual(data, avcc)
        XCTAssertTrue(keyframe)
        XCTAssertEqual(params, parameterSets)
    }

    func testBodyWithNoLengthEndsWhenTheServerCloses() async throws {
        let server = try ScriptedServer { _ in
            [.bytes(Data("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nhello".utf8)), .pause(0.05), .bytes(Data(" world".utf8)), .close]
        }
        defer { server.stop() }

        let (body, _) = try await AssistantHTTP.send(get(server.url("/")))

        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello world")
    }

    func testInterimContinueResponseIsSkipped() async throws {
        let server = try ScriptedServer { _ in
            [.bytes(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)), .bytes(reply(body: "ok"))]
        }
        defer { server.stop() }

        let (body, response) = try await AssistantHTTP.send(get(server.url("/")))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "ok")
    }

    func testKeepAliveConnectionIsReusedForFrequentRequests() async throws {
        let server = try ScriptedServer { _ in [.bytes(reply(headers: ["Connection: keep-alive"], body: "{}"))] }
        defer { server.stop() }

        for _ in 0..<5 { _ = try await AssistantHTTP.send(get(server.url("/api/control/input"))) }

        XCTAssertEqual(server.received.count, 5)
        XCTAssertEqual(server.accepted, 1, "one TCP connection serves them all; opening one per pointer event would add a round trip to each")
    }

    func testAConnectionTheServerAlreadyClosedIsRetriedOnceOnAFreshOne() async throws {
        let counter = Counter()
        let server = try ScriptedServer { _ in
            // The first reply promises keep-alive and then the server hangs up anyway.
            counter.next() == 0 ? [.bytes(reply(headers: ["Connection: keep-alive"], body: "one")), .close]
                                : [.bytes(reply(headers: ["Connection: keep-alive"], body: "two"))]
        }
        defer { server.stop() }

        let (first, _) = try await AssistantHTTP.send(get(server.url("/")))
        try await Task.sleep(nanoseconds: 100_000_000)
        let (second, _) = try await AssistantHTTP.send(get(server.url("/")))

        XCTAssertEqual(String(decoding: first, as: UTF8.self), "one")
        XCTAssertEqual(String(decoding: second, as: UTF8.self), "two")
        XCTAssertEqual(server.accepted, 2)
    }

    func testConnectionClosedBeforeTheBodyIsCompleteIsALostConnection() async throws {
        let server = try ScriptedServer { _ in
            [.bytes(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n12345".utf8)), .close]
        }
        defer { server.stop() }

        do {
            _ = try await AssistantHTTP.send(get(server.url("/")))
            XCTFail("a truncated body must not look like a complete one")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
    }

    func testRefusedConnectionIsReportedAsCannotConnect() async throws {
        let server = try ScriptedServer { _ in [] }
        let url = server.url("/")
        server.stop()
        try await Task.sleep(nanoseconds: 200_000_000)

        do {
            _ = try await AssistantHTTP.send(get(url, timeout: 5))
            XCTFail("nothing is listening")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        }
    }

    func testSilentServerTimesOut() async throws {
        let server = try ScriptedServer { _ in [.hang] }
        defer { server.stop() }
        let started = Date()

        do {
            _ = try await AssistantHTTP.send(get(server.url("/"), timeout: 0.5))
            XCTFail("a silent server must time out")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        }
    }

    func testCancellingAStreamClosesTheConnection() async throws {
        let server = try ScriptedServer { _ in
            [.bytes(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)), .hang]
        }
        defer { server.stop() }

        let consumer = Task {
            for try await _ in AssistantHTTP.stream(get(server.url("/stream"), timeout: 60)) {}
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        consumer.cancel()
        _ = try? await consumer.value

        for _ in 0..<40 where server.closedByClient == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertGreaterThanOrEqual(server.closedByClient, 1, "cancelling must release the socket")
    }

    func testRequestSplittingThroughAHeaderIsRefused() async throws {
        // Foundation already drops a header whose *value* holds CR/LF, but it keeps such a name.
        var request = get(URL(string: "http://127.0.0.1:9/")!)
        request.setValue("1", forHTTPHeaderField: "X-A\r\nX-Injected: 1")
        do {
            _ = try await AssistantHTTP.send(request)
            XCTFail("a CR/LF in a header name must be refused")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badURL)
        }
    }

    func testHostNamesAndIPv6LiteralsAreHandled() async throws {
        let server = try ScriptedServer { _ in [.bytes(reply(body: "named"))] }
        defer { server.stop() }
        // `localhost` resolves to ::1 and 127.0.0.1; the server listens on the second.
        let (body, _) = try await AssistantHTTP.send(get(URL(string: "http://localhost:\(server.port)/")!))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "named")

        let bytes = try AssistantHTTP.serialize(get(URL(string: "http://[fe80::1]:9575/api/control")!), keepAlive: true)
        let head = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(head.contains("Host: [fe80::1]:9575\r\n"), head)
        let plain = try AssistantHTTP.serialize(get(URL(string: "http://mac.tail1234.ts.net/api")!), keepAlive: false)
        XCTAssertTrue(String(decoding: plain, as: UTF8.self).contains("Host: mac.tail1234.ts.net\r\n"))
        XCTAssertTrue(String(decoding: plain, as: UTF8.self).contains("Connection: close\r\n"))
    }

    func testLargeBodyArrivesIntact() async throws {
        let payload = String(repeating: "0123456789abcdef", count: 6 * 1024 * 1024 / 16)
        let server = try ScriptedServer { _ in [.bytes(reply(body: payload))] }
        defer { server.stop() }

        let (body, _) = try await AssistantHTTP.send(get(server.url("/api/control/applications")))

        XCTAssertEqual(body.count, payload.utf8.count)
        XCTAssertEqual(String(decoding: body.prefix(32), as: UTF8.self), String(payload.prefix(32)))
    }
}

final class AssistantHTTPParserTests: XCTestCase {
    private let url = URL(string: "http://192.168.1.20:9575/api")!

    private func run(_ wire: Data, chunk: Int) throws -> (HTTPURLResponse?, Data, Bool) {
        var parser = AssistantHTTP.Parser(url: url)
        var head: HTTPURLResponse?
        var body = Data()
        var offset = 0
        while offset < wire.count {
            let next = min(offset + chunk, wire.count)
            for step in try parser.feed(wire.subdata(in: offset..<next)) {
                switch step {
                case .head(let response): head = response
                case .body(let data): body.append(data)
                }
            }
            offset = next
        }
        return (head, body, parser.isFinished)
    }

    func testTheSameResponseParsesIdenticallyAtEverySplitSize() throws {
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-Beet: 1\r\n\r\n4;ext=1\r\nWiki\r\n5\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\nTrailer: x\r\n\r\n".utf8)
        for size in [1, 2, 3, 7, 64, chunked.count] {
            let (head, body, finished) = try run(chunked, chunk: size)
            XCTAssertEqual(head?.statusCode, 200, "split \(size)")
            XCTAssertEqual(String(decoding: body, as: UTF8.self), "Wikipedia in\r\n\r\nchunks.", "split \(size)")
            XCTAssertTrue(finished, "split \(size)")
            XCTAssertEqual(head?.value(forHTTPHeaderField: "x-beet"), "1")
        }
    }

    func testStatusLineAndHeaderGarbageIsRejected() {
        for wire in ["NOTHTTP 200 OK\r\n\r\n", "HTTP/1.1 abc OK\r\n\r\n", "HTTP/1.1 200 OK\r\nbroken header line\r\n\r\n",
                     "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"] {
            XCTAssertThrowsError(try run(Data(wire.utf8), chunk: 4096), wire)
        }
    }

    func testOnlyACompleteLengthDelimitedResponseIsReusable() throws {
        var complete = AssistantHTTP.Parser(url: url)
        _ = try complete.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8))
        XCTAssertTrue(complete.reusable)

        var closing = AssistantHTTP.Parser(url: url)
        _ = try closing.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8))
        XCTAssertFalse(closing.reusable)

        var untilClose = AssistantHTTP.Parser(url: url)
        _ = try untilClose.feed(Data("HTTP/1.1 200 OK\r\n\r\nbody".utf8))
        _ = try untilClose.endOfStream()
        XCTAssertFalse(untilClose.reusable)

        var http10 = AssistantHTTP.Parser(url: url)
        _ = try http10.feed(Data("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8))
        XCTAssertFalse(http10.reusable, "HTTP/1.0 closes by default")
    }

    func testAnOversizedHeadIsRefused() {
        var parser = AssistantHTTP.Parser(url: url)
        XCTAssertThrowsError(try parser.feed(Data(repeating: 0x61, count: AssistantHTTP.maxHeadBytes + 10)))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; defer { value += 1 }; return value }
}
