import Combine
import CoreImage
import CoreVideo
import Foundation
import TransportWebRTC

#if canImport(Security)
import Security
#endif

// MARK: - Vamp Assistant compatibility

/// The Vamp Assistant host is a separate, authenticated HTTP peer. It deliberately does not
/// participate in Vamp's signed WebRTC protocol, so it is kept behind an explicit product
/// boundary rather than being made to look like a Vamp Host in Bonjour discovery.
struct BeetCodeRemoteEndpoint: Equatable, Hashable, Sendable {
    let url: URL
    let pairingCode: String?

    static let defaultPort = 9575

    static func parse(address: String, pairingCode: String? = nil) throws -> Self {
        let candidate = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { throw BeetCodeRemoteError.invalidAddress }
        let withScheme = candidate.contains("://") ? candidate : "http://\(candidate)"
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            throw BeetCodeRemoteError.invalidAddress
        }

        let port = components.port ?? defaultPort
        guard (1...65535).contains(port) else { throw BeetCodeRemoteError.invalidAddress }
        if scheme == "http", !isPrivateHost(host) {
            throw BeetCodeRemoteError.insecurePublicAddress
        }

        let queryCode = components.queryItems?.first(where: { $0.name == "pair" })?.value
        let rawCode = queryCode ?? pairingCode
        let normalizedCode = rawCode.map { String($0.filter { $0 >= "0" && $0 <= "9" }) }
        if let normalizedCode, normalizedCode.count != 6 {
            throw BeetCodeRemoteError.invalidPairingCode
        }

        components.port = port
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw BeetCodeRemoteError.invalidAddress }
        return Self(url: url, pairingCode: normalizedCode)
    }

    static func savedURL(address: String) throws -> URL {
        try parse(address: address).url
    }

    private static func isPrivateHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized.hasSuffix(".local")
            || normalized.hasSuffix(".ts.net") {
            return true
        }

        let parts = normalized.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10
            || (parts[0] == 100 && (64...127).contains(parts[1])) // Tailscale CGNAT range
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || parts[0] == 127
    }
}

enum BeetCodeRemoteError: LocalizedError, Equatable, Sendable {
    case invalidAddress
    case insecurePublicAddress
    case invalidPairingCode
    case notConnected
    case controlUnavailable(String)
    case server(String)
    case invalidResponse
    case invalidResponseReason(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Enter the private Vamp Assistant address shown on your Mac."
        case .insecurePublicAddress:
            return "Plain HTTP is allowed only for a private LAN, Tailscale, or local address."
        case .invalidPairingCode:
            return "Enter the six-digit pairing code shown by Vamp Assistant."
        case .notConnected:
            return "Pair with your Mac first."
        case .controlUnavailable(let message):
            return message
        case .server(let message):
            return message
        case .invalidResponse:
            return "Vamp Assistant returned an unreadable response."
        case .invalidResponseReason(let reason):
            return "Vamp Assistant stream error: \(reason)"
        }
    }
}

struct BeetCodePairResponse: Decodable, Sendable {
    let token: String
    let expiresAt: Double
    let product: String?
}

struct BeetCodeControlStatus: Decodable, Equatable, Sendable {
    let enabled: Bool
    let screenRecording: Bool
    let accessibility: Bool
    let ready: Bool
    let locked: Bool?
    let remoteUnlockEnabled: Bool?
    let remoteUnlockAvailable: Bool?
    let remoteUnlockMessage: String?
    let supportsCursorlessCapture: Bool?
    let message: String?
    let displayX: Double?
    let displayY: Double?
    let displayWidth: Double?
    let displayHeight: Double?
    let displays: [BeetCodeRemoteDisplay]?

    /// Vamp Assistant only accepts login passwords over its encrypted Tailscale
    /// route. Older Assistant builds omit these fields and keep the form hidden.
    var shouldOfferRemoteUnlock: Bool {
        locked == true && remoteUnlockAvailable == true
    }
}

struct BeetCodeRemoteDisplay: Decodable, Equatable, Hashable, Identifiable, Sendable {
    let id: UInt32
    let name: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct BeetCodeRemoteApplication: Decodable, Equatable, Hashable, Identifiable, Sendable {
    let windowID: UInt32?
    let bundleIdentifier: String?
    let name: String
    let windowTitle: String?
    let width: Double
    let height: Double
    let isRunning: Bool
    let isActive: Bool
    let iconPNGBase64: String?

    var id: String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty { return bundleIdentifier }
        if let windowID { return "window:\(windowID)" }
        return "name:\(name)"
    }

    var streamListID: String { windowID.map { "window:\($0)" } ?? id }

    var detail: String {
        if let windowTitle, !windowTitle.isEmpty, windowTitle != name {
            return "\(windowTitle) · \(Int(width))×\(Int(height))"
        }
        if width > 0, height > 0 { return "\(Int(width))×\(Int(height))" }
        return isRunning ? "Running" : "Installed"
    }

    private enum CodingKeys: String, CodingKey {
        case windowID, bundleIdentifier, name, windowTitle, width, height
        case isRunning, isActive, iconPNGBase64
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windowID = try values.decodeIfPresent(UInt32.self, forKey: .windowID)
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        name = try values.decode(String.self, forKey: .name)
        windowTitle = try values.decodeIfPresent(String.self, forKey: .windowTitle)
        width = try values.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try values.decodeIfPresent(Double.self, forKey: .height) ?? 0
        isRunning = try values.decodeIfPresent(Bool.self, forKey: .isRunning) ?? (windowID != nil)
        isActive = try values.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        iconPNGBase64 = try values.decodeIfPresent(String.self, forKey: .iconPNGBase64)
    }
}

private struct BeetCodeRemoteApplicationsResponse: Decodable, Sendable {
    let applications: [BeetCodeRemoteApplication]
}

private struct BeetCodeRemoteApplicationResponse: Decodable, Sendable {
    let application: BeetCodeRemoteApplication
}

struct BeetCodeDisplayGeometry: Equatable, Sendable {
    let imageWidth: Int
    let imageHeight: Int
    let displayX: Double
    let displayY: Double
    let displayWidth: Double
    let displayHeight: Double
}

struct BeetCodeScreenFrame: Sendable {
    enum Payload: Sendable {
        case h264(data: Data, keyframe: Bool, parameterSets: Data?)
        case jpeg(Data)
    }

    let payload: Payload
    let geometry: BeetCodeDisplayGeometry
}

enum BeetCodeInputCommand: Equatable, Sendable {
    case click(x: Double?, y: Double?, button: String, count: Int)
    case move(x: Double, y: Double)
    case relative(dx: Double, dy: Double)
    case down(button: String)
    case up(button: String)
    case scroll(x: Double?, y: Double?, dx: Double, dy: Double)
    case type(String)
    case key(String, modifiers: [String])

    var isMotion: Bool {
        switch self {
        case .move, .relative, .scroll: return true
        default: return false
        }
    }

    /// Use the primitive button actions for taps. They are also used by drag-lock and are
    /// supported by older Assistant hosts whose synthetic `click` action could acknowledge a
    /// request without producing a usable mouse-down/up pair.
    static func clickSequence(
        x: Double?,
        y: Double?,
        button: String,
        count: Int
    ) -> [Self] {
        var commands: [Self] = []
        if let x, let y { commands.append(.move(x: x, y: y)) }
        for _ in 0..<max(count, 1) {
            commands.append(.down(button: button))
            commands.append(.up(button: button))
        }
        return commands
    }

    func wireBody() -> [String: Any] {
        switch self {
        case let .click(x, y, button, count):
            return Self.body(action: "click", x: x, y: y, button: button, count: count)
        case let .move(x, y):
            return Self.body(action: "move", x: x, y: y)
        case let .relative(dx, dy):
            return Self.body(action: "rel", x: dx, y: dy)
        case let .down(button):
            return Self.body(action: "down", button: button)
        case let .up(button):
            return Self.body(action: "up", button: button)
        case let .scroll(x, y, dx, dy):
            return Self.body(action: "scroll", x: x, y: y, dx: dx, dy: dy)
        case let .type(text):
            return Self.body(action: "type", text: text)
        case let .key(key, modifiers):
            return Self.body(action: "key", key: key, modifiers: modifiers)
        }
    }

    private static func body(
        action: String,
        x: Double? = nil,
        y: Double? = nil,
        dx: Double? = nil,
        dy: Double? = nil,
        text: String? = nil,
        key: String? = nil,
        button: String? = nil,
        count: Int? = nil,
        modifiers: [String] = []
    ) -> [String: Any] {
        var result: [String: Any] = ["action": action]
        if let x { result["x"] = x }
        if let y { result["y"] = y }
        if let dx { result["dx"] = dx }
        if let dy { result["dy"] = dy }
        if let text { result["text"] = text }
        if let key { result["key"] = key }
        if let button { result["button"] = button }
        if let count { result["count"] = count }
        if !modifiers.isEmpty { result["modifiers"] = modifiers }
        return result
    }
}

struct BeetCodeAcceptedResponse: Decodable, Sendable {
    let accepted: Bool
    let queued: Bool?
}

struct BeetCodeRemoteClient: Sendable {
    let baseURL: URL
    let token: String?

    init(endpoint: BeetCodeRemoteEndpoint, token: String? = nil) {
        self.baseURL = endpoint.url
        self.token = token
    }

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    func pair(code: String) async throws -> BeetCodePairResponse {
        var request = URLRequest(url: baseURL.appending(path: "api/pair"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await decode(BeetCodePairResponse.self, request: request)
    }

    func controlStatus(timeout: TimeInterval = 15) async throws -> BeetCodeControlStatus {
        try await request("api/control", timeout: timeout)
    }

    func applications() async throws -> [BeetCodeRemoteApplication] {
        let response: BeetCodeRemoteApplicationsResponse = try await request("api/control/apps")
        return response.applications
    }

    func launchApplication(
        bundleIdentifier: String,
        clientViewportAspect: Double? = nil
    ) async throws -> BeetCodeRemoteApplication {
        var body: [String: Any] = ["bundleIdentifier": bundleIdentifier]
        if let clientViewportAspect { body["clientViewportAspect"] = clientViewportAspect }
        let response: BeetCodeRemoteApplicationResponse = try await request(
            "api/control/apps/launch",
            method: "POST",
            body: body,
            timeout: Self.windowResolvingTimeout)
        return response.application
    }

    func quitApplication(bundleIdentifier: String) async throws {
        do {
            let _: BeetCodeAcceptedResponse = try await request(
                "api/control/apps/quit",
                method: "POST",
                body: ["bundleIdentifier": bundleIdentifier],
                timeout: 15)
        } catch BeetCodeRemoteError.server(let message) where message.contains("404") {
            throw BeetCodeRemoteError.server("This Vamp Assistant build cannot close apps yet.")
        }
    }

    func resizeApplication(
        windowID: UInt32,
        clientViewportAspect: Double
    ) async throws -> BeetCodeRemoteApplication {
        let response: BeetCodeRemoteApplicationResponse = try await request(
            "api/control/apps/resize",
            method: "POST",
            body: [
                "windowID": windowID,
                "clientViewportAspect": clientViewportAspect,
            ],
            timeout: Self.windowResolvingTimeout)
        return response.application
    }

    func sendControlBatch(_ commands: [BeetCodeInputCommand]) async throws -> BeetCodeAcceptedResponse {
        guard !commands.isEmpty else { throw BeetCodeRemoteError.invalidResponse }
        let body = ["commands": commands.map { $0.wireBody() }]
        return try await request("api/control/input", method: "POST", body: body)
    }

    func unlockMac(password: String) async throws -> BeetCodeAcceptedResponse {
        try await request(
            "api/control/unlock",
            method: "POST",
            body: ["password": password],
            timeout: 8
        )
    }

    func screenStream(
        resolution: String = "1080p",
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        showsCursor: Bool = true
    ) -> AsyncThrowingStream<BeetCodeScreenFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var components = URLComponents(
                        url: baseURL.appending(path: "api/control/screen/stream"),
                        resolvingAgainstBaseURL: false)
                    var queryItems = [URLQueryItem(name: "resolution", value: resolution)]
                    if let displayID {
                        queryItems.append(URLQueryItem(name: "display", value: String(displayID)))
                    }
                    if let windowID {
                        queryItems.append(URLQueryItem(name: "window", value: String(windowID)))
                    }
                    if !showsCursor {
                        queryItems.append(URLQueryItem(name: "cursor", value: "0"))
                    }
                    components?.queryItems = queryItems
                    guard let url = components?.url else { throw BeetCodeRemoteError.invalidAddress }
                    var request = try authorizedRequest(url: url, method: "GET")
                    request.timeoutInterval = 24 * 60 * 60
                    request.setValue("multipart/mixed, multipart/x-mixed-replace, video/avc", forHTTPHeaderField: "Accept")

                    let events = Self.dataEvents(for: request)
                    var parser = BeetCodeScreenStreamParser()
                    for try await event in events {
                        try Task.checkCancellation()
                        switch event {
                        case .headers(let response):
                            try parser.configure(response: response)
                        case .data(let data):
                            for frame in try parser.append(data) {
                                continuation.yield(frame)
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Launching and resizing block on the Mac while it opens the app and then polls
    /// ScreenCaptureKit for a shareable window. A cold start of a heavy app blows straight
    /// past the ordinary request timeout, which is why so many apps used to fail to open.
    private static let windowResolvingTimeout: TimeInterval = 60

    private func request<Response: Decodable>(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeout: TimeInterval = 15
    ) async throws -> Response {
        var request = try authorizedRequest(url: baseURL.appending(path: path), method: method)
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await decode(Response.self, request: request)
    }

    private func authorizedRequest(url: URL, method: String) throws -> URLRequest {
        guard let token, !token.isEmpty else { throw BeetCodeRemoteError.notConnected }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func decode<Response: Decodable>(_ type: Response.Type, request: URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BeetCodeRemoteError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(BeetCodeErrorBody.self, from: data).error)
                ?? "Vamp Assistant request failed (\(http.statusCode))."
            throw BeetCodeRemoteError.server(message)
        }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw BeetCodeRemoteError.invalidResponse }
    }

    private enum DataEvent: Sendable {
        case headers(HTTPURLResponse)
        case data(Data)
    }

    private static func dataEvents(for request: URLRequest) -> AsyncThrowingStream<DataEvent, Error> {
        AsyncThrowingStream { continuation in
            final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
                let continuation: AsyncThrowingStream<DataEvent, Error>.Continuation
                init(_ continuation: AsyncThrowingStream<DataEvent, Error>.Continuation) {
                    self.continuation = continuation
                }

                func urlSession(
                    _ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
                ) {
                    guard let response = response as? HTTPURLResponse else {
                        continuation.finish(throwing: BeetCodeRemoteError.invalidResponse)
                        completionHandler(.cancel)
                        return
                    }
                    continuation.yield(.headers(response))
                    completionHandler(.allow)
                }

                func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
                    continuation.yield(.data(data))
                }

                func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                    if let error, (error as? URLError)?.code != .cancelled {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
            }

            let receiver = Receiver(continuation)
            let session = URLSession(configuration: .ephemeral, delegate: receiver, delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }
}

private struct BeetCodeErrorBody: Decodable {
    let error: String
}

// MARK: - Stream parser

/// Incremental parser for Vamp Assistant's multipart H.264 stream. Keeping this parser pure makes
/// the wire contract testable without a running Mac or a live network connection.
struct BeetCodeScreenStreamParser {
    private enum Mode { case multipart(boundary: String), unwrapped(expected: Int, headers: [String: String]) }

    private var mode: Mode?
    private var buffer = Data()
    private let maxFrameBytes = 24 * 1024 * 1024
    private let maxBufferBytes = 32 * 1024 * 1024

    mutating func configure(response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw BeetCodeRemoteError.server("Vamp Assistant stream HTTP \(response.statusCode).")
        }
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("multipart") {
            guard let boundary = Self.boundary(from: contentType), !boundary.isEmpty else {
                throw BeetCodeRemoteError.invalidResponseReason("the stream boundary is missing")
            }
            mode = .multipart(boundary: boundary)
        } else if contentType.contains("video/avc") || contentType.contains("application/octet-stream") {
            let headers = Self.headerMap(from: response)
            guard let expected = Int(headers["content-length"] ?? ""), expected > 0, expected <= maxFrameBytes else {
                throw BeetCodeRemoteError.invalidResponseReason("bad stream part length")
            }
            mode = .unwrapped(expected: expected, headers: headers)
        } else {
            throw BeetCodeRemoteError.invalidResponseReason("expected H.264 stream, got \(contentType.prefix(80))")
        }
        buffer.removeAll(keepingCapacity: true)
    }

    mutating func append(_ data: Data) throws -> [BeetCodeScreenFrame] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var frames: [BeetCodeScreenFrame] = []
        switch mode {
        case .unwrapped(let expected, let headers):
            guard buffer.count >= expected else { return [] }
            let body = Data(buffer.prefix(expected))
            buffer.removeFirst(expected)
            if let frame = try Self.frame(headers: headers, body: body) { frames.append(frame) }
        case .multipart(let boundary):
            while true {
                switch try consumeMultipart(boundary: boundary) {
                case .needMoreData: return frames
                case .frame(let frame): frames.append(frame)
                case .skip: continue
                case .ended: return frames
                }
            }
        case .none:
            return []
        }
        if buffer.count > maxBufferBytes {
            let marker = Data("--\(boundaryForRecovery)".utf8)
            if let range = buffer.range(of: marker), range.lowerBound > 0 {
                buffer.removeSubrange(0..<range.lowerBound)
            } else {
                buffer.removeAll(keepingCapacity: true)
            }
        }
        return frames
    }

    private var boundaryForRecovery: String {
        if case .multipart(let boundary) = mode { return boundary }
        return "beetframe"
    }

    private enum ConsumeResult {
        case needMoreData
        case frame(BeetCodeScreenFrame)
        case skip
        case ended
    }

    private mutating func consumeMultipart(boundary: String) throws -> ConsumeResult {
        let marker = Data("--\(boundary)".utf8)
        guard let first = buffer.range(of: marker) else {
            if buffer.count > maxBufferBytes { buffer.removeAll(keepingCapacity: true) }
            return .needMoreData
        }
        if first.lowerBound > 0 { buffer.removeSubrange(0..<first.lowerBound) }
        let afterOpen = marker.count
        guard buffer.count > afterOpen else { return .needMoreData }
        if buffer.count >= afterOpen + 2, buffer[afterOpen] == 45, buffer[afterOpen + 1] == 45 {
            return .ended
        }

        let headerStart: Int
        if buffer.count >= afterOpen + 2,
           buffer[afterOpen] == 13,
           buffer[afterOpen + 1] == 10 {
            headerStart = afterOpen + 2
        } else {
            headerStart = afterOpen
        }
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator, in: headerStart..<buffer.count) else {
            return .needMoreData
        }
        let headerData = buffer.subdata(in: headerStart..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            buffer.removeSubrange(0..<min(headerEnd.upperBound, buffer.count))
            return .skip
        }
        let headers = Self.headerMap(from: headerText)
        guard let length = Int(headers["content-length"] ?? ""), length > 0 else {
            buffer.removeSubrange(0..<headerEnd.upperBound)
            return .skip
        }
        guard length <= maxFrameBytes else {
            let end = headerEnd.upperBound + length
            guard buffer.count >= end else { return .needMoreData }
            buffer.removeSubrange(0..<min(end + 2, buffer.count))
            return .skip
        }
        let bodyStart = headerEnd.upperBound
        let bodyEnd = bodyStart + length
        guard buffer.count >= bodyEnd else { return .needMoreData }
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        var consumed = bodyEnd
        if buffer.count >= consumed + 2, buffer[consumed] == 13, buffer[consumed + 1] == 10 {
            consumed += 2
        }
        buffer.removeSubrange(0..<consumed)
        guard let frame = try Self.frame(headers: headers, body: body) else { return .skip }
        return .frame(frame)
    }

    private static func frame(headers: [String: String], body: Data) throws -> BeetCodeScreenFrame? {
        let contentType = (headers["content-type"] ?? "video/avc").lowercased()
        let width = Int(Double(headers["x-beet-image-width"] ?? "") ?? 0)
        let height = Int(Double(headers["x-beet-image-height"] ?? "") ?? 0)
        guard (1...8192).contains(width), (1...8192).contains(height), !body.isEmpty else {
            throw BeetCodeRemoteError.invalidResponseReason("invalid frame dimensions")
        }
        let geometry = BeetCodeDisplayGeometry(
            imageWidth: width,
            imageHeight: height,
            displayX: Double(headers["x-beet-display-x"] ?? "") ?? 0,
            displayY: Double(headers["x-beet-display-y"] ?? "") ?? 0,
            displayWidth: max(Double(headers["x-beet-display-width"] ?? "") ?? Double(width), 1),
            displayHeight: max(Double(headers["x-beet-display-height"] ?? "") ?? Double(height), 1))

        if contentType.contains("jpeg") || contentType.contains("jpg") {
            return BeetCodeScreenFrame(payload: .jpeg(body), geometry: geometry)
        }
        guard contentType.contains("video/avc") || contentType.contains("application/octet-stream") else {
            return nil
        }
        let keyframe = ["1", "true", "yes"].contains((headers["x-beet-keyframe"] ?? "0").lowercased())
        let paramsLength = Int(headers["x-beet-params-length"] ?? "0") ?? 0
        let parameterSets: Data?
        let avcc: Data
        if paramsLength > 0 {
            guard paramsLength < body.count else {
                throw BeetCodeRemoteError.invalidResponseReason("invalid H.264 parameter-set length")
            }
            parameterSets = Data(body.prefix(paramsLength))
            avcc = Data(body.dropFirst(paramsLength))
        } else if let encoded = headers["x-beet-parameter-sets"],
                  let decoded = Data(base64Encoded: encoded), !decoded.isEmpty {
            parameterSets = decoded
            avcc = body
        } else {
            parameterSets = nil
            avcc = body
        }
        guard !avcc.isEmpty else { return nil }
        return BeetCodeScreenFrame(payload: .h264(data: avcc, keyframe: keyframe, parameterSets: parameterSets), geometry: geometry)
    }

    private static func boundary(from contentType: String) -> String? {
        for part in contentType.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("boundary=") {
                return String(trimmed.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    private static func headerMap(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String { headers[key.lowercased()] = "\(value)" }
        }
        return headers
    }

    private static func headerMap(from text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return headers
    }
}

// MARK: - Secure token persistence

enum BeetCodeTokenStore {
    private static let service = "com.mesutcy.remotedesktop.stream.beetcode"

    static func save(_ token: String, for url: URL) throws {
        #if canImport(Security)
        let query = query(for: url)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw BeetCodeRemoteError.server("The Vamp Assistant token could not be saved securely.")
        }
        #else
        _ = token
        _ = url
        #endif
    }

    static func load(for url: URL) -> String? {
        #if canImport(Security)
        var item = query(for: url)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    static func clear(for url: URL) {
        #if canImport(Security)
        SecItemDelete(query(for: url) as CFDictionary)
        #else
        _ = url
        #endif
    }

    #if canImport(Security)
    private static func query(for url: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: url.absoluteString,
        ]
    }
    #endif
}

// MARK: - H.264/JPEG presentation bridge

@MainActor
final class BeetCodeVideoRendererViewModel: ObservableObject {
    @Published private(set) var latestPixelBuffer: CVPixelBuffer?
    @Published private(set) var geometry: BeetCodeDisplayGeometry?
    @Published private(set) var isReceiving = false
    @Published private(set) var lastError: String?
    /// Rolling decoded frame rate, recomputed about once a second. Nil until the
    /// first full window has elapsed, so a session-stats readout can show "—"
    /// rather than a misleading number from a partial sample.
    @Published private(set) var framesPerSecond: Double?

    private let decoder = VideoFrameDecoder()
    private var streamTask: Task<Void, Never>?
    private var sequence: UInt64 = 0
    private var acceptingFrames = false
    private var frameRateWindowStart: TimeInterval?
    private var frameRateWindowCount = 0

    private var receiveGeneration: UInt64 = 0

    /// A one-second counting window, not a smoothed estimator. Good
    /// enough to tell a healthy stream from a stalled one, which is all the
    /// readout claims.
    private(set) var lastDecodedAt: TimeInterval?

    private func noteDecodedFrame() {
        lastDecodedAt = ProcessInfo.processInfo.systemUptime
        let now = ProcessInfo.processInfo.systemUptime
        guard let start = frameRateWindowStart else {
            frameRateWindowStart = now
            frameRateWindowCount = 1
            return
        }
        frameRateWindowCount += 1
        let elapsed = now - start
        guard elapsed >= 1 else { return }
        framesPerSecond = Double(frameRateWindowCount) / elapsed
        frameRateWindowStart = now
        frameRateWindowCount = 0
    }

    private func installFrameHandler() {
        receiveGeneration &+= 1
        let generation = receiveGeneration
        decoder.onDecodedFrame = { [weak self] pixelBuffer, _ in
            Task { @MainActor [weak self] in
                guard let self, self.acceptingFrames, self.receiveGeneration == generation else { return }
                self.latestPixelBuffer = pixelBuffer
                self.noteDecodedFrame()
            }
        }
    }

    func start(
        client: BeetCodeRemoteClient,
        resolution: String = "1080p",
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        showsCursor: Bool = true
    ) {
        stop()
        lastError = nil
        installFrameHandler()
        acceptingFrames = true
        streamTask = Task { [weak self] in
            guard let self else { return }
            var retry = 0
            while !Task.isCancelled {
                var receivedFrame = false
                do {
                    let stream = client.screenStream(
                        resolution: resolution,
                        displayID: displayID,
                        windowID: windowID,
                        showsCursor: showsCursor)
                    for try await frame in stream {
                        guard !Task.isCancelled else { return }
                        receivedFrame = true
                        retry = 0
                        self.lastError = nil
                        if let previous = self.geometry,
                           previous.imageWidth != frame.geometry.imageWidth || previous.imageHeight != frame.geometry.imageHeight
                            || previous.displayWidth != frame.geometry.displayWidth || previous.displayHeight != frame.geometry.displayHeight {
                            self.latestPixelBuffer = nil
                            self.lastDecodedAt = nil
                            self.decoder.stopDecoding()
                            self.installFrameHandler()
                        }
                        self.geometry = frame.geometry
                        self.isReceiving = true
                        switch frame.payload {
                        case let .h264(data, keyframe, parameterSets):
                            self.sequence &+= 1
                            self.decoder.decodeAsync(VideoFrameData(
                                codec: .h264,
                                data: data,
                                isKeyframe: keyframe,
                                presentationTimestamp: ProcessInfo.processInfo.systemUptime,
                                width: frame.geometry.imageWidth,
                                height: frame.geometry.imageHeight,
                                sequenceNumber: self.sequence,
                                parameterSets: parameterSets))
                        case let .jpeg(data):
                            if let pixelBuffer = Self.pixelBuffer(from: data) {
                                self.latestPixelBuffer = pixelBuffer
                                self.noteDecodedFrame()
                            }
                        }
                    }
                    guard !Task.isCancelled else { return }
                    throw BeetCodeRemoteError.controlUnavailable("Vamp Assistant ended the stream.")
                } catch is CancellationError {
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch {
                    self.isReceiving = false
                    self.latestPixelBuffer = nil
                    self.lastDecodedAt = nil
                    self.framesPerSecond = nil
                    self.frameRateWindowStart = nil
                    self.frameRateWindowCount = 0
                    self.lastError = receivedFrame
                        ? "Connection interrupted. Reconnecting…"
                        : "Waiting for Vamp Assistant… \(error.localizedDescription)"
                    self.decoder.stopDecoding()
                    self.installFrameHandler()
                    retry = min(retry + 1, 5)
                    let delay = UInt64(min(pow(2.0, Double(retry - 1)), 8) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
    }

    func stop() {
        acceptingFrames = false
        lastDecodedAt = nil
        streamTask?.cancel()
        streamTask = nil
        decoder.stopDecoding()
        latestPixelBuffer = nil
        geometry = nil
        isReceiving = false
        framesPerSecond = nil
        frameRateWindowStart = nil
        frameRateWindowCount = 0
    }

    private static func pixelBuffer(from data: Data) -> CVPixelBuffer? {
        guard let image = CIImage(data: data), image.extent.width > 0, image.extent.height > 0 else { return nil }
        let width = Int(image.extent.width.rounded())
        let height = Int(image.extent.height.rounded())
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer) == kCVReturnSuccess,
            let pixelBuffer else { return nil }
        CIContext().render(image, to: pixelBuffer)
        return pixelBuffer
    }
}
