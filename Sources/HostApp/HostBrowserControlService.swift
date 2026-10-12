#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import Network
import Security
import SharedProtocol
import TransportWebRTC
import os

/// The web control plane is private to this Mac and its Tailscale interface.
/// When Tailscale is available the listener accepts loopback (for `tailscale
/// serve`) and tailnet traffic, while rejecting ordinary LAN paths. Without
/// Tailscale it remains loopback-only.
struct HostBrowserControlStatus: Equatable, Sendable {
    let running: Bool
    let port: UInt16?
    let tailscaleHost: String?
    let pairingCode: String
    let pairingCodeExpiresAt: Date
    let lastError: String?

    var serveCommand: String? {
        guard let port else { return nil }
        return "tailscale serve --bg http://127.0.0.1:\(port)"
    }
}

/// Turns a Safari-control bind failure into an actionable host-dashboard line.
enum HostBrowserControlBindError {
    static func isAddressInUse(_ error: Error) -> Bool {
        if let nwError = error as? NWError, case .posix(let code) = nwError {
            return code == .EADDRINUSE
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EADDRINUSE) {
            return true
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("Address already in use")
    }

    static func message(port: UInt16, error: Error, occupantName: String? = nil) -> String {
        guard isAddressInUse(error) else { return error.localizedDescription }
        let occupant = occupantName ?? listeningProcessName(on: port)
        if let occupant, !occupant.isEmpty {
            if occupant.localizedCaseInsensitiveContains("Vamp Terminal Host") {
                return "Port \(port) is already in use by Vamp Terminal Host. Quit that host, then tap Retry. Only one Mac host can run at a time."
            }
            if occupant.localizedCaseInsensitiveContains("Vamp Host") {
                return "Port \(port) is already in use by another Vamp Host. Quit the extra host, then tap Retry."
            }
            return "Port \(port) is already in use by \(occupant). Quit that app, then tap Retry so Safari control can start."
        }
        return "Port \(port) is already in use. Quit the other app using that port, then tap Retry."
    }

    static func parseLsofFieldOutput(_ text: String, excludingPID: pid_t) -> String? {
        var pid: pid_t?
        var name: String?
        var found: String?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let first = line.first else { continue }
            let value = String(line.dropFirst())
            switch first {
            case "p":
                if let currentPID = pid, currentPID != excludingPID, let name, !name.isEmpty {
                    found = name
                }
                pid = pid_t(value)
                name = nil
            case "c":
                name = value
            default:
                break
            }
        }
        if let currentPID = pid, currentPID != excludingPID, let name, !name.isEmpty {
            found = name
        }
        return found
    }

    static func listeningProcessName(on port: UInt16, excludingPID: pid_t = getpid()) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-Fpc", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseLsofFieldOutput(text, excludingPID: excludingPID)
    }
}

/// Normalizes the 12-digit code shown by the host. Pairing codes can be
/// pasted with spaces or hyphens, and whole-number digits from another locale
/// should behave the same as ASCII digits.
enum HostBrowserPairingCode {
    static let length = 12

    static func normalize(_ raw: String) -> String? {
        var digits = ""
        digits.reserveCapacity(length)

        for character in raw {
            let isFormatMark = character.unicodeScalars.allSatisfy {
                $0.properties.generalCategory == .format
            }
            if character.isWhitespace || character == "-" || character == "·" || isFormatMark {
                continue
            }
            guard let value = character.wholeNumberValue, (0...9).contains(value) else {
                return nil
            }
            digits.append(String(value))
        }

        return digits.count == length ? digits : nil
    }

    static func generate() -> String {
        // Draw from the CSPRNG explicitly rather than `Int.random(in:)` so the
        // pairing code's entropy source is auditable and guaranteed not to fall
        // back to a non-cryptographic generator on any platform. 12 decimal
        // digits are ~39.8 bits. Rejection sampling keeps the draw uniform:
        // 2^32 is not enough, so we draw 8 bytes and reduce modulo 10^12
        // only after discarding values above the largest multiple of 10^12
        // that fits in UInt64.
        let modulus: UInt64 = 1_000_000_000_000
        let unbiasedLimit = (UInt64.max / modulus) * modulus
        var value: UInt64 = 0
        repeat {
            let drawn = withUnsafeMutableBytes(of: &value) { buffer -> Bool in
                guard let base = buffer.baseAddress else { return false }
                return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base) == errSecSuccess
            }
            guard drawn else {
                var fallback = [UInt8](repeating: 0, count: 8)
                _ = SecRandomCopyBytes(kSecRandomDefault, fallback.count, &fallback)
                let reduced = fallback.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % modulus
                return String(format: "%012llu", reduced)
            }
        } while value >= unbiasedLimit
        return String(format: "%012llu", value % modulus)
    }

    static func isExpired(
        issuedAt: Date,
        at now: Date = Date(),
        lifetime: TimeInterval
    ) -> Bool {
        now.timeIntervalSince(issuedAt) >= lifetime
    }
}

/// Builds the private URL encoded in the host QR card. The pairing code is
/// never placed in the URL: the operator types it on a trusted screen, and
/// POST /api/pair exchanges it for a short-lived bearer token.
enum HostBrowserPairingLink {
    static func make(baseURL: String) -> String? {
        guard var components = URLComponents(string: baseURL),
              let scheme = components.scheme, !scheme.isEmpty,
              let host = components.host, !host.isEmpty else {
            return nil
        }

        if var queryItems = components.queryItems {
            queryItems.removeAll { $0.name == "pair" }
            components.queryItems = queryItems.isEmpty ? nil : queryItems
        }
        return components.url?.absoluteString
    }
}

/// A small, dependency-free browser gateway for terminal-only control.
///
/// The browser protocol is intentionally separate from the WebRTC media
/// session: Safari gets a focused task-chat terminal, not screen capture or
/// remote input. Each browser connection owns one bounded HostTerminalService
/// and therefore keeps up to eight shell tabs independent from one another.
final class HostBrowserControlService: @unchecked Sendable {
    static let defaultPort: UInt16 = 9475
    static let maxBrowserClients = 1
    static let pairingCodeLifetime: TimeInterval = 10 * 60
    static let browserTokenLifetime: TimeInterval = 30 * 60
    /// Wrong-code guesses a single remote IP may make within one window before
    /// being throttled. Per-IP (not global) so an attacker cannot lock out the
    /// legitimate user by burning a shared budget.
    static let maxPairFailuresPerWindow = 8
    static let pairFailureWindowSeconds: TimeInterval = 60
    /// Subprotocol name used to carry the bearer token during the WebSocket
    /// handshake, keeping the token out of the URL (which leaks to history,
    /// referrer headers, and logs). The client sends this name followed by the
    /// token; the server validates the token and echoes only the name back.
    static let webSocketAuthProtocol = "vamp-auth"
    static let maxHTTPBodyBytes = 4 * 1024
    static let maxWebSocketFrameBytes = 64 * 1024

    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "BrowserControl")
    private let queue = DispatchQueue(label: "com.remotedesktop.host.browser-control", qos: .userInitiated)
    private var listener: NWListener?
    private var listenerReady = false
    private var lastError: String?
    private var bindAttempt = 0
    private var tailscaleListenerHost: String?
    private var clients: [UUID: BrowserClient] = [:]
    private var pairingCode = HostBrowserPairingCode.generate()
    private var pairingCodeIssuedAt = Date()
    /// Keeps the code shown in the host UI from becoming a permanently stale
    /// value after the ten-minute window. The work item runs on `queue`, the
    /// same serial queue that owns all pairing state.
    private var pairingCodeExpiryWorkItem: DispatchWorkItem?
    private var browserToken: String?
    private var browserTokenExpiresAt: Date?
    private struct PairFailureWindow {
        var count: Int
        var firstAt: Date
    }
    /// Pairing failures keyed by remote IP. Throttling per address (instead of
    /// globally) stops an attacker's guesses from consuming the legitimate
    /// user's attempt budget and locking them out.
    private var pairFailuresByAddress: [String: PairFailureWindow] = [:]

    /// These providers are installed by HostAppEnvironment after all of its
    /// dependencies have been initialized.
    var terminalModeProvider: () -> Bool = { false }
    var readClipboard: () -> String? = { nil }
    var writeClipboard: (String) -> Void = { _ in }
    var onStatusChange: (@Sendable (HostBrowserControlStatus) -> Void)?
    var workspaceService: HostWorkspaceService?
    /// Opens the trusted native Mac folder chooser. Browser JavaScript can
    /// request this action, but it can never choose or submit a host path.
    var requestWorkspaceAccess: ((@escaping @Sendable (Bool) -> Void) -> Void)?

    deinit {
        stop()
    }

    func start(port: UInt16 = HostBrowserControlService.defaultPort, tailscaleHost: String? = nil) {
        queue.async { [weak self] in
            // Resolve again on the service queue. The host environment may
            // start the browser service while the Tailscale daemon is still
            // waking up, and the direct tailnet endpoint should not depend on
            // a single early probe.
            let resolvedTailscaleHost = tailscaleHost ?? getTailscaleConnectionInfo()?.ipAddress
            self?.bindAttempt = 0
            self?._start(port: port, tailscaleHost: resolvedTailscaleHost)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?._stop()
        }
    }

    @discardableResult
    func rotatePairingCode() -> HostBrowserControlStatus {
        queue.sync {
            issuePairingCode()
            revokeBrowserSessions(reason: "pairing-code-rotated")
            publishStatus()
            return currentStatusOnQueue()
        }
    }

    func currentStatus() -> HostBrowserControlStatus {
        queue.sync {
            if refreshExpiredPairingCodeIfNeeded() {
                publishStatus()
            }
            return currentStatusOnQueue()
        }
    }

    // MARK: Listener lifecycle

    private static let maxBindAttempts = 4

    private func _start(port: UInt16, tailscaleHost: String?) {
        let hasTailscaleHost = tailscaleHost.map { !$0.isEmpty } ?? false

        // Network.framework reserves a TCP port process-wide when a listener
        // is bound to loopback, so a second listener on the same port cannot
        // be added for the 100.x Tailscale address. Bind once to all local
        // interfaces when Tailscale is available; keep loopback-only mode
        // when no tailnet address is detected.
        if listener != nil,
           hasTailscaleHost,
           tailscaleListenerHost == nil {
            listener?.cancel()
            listener = nil
            listenerReady = false
        } else if listener != nil, listenerReady {
            publishStatus()
            return
        } else if listener != nil {
            listener?.cancel()
            listener = nil
            listenerReady = false
        }

        lastError = nil
        let bindHost = hasTailscaleHost ? NWEndpoint.Host("0.0.0.0") : .ipv4(.loopback)
        let label = hasTailscaleHost ? "loopback + Tailscale" : "loopback"
        do {
            let newListener = try makeListener(port: port, host: bindHost, label: label, tailscaleHost: tailscaleHost) { [weak self] stoppedListener in
                // A loopback listener can be replaced by the all-interface
                // listener once Tailscale wakes up. Its cancellation callback
                // may arrive after the replacement is installed, so it must
                // never clear a newer listener.
                guard let self, self.listener === stoppedListener else { return }
                self.listenerReady = false
                self.listener = nil
                self.tailscaleListenerHost = nil
            }
            listener = newListener
            listenerReady = false
            tailscaleListenerHost = hasTailscaleHost ? tailscaleHost : nil
            newListener.start(queue: queue)
            publishStatus()
        } catch {
            handleBindFailure(port: port, tailscaleHost: tailscaleHost, error: error)
        }
    }

    private func handleBindFailure(port: UInt16, tailscaleHost: String?, error: Error) {
        logger.error("Browser control listener failed: \(error.localizedDescription, privacy: .public)")
        guard listener == nil else { return }
        listenerReady = false
        tailscaleListenerHost = nil
        if HostBrowserControlBindError.isAddressInUse(error), bindAttempt + 1 < Self.maxBindAttempts {
            bindAttempt += 1
            let delay = pow(2.0, Double(bindAttempt - 1)) * 0.15
            logger.warning("Port \(port) is still busy; retrying Safari control bind (\(self.bindAttempt)/\(Self.maxBindAttempts - 1))")
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?._start(port: port, tailscaleHost: tailscaleHost)
            }
            return
        }
        publishStatus(error: HostBrowserControlBindError.message(port: port, error: error))
    }

    private func makeListener(
        port: UInt16,
        host: NWEndpoint.Host,
        label: String,
        tailscaleHost: String?,
        onStopped: @escaping @Sendable (NWListener) -> Void
    ) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: host,
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        let newListener = try NWListener(using: parameters)
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.info("Browser control \(label, privacy: .public) listener ready on port \(newListener?.port?.rawValue ?? 0)")
                self.bindAttempt = 0
                if let newListener, self.listener === newListener {
                    self.listenerReady = true
                    self.lastError = nil
                    // Issue the code only after the active listener is ready.
                    // A code shown while a replacement socket is still
                    // binding can otherwise look valid but hit the old host.
                    self.issuePairingCode()
                }
                self.publishStatus()
            case .failed(let error):
                let isCurrent = newListener.map { self.listener === $0 } ?? false
                if let newListener { onStopped(newListener) }
                guard isCurrent else { return }
                self.handleBindFailure(port: port, tailscaleHost: tailscaleHost, error: error)
            case .cancelled:
                if let newListener { onStopped(newListener) }
                self.publishStatus()
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return newListener
    }

    private func _stop() {
        pairingCodeExpiryWorkItem?.cancel()
        pairingCodeExpiryWorkItem = nil
        lastError = nil
        bindAttempt = 0
        listener?.cancel()
        listener = nil
        listenerReady = false
        tailscaleListenerHost = nil
        revokeBrowserSessions(reason: "browser-server-stopped")
        browserToken = nil
        browserTokenExpiresAt = nil
        publishStatus()
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let client = BrowserClient(id: id, connection: connection)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard self.allowsBrowserPath(
                    connection?.currentPath,
                    remoteEndpoint: connection?.endpoint
                ) else {
                    self.logger.warning("Rejecting browser connection outside loopback or Tailscale")
                    self.remove(clientID: id, connection: connection)
                    return
                }
                self.receive(on: client)
            case .failed, .cancelled:
                self.remove(clientID: id, connection: connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func allowsBrowserPath(_ path: NWPath?, remoteEndpoint: NWEndpoint?) -> Bool {
        guard tailscaleListenerHost != nil else { return true }
        guard let path else { return false }
        if path.usesInterfaceType(.loopback) { return true }
        // Never accept the LAN or cellular NIC even if a peer spoofs a CGNAT
        // source. Tailscale arrives as `.other` (utun).
        if path.usesInterfaceType(.wifi)
            || path.usesInterfaceType(.wiredEthernet)
            || path.usesInterfaceType(.cellular) {
            return false
        }
        // Network.framework labels Tailscale's utun as `.other`, but `.other`
        // also covers unrelated tunnels. Require the peer address itself to
        // be in Tailscale's documented CGNAT IPv4 block or ULA IPv6 prefix.
        guard path.usesInterfaceType(.other),
              case let .hostPort(host, _) = remoteEndpoint else { return false }
        return Self.isTailscaleAddress(host)
    }

    static func isTailscaleAddress(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 4 else { return false }
            // 100.64.0.0/10
            return bytes[0] == 100 && (64...127).contains(bytes[1])
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            // fd7a:115c:a1e0::/48
            return Array(bytes.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        case .name(let name, _):
            // Connections accepted by a listener normally expose a numeric
            // endpoint. Keep names closed instead of trusting suffix text.
            return IPv4Address(name).map { isTailscaleAddress(.ipv4($0)) }
                ?? IPv6Address(name).map { isTailscaleAddress(.ipv6($0)) }
                ?? false
        @unknown default:
            return false
        }
    }

    private func remove(clientID: UUID, connection: NWConnection?) {
        guard let client = clients.removeValue(forKey: clientID) else { return }
        client.terminalService?.sessionDidEnd(reason: "browser-disconnected")
        client.agentSemanticService?.sessionDidEnd()
        if connection == nil || connection === client.connection {
            client.connection.cancel()
        }
    }

    // MARK: HTTP

    private func receive(on client: BrowserClient) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxWebSocketFrameBytes) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }
            if let error {
                self.logger.debug("Browser connection read ended: \(error.localizedDescription, privacy: .public)")
                self.remove(clientID: client.id, connection: client.connection)
                return
            }
            if let data, !data.isEmpty {
                client.receiveBuffer.append(data)
                if client.mode == .http {
                    self.handleHTTPBuffer(for: client)
                } else {
                    self.handleWebSocketBuffer(for: client)
                }
            }
            if isComplete {
                self.remove(clientID: client.id, connection: client.connection)
            } else if self.clients[client.id] != nil {
                // Re-arm on the next turn of the service queue. Re-entering
                // NWConnection.receive from inside its completion can leave a
                // manually upgraded TCP stream with no second read request;
                // that is especially visible when Safari/Chrome sends its
                // first WebSocket command after the 101 response.
                self.queue.async { [weak self, weak client] in
                    guard let self, let client, self.clients[client.id] != nil else { return }
                    self.receive(on: client)
                }
            }
        }
    }

    private func handleHTTPBuffer(for client: BrowserClient) {
        guard let headerEnd = client.receiveBuffer.range(of: Data("\r\n\r\n".utf8)) else {
            if client.receiveBuffer.count > 16 * 1024 {
                remove(clientID: client.id, connection: client.connection)
            }
            return
        }

        let headerData = client.receiveBuffer.subdata(in: 0..<headerEnd.lowerBound)
        let headerText = String(decoding: headerData, as: UTF8.self)
        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first,
              let request = Self.parseRequestLine(requestLine) else {
            sendHTTP(.badRequest, body: "Bad request", to: client)
            return
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength: Int
        if let rawContentLength = headers["content-length"] {
            guard let parsedContentLength = Int(rawContentLength),
                  parsedContentLength >= 0,
                  parsedContentLength <= Self.maxHTTPBodyBytes else {
                sendHTTP(.badRequest, body: "Invalid request body", to: client)
                return
            }
            contentLength = parsedContentLength
        } else {
            contentLength = 0
        }
        let bodyStart = headerEnd.upperBound
        guard client.receiveBuffer.count >= bodyStart + contentLength else { return }
        let body = client.receiveBuffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        client.receiveBuffer.removeSubrange(0..<(bodyStart + contentLength))

        if request.path == "/socket",
           request.method == "GET",
           headers["upgrade"]?.lowercased() == "websocket",
           let websocketKey = headers["sec-websocket-key"] {
            upgradeToWebSocket(client, request: request, headers: headers, key: websocketKey)
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            sendHTTP(.ok, contentType: "text/html; charset=utf-8", body: BrowserControlWebAssets.indexHTML, to: client)
        case ("GET", "/api/status"):
            sendHTTP(.ok, contentType: "application/json", body: statusJSON(), to: client)
        case ("GET", let path) where path.hasPrefix("/assets/providers/"):
            sendProviderAsset(path: path, to: client)
        case ("POST", "/api/pair"):
            // Pairing creates a bearer credential. A hostile web page must not
            // be able to submit the visible 12-digit code through the user's
            // browser, so apply the same-origin rule used by the WebSocket
            // upgrade. Native/non-browser clients may omit Origin.
            guard Self.isAllowedBrowserOrigin(
                headers["origin"],
                hostHeader: headers["host"]
            ) else {
                logger.warning("Rejected browser pairing request with mismatched Origin")
                sendHTTP(.forbidden, body: "Origin not allowed", to: client)
                return
            }
            // Keep the QR handoff available even when a browser or proxy
            // drops the JSON body. The URL code is still validated against
            // the same one-time pairing secret below; this is not a second
            // authentication path.
            handlePair(body: body, client: client)
        default:
            sendHTTP(.notFound, body: "Not found", to: client)
        }
    }

    private func sendProviderAsset(path: String, to client: BrowserClient) {
        let name = String(path.dropFirst("/assets/providers/".count))
        let allowed: [String: String] = [
            "opencode.png": "image/png",
            "claude.jpg": "image/jpeg",
            "grok.jpg": "image/jpeg",
            "openai.jpg": "image/jpeg",
            "kimi.jpg": "image/jpeg",
        ]
        guard let contentType = allowed[name],
              let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("BrowserProviders/").appendingPathComponent(name),
              let data = try? Data(contentsOf: resourceURL) else {
            sendHTTP(.notFound, body: "Not found", to: client)
            return
        }
        sendHTTP(.ok, contentType: contentType, data: data, to: client)
    }

    private func handlePair(body: Data, client: BrowserClient) {
        // The expiry work item normally rotates the code exactly at the
        // deadline. Refresh synchronously as well so a delayed serial-queue
        // callback can never leave the listener accepting stale state or
        // reporting an expired code as if it were still current.
        if refreshExpiredPairingCodeIfNeeded() {
            publishStatus()
        }
        guard terminalModeProvider() else {
            sendHTTP(.forbidden, contentType: "application/json", body: "{\"error\":\"terminal-disabled\"}", to: client)
            return
        }
        let remoteAddress = remoteAddress(of: client)
        guard canAttemptPairing(address: remoteAddress) else {
            sendHTTP(.tooManyRequests, body: "Too many pairing attempts", to: client)
            return
        }
        let payload = try? JSONDecoder().decode(BrowserPairRequest.self, from: body)
        let submittedCode = payload?.code.flatMap(HostBrowserPairingCode.normalize)
        guard let submittedCode,
              Self.constantTimeEqual(submittedCode, pairingCode),
              !HostBrowserPairingCode.isExpired(
                  issuedAt: pairingCodeIssuedAt,
                  lifetime: Self.pairingCodeLifetime
              ) else {
            logger.warning("Browser pairing rejected: invalid or expired code")
            recordPairFailure(address: remoteAddress)
            sendHTTP(.unauthorized, contentType: "application/json", body: "{\"error\":\"invalid-code\"}", to: client)
            return
        }

        // Pairing is an explicit handoff. If this browser, another tab, or a
        // phone already owns the single browser slot, retire that old socket
        // before issuing the new token. Previously the code was accepted and
        // returned 200, but the follow-up WebSocket then hit the capacity
        // guard and immediately closed, making QR/manual pairing appear to
        // have failed.
        revokeWebSocketSessions(reason: "browser-replaced")
        pairFailuresByAddress.removeValue(forKey: remoteAddress)
        let token = Self.makeToken()
        browserToken = token
        browserTokenExpiresAt = Date().addingTimeInterval(Self.browserTokenLifetime)
        logger.info("Browser pairing accepted; issuing a fresh browser token")
        let response = BrowserPairResponse(token: token, expiresAt: browserTokenExpiresAt ?? Date())
        sendHTTP(.ok, contentType: "application/json", body: Self.jsonString(response), to: client)
    }

    private func canAttemptPairing(address: String) -> Bool {
        pruneExpiredPairFailures()
        guard let window = pairFailuresByAddress[address] else { return true }
        return window.count < Self.maxPairFailuresPerWindow
    }

    private func recordPairFailure(address: String) {
        pruneExpiredPairFailures()
        let now = Date()
        var window = pairFailuresByAddress[address] ?? PairFailureWindow(count: 0, firstAt: now)
        window.count += 1
        pairFailuresByAddress[address] = window

        // Once a single address exhausts its guess budget, rotate the code so
        // any partial progress from the brute-force attempt is invalidated.
        // This is deliberately aggressive: a full budget of wrong guesses from
        // one IP is an attack, not a typo.
        if window.count >= Self.maxPairFailuresPerWindow {
            logger.warning("Pairing guess budget exhausted from \(address); rotating pairing code")
            issuePairingCode()
            publishStatus()
        }
    }

    private func pruneExpiredPairFailures() {
        let now = Date()
        pairFailuresByAddress = pairFailuresByAddress.filter {
            now.timeIntervalSince($0.value.firstAt) < Self.pairFailureWindowSeconds
        }
    }

    private func remoteAddress(of client: BrowserClient) -> String {
        switch client.connection.endpoint {
        case .hostPort(let host, _):
            return "\(host)"
        default:
            return "unknown"
        }
    }

    private func statusJSON() -> String {
        if refreshExpiredPairingCodeIfNeeded() {
            publishStatus()
        }
        let status = currentStatusOnQueue()
        let response = BrowserStatusResponse(
            terminalModeEnabled: terminalModeProvider(),
            maxTerminals: HostTerminalService.maxActiveTerminals,
            running: status.running,
            tailscaleHost: status.tailscaleHost,
            pairingCodeExpiresAt: status.pairingCodeExpiresAt
        )
        return Self.jsonString(response)
    }

    private func upgradeToWebSocket(
        _ client: BrowserClient,
        request: BrowserHTTPRequest,
        headers: [String: String],
        key: String
    ) {
        // A browser WebSocket is authenticated with a bearer token, so a
        // cross-origin page must never be able to spend that token through the
        // user's browser. Non-browser WebSocket clients commonly omit Origin;
        // when it is present it must match this HTTP endpoint exactly.
        guard Self.isAllowedBrowserOrigin(
            headers["origin"],
            hostHeader: headers["host"]
        ) else {
            logger.warning("Rejected browser WebSocket with mismatched Origin")
            sendHTTP(.forbidden, body: "Origin not allowed", to: client)
            return
        }
        // The bearer token travels in the Sec-WebSocket-Protocol handshake
        // header instead of a `?token=` URL query: URLs leak into browser
        // history, referrer headers, and any intermediary logs, while
        // handshake headers do not. The client offers the fixed protocol name
        // followed by the token; we validate the token and echo the protocol
        // name back in the 101 response.
        let subprotocols = (headers["sec-websocket-protocol"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard subprotocols.first == Self.webSocketAuthProtocol,
              let token = subprotocols.dropFirst().first,
              let storedToken = browserToken,
              let expiresAt = browserTokenExpiresAt,
              Date() < expiresAt,
              Self.constantTimeEqual(token, storedToken) else {
            sendHTTP(.unauthorized, body: "Pair this browser first", to: client)
            return
        }
        guard terminalModeProvider() else {
            sendHTTP(.forbidden, contentType: "application/json", body: "{\"error\":\"terminal-disabled\"}", to: client)
            return
        }
        if clients.values.contains(where: { $0.mode == .webSocket }) {
            // Pairing is an explicit handoff. A tab can finish the HTTP
            // exchange and open its socket after an old tab is still present;
            // replacing the old socket here closes that race as well as the
            // earlier POST-side handoff.
            revokeWebSocketSessions(reason: "browser-replaced")
        }

        let accept = Self.websocketAcceptValue(key: key)
        // Echo the negotiated subprotocol back so the browser completes the
        // handshake; the token itself is never echoed.
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n"
            + "Sec-WebSocket-Protocol: \(Self.webSocketAuthProtocol)\r\n\r\n"

        // Switch the client into WebSocket mode before writing the 101
        // response. Chrome can send the first terminal-open frame as soon as
        // it observes the handshake, while NWConnection may still deliver
        // that frame through the receive callback that started in HTTP mode.
        // Deferring this state change until the send completion races the
        // browser and leaves tabs stuck at "Opening shell…" with no PTY.
        client.mode = .webSocket
        client.sessionID = UUID()
        let terminalService = HostTerminalService(workspaceService: workspaceService)
        terminalService.sendEnvelope = { [weak self, weak client] envelope in
            guard let self, let client else { return }
            self.queue.async {
                self.sendTerminalEnvelope(envelope, to: client)
            }
        }
        client.terminalService = terminalService
        let agentSemanticService = HostAgentSemanticService(workspaceService: workspaceService)
        agentSemanticService.sendEnvelope = { [weak self, weak client] envelope in
            guard let self, let client else { return }
            self.queue.async { self.sendTerminalEnvelope(envelope, to: client) }
        }
        client.agentSemanticService = agentSemanticService

        var browserCapabilities = [
            "terminal",
            "multiple-terminals",
            "clipboard",
            "approval-cards",
            "chat",
            "task-plans",
            "tmux",
            "screen"
        ]
        if workspaceService != nil {
            browserCapabilities.append("workspaces")
        }
        let hello = BrowserHelloEvent(
            sessionID: client.sessionID ?? UUID(),
            maxTerminals: HostTerminalService.maxActiveTerminals,
            features: BrowserFeatureCapabilities(chat: true, taskPlans: true, workspaces: workspaceService != nil),
            capabilities: browserCapabilities
        )
        sendRaw(Data(response.utf8), to: client) { [weak self, weak client] in
            guard let self, let client, self.clients[client.id] != nil else { return }
            self.sendJSON(hello, to: client)
            if let workspaceService = self.workspaceService {
                self.sendJSON(
                    BrowserWorkspaceEvent(
                        workspaces: [],
                        roots: workspaceService.availableBrowseRoots(),
                        error: nil
                    ),
                    to: client
                )
            }
            self.workspaceService?.listWorkspaces(refresh: false) { [weak self, weak client] workspaces, roots, error in
                guard let self, let client else { return }
                self.queue.async {
                    self.sendJSON(BrowserWorkspaceEvent(workspaces: workspaces, roots: roots, error: error), to: client)
                }
            }
        }

        // A client is allowed to pipeline its first frame with the upgrade
        // request. Process anything already buffered now that the protocol
        // mode has changed; otherwise it would sit until another frame arrives.
        if !client.receiveBuffer.isEmpty {
            handleWebSocketBuffer(for: client)
        }
    }

    static func isAllowedBrowserOrigin(_ origin: String?, hostHeader: String?) -> Bool {
        guard let origin, !origin.isEmpty else { return true }
        guard origin != "null",
              let hostHeader,
              let components = URLComponents(string: origin),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else { return false }

        let originPort = components.port ?? (scheme == "https" ? 443 : 80)
        let expected = hostHeader.lowercased()
        let originAuthority = originPort == (scheme == "https" ? 443 : 80)
            ? host
            : "\(host):\(originPort)"
        return originAuthority == expected
    }

    @available(*, deprecated, renamed: "isAllowedBrowserOrigin(_:hostHeader:)")
    static func isAllowedWebSocketOrigin(_ origin: String?, hostHeader: String?) -> Bool {
        isAllowedBrowserOrigin(origin, hostHeader: hostHeader)
    }

    // MARK: WebSocket terminal protocol

    private func handleWebSocketBuffer(for client: BrowserClient) {
        while let frame = Self.decodeFrame(from: &client.receiveBuffer) {
            switch frame.opcode {
            case 0x8: // close
                sendWebSocketFrame(Data(), opcode: 0x8, to: client)
                remove(clientID: client.id, connection: client.connection)
                return
            case 0x9: // ping
                sendWebSocketFrame(frame.payload, opcode: 0xA, to: client)
            case 0x1: // text
                handleWebSocketCommand(frame.payload, client: client)
            default:
                sendError("unsupported-frame", to: client)
            }
        }
    }

    private func handleWebSocketCommand(_ data: Data, client: BrowserClient) {
        guard data.count <= Self.maxWebSocketFrameBytes,
              let command = try? JSONDecoder().decode(BrowserTerminalCommand.self, from: data),
              let type = command.type?.lowercased(),
              let sessionID = client.sessionID,
              let terminalService = client.terminalService else {
            sendError("invalid-command", to: client)
            return
        }
        guard terminalModeProvider() else {
            sendError("terminal-disabled", terminalID: command.terminalID, to: client)
            return
        }

        switch type {
        case "open":
            guard let terminalID = command.terminalID,
                  let cols = command.cols, let rows = command.rows,
                  cols > 0, rows > 0, cols <= 1000, rows <= 1000 else {
                sendError("invalid-terminal-size", terminalID: command.terminalID, to: client)
                return
            }
            if let startupCommand = command.startupCommand, startupCommand.utf8.count > TerminalOpenMessage.maxStartupCommandLength {
                sendError("startup-command-too-large", terminalID: command.terminalID, to: client)
                return
            }
            terminalService.handleOpen(TerminalOpenMessage(
                sessionID: sessionID,
                terminalID: terminalID,
                cols: cols,
                rows: rows,
                term: command.term ?? "xterm-256color",
                startupCommand: command.startupCommand,
                workspaceID: command.workspaceID,
                workingDirectory: command.workingDirectory
            ))
        case "input":
            guard let terminalID = command.terminalID,
                  let encoded = command.data,
                  let input = Data(base64Encoded: encoded),
                  !input.isEmpty,
                  input.count <= TerminalInputMessage.maxChunkBytes else {
                sendError("invalid-input", terminalID: command.terminalID, to: client)
                return
            }
            terminalService.handleInput(TerminalInputMessage(sessionID: sessionID, terminalID: terminalID, data: input))
        case "resize":
            guard let terminalID = command.terminalID,
                  let cols = command.cols, let rows = command.rows,
                  cols > 0, rows > 0, cols <= 1000, rows <= 1000 else {
                sendError("invalid-terminal-size", terminalID: command.terminalID, to: client)
                return
            }
            terminalService.handleResize(TerminalResizeMessage(sessionID: sessionID, terminalID: terminalID, cols: cols, rows: rows))
        case "close":
            guard let terminalID = command.terminalID else { sendError("invalid-terminal", to: client); return }
            terminalService.handleClose(TerminalCloseMessage(sessionID: sessionID, terminalID: terminalID, reason: "browser-requested"))
        case "agentprompt":
            guard let terminalID = command.terminalID,
                  let rawProvider = command.provider,
                  let provider = Self.browserProvider(rawProvider),
                  let prompt = command.prompt,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  prompt.utf8.count <= AgentPromptMessage.maxPromptBytes,
                  let service = client.agentSemanticService else {
                sendError("invalid-agent-prompt", terminalID: command.terminalID, to: client)
                return
            }
            service.handlePrompt(AgentPromptMessage(
                sessionID: sessionID,
                terminalID: terminalID,
                provider: provider,
                prompt: prompt,
                workingDirectory: command.workingDirectory
            ))
        case "clipboardget":
            let text = String((readClipboard() ?? "").prefix(ClipboardSyncMessage.maxContentLength))
            sendJSON(BrowserClipboardEvent(text: text), to: client)
        case "clipboardset":
            guard let text = command.text, text.utf8.count <= ClipboardSyncMessage.maxContentLength else {
                sendError("clipboard-too-large", terminalID: command.terminalID, to: client)
                return
            }
            writeClipboard(text)
            sendJSON(BrowserClipboardEvent(text: text), to: client)
        case "addworkspace":
            guard let requestWorkspaceAccess else {
                sendError("workspace-access-unavailable", to: client)
                return
            }
            requestWorkspaceAccess { [weak self, weak client] approved in
                guard let self, let client else { return }
                self.workspaceService?.listWorkspaces(refresh: true) { [weak self, weak client] workspaces, roots, error in
                    guard let self, let client else { return }
                    self.queue.async {
                        let message = approved ? error : (error ?? "Folder selection was cancelled on the Mac.")
                        self.sendJSON(BrowserWorkspaceEvent(workspaces: workspaces, roots: roots, error: message), to: client)
                    }
                }
            }
        case "ping":
            sendJSON(BrowserPongEvent(), to: client)
        default:
            sendError("unknown-command", terminalID: command.terminalID, to: client)
        }
    }

    private func sendTerminalEnvelope(_ envelope: DataChannelEnvelope, to client: BrowserClient) {
        guard client.mode == .webSocket else {
            logger.warning("Dropping terminal envelope because browser client is not in WebSocket mode")
            return
        }
        switch envelope.kind {
        case .terminalReady:
            guard let message = try? envelope.decodeTerminalReady() else {
                logger.error("Could not decode terminal-ready envelope for browser")
                return
            }
            sendJSON(BrowserReadyEvent(terminalID: message.terminalID, cols: message.cols, rows: message.rows), to: client)
        case .terminalOutput:
            guard let message = try? envelope.decodeTerminalOutput() else {
                logger.error("Could not decode terminal-output envelope for browser")
                return
            }
            sendJSON(BrowserOutputEvent(terminalID: message.terminalID, data: message.data.base64EncodedString(), sequence: message.sequence), to: client)
        case .terminalClose:
            guard let message = try? envelope.decodeTerminalClose() else {
                logger.error("Could not decode terminal-close envelope for browser")
                return
            }
            sendJSON(BrowserCloseEvent(terminalID: message.terminalID, reason: message.reason ?? "closed"), to: client)
        case .taskPlanEvent:
            guard let message = try? envelope.decodeTaskPlanEvent() else {
                logger.error("Could not decode task-plan event for browser")
                return
            }
            sendJSON(BrowserTaskPlanEvent(sessionID: message.sessionID, terminalID: message.terminalID, event: message.event), to: client)
        case .providerSemanticEvent:
            guard let message = try? envelope.decodeProviderSemanticEvent() else {
                logger.error("Could not decode provider semantic event for browser")
                return
            }
            sendJSON(BrowserProviderSemanticEvent(message: message), to: client)
        default:
            break
        }
    }

    private func sendError(_ code: String, terminalID: UUID? = nil, to client: BrowserClient) {
        sendJSON(BrowserErrorEvent(code: code, terminalID: terminalID), to: client)
    }

    private static func browserProvider(_ value: String) -> AgentProviderKind? {
        switch value.lowercased() {
        case "grok": return .grok
        case "opencode", "open-code": return .openCode
        case "claude": return .claude
        case "codex", "chatgpt": return .codex
        case "pi": return .pi
        case "commandcode", "command-code", "cmd": return .commandCode
        case "kimi": return .kimi
        case "qwen", "qwen-code": return .qwen
        case "aider": return .aider
        case "gemini", "gemini-cli": return .gemini
        default: return nil
        }
    }

    // MARK: Wire helpers

    private func sendHTTP(
        _ status: HTTPStatus,
        contentType: String = "text/plain; charset=utf-8",
        body: String,
        to client: BrowserClient
    ) {
        let data = Data(body.utf8)
        let response = "HTTP/1.1 \(status.code) \(status.reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'\r\n"
            + "Connection: close\r\n\r\n"
        sendRaw(Data(response.utf8) + data, to: client) { [weak self] in
            self?.remove(clientID: client.id, connection: client.connection)
        }
    }

    private func sendHTTP(
        _ status: HTTPStatus,
        contentType: String,
        data: Data,
        to client: BrowserClient
    ) {
        let response = "HTTP/1.1 \(status.code) \(status.reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Cache-Control: public, max-age=86400, immutable\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "Content-Security-Policy: default-src 'none'\r\n"
            + "Connection: close\r\n\r\n"
        sendRaw(Data(response.utf8) + data, to: client) { [weak self] in
            self?.remove(clientID: client.id, connection: client.connection)
        }
    }

    private func sendJSON<T: Encodable>(_ value: T, to client: BrowserClient) {
        guard let data = try? JSONEncoder().encode(value) else {
            logger.error("Could not encode browser WebSocket event")
            return
        }
        sendWebSocketFrame(data, opcode: 0x1, to: client)
    }

    private func sendRaw(_ data: Data, to client: BrowserClient, completion: (() -> Void)? = nil) {
        client.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { completion?() }
        })
    }

    private func sendWebSocketFrame(_ payload: Data, opcode: UInt8, to client: BrowserClient) {
        guard payload.count <= Self.maxWebSocketFrameBytes else {
            sendError("response-too-large", to: client)
            return
        }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            frame.append(126)
            frame.append(contentsOf: UInt16(payload.count).bigEndianBytes)
        } else {
            frame.append(127)
            frame.append(contentsOf: UInt64(payload.count).bigEndianBytes)
        }
        frame.append(payload)
        sendRaw(frame, to: client)
    }

    private func publishStatus(error: String? = nil) {
        if let error {
            lastError = error
        } else if listenerReady {
            lastError = nil
        }
        onStatusChange?(currentStatusOnQueue())
    }

    private func currentStatusOnQueue() -> HostBrowserControlStatus {
        HostBrowserControlStatus(
            running: listener != nil && listenerReady,
            port: listener?.port?.rawValue,
            tailscaleHost: tailscaleListenerHost,
            pairingCode: pairingCode,
            pairingCodeExpiresAt: pairingCodeIssuedAt.addingTimeInterval(Self.pairingCodeLifetime),
            lastError: lastError
        )
    }

    private static func parseRequestLine(_ line: String) -> BrowserHTTPRequest? {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, let url = URLComponents(string: parts[1]) else { return nil }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return BrowserHTTPRequest(method: parts[0].uppercased(), path: url.path.isEmpty ? "/" : url.path, query: query)
    }

    private static func websocketAcceptValue(key: String) -> String {
        let source = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        return Data(Insecure.SHA1.hash(data: source)).base64EncodedString()
    }

    private static func decodeFrame(from buffer: inout Data) -> BrowserWebSocketFrame? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.startIndex + 1]
        // Browser-to-server frames must be final, unfragmented, masked frames.
        // Rejecting anything else keeps this intentionally small parser from
        // accepting protocol variants it cannot safely reassemble.
        guard first & 0x80 != 0,
              first & 0x70 == 0,
              second & 0x80 != 0 else {
            buffer.removeAll()
            return BrowserWebSocketFrame(opcode: 0x8, payload: Data())
        }
        let opcode = first & 0x0F
        let masked = true
        var length = Int(second & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            // readUInt16 already assembles the network-order bytes into a
            // host-order value. Applying a second endian swap makes every
            // launcher command over 125 bytes appear incomplete forever.
            length = Int(buffer.readUInt16(at: offset))
            offset += 2
        } else if length == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            let longLength = buffer.readUInt64(at: offset)
            guard longLength <= UInt64(Self.maxWebSocketFrameBytes) else {
                buffer.removeAll()
                return BrowserWebSocketFrame(opcode: 0x8, payload: Data())
            }
            length = Int(longLength)
            offset += 8
        }
        guard length <= Self.maxWebSocketFrameBytes,
              opcode != 0,
              opcode < 0x8 || length <= 125 else {
            buffer.removeAll()
            return BrowserWebSocketFrame(opcode: 0x8, payload: Data())
        }
        var mask: [UInt8] = []
        guard buffer.count >= offset + 4 else { return nil }
        mask = Array(buffer[offset..<(offset + 4)])
        offset += 4
        guard buffer.count >= offset + length else { return nil }
        var payload = Data(buffer[offset..<(offset + length)])
        buffer.removeSubrange(0..<(offset + length))
        if masked {
            for index in 0..<payload.count {
                payload[index] ^= mask[index % 4]
            }
        }
        return BrowserWebSocketFrame(opcode: opcode, payload: payload)
    }

    private func issuePairingCode() {
        pairingCodeExpiryWorkItem?.cancel()
        pairingCode = HostBrowserPairingCode.generate()
        pairingCodeIssuedAt = Date()
        browserToken = nil
        browserTokenExpiresAt = nil
        pairFailuresByAddress.removeAll()

        // Keep the host's displayed code and the listener's accepted code in
        // lockstep. Previously the code simply stayed on screen forever after
        // expiry, which made Safari show the misleading "invalid or expired"
        // error until the operator manually rotated it.
        let expiryWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.listener != nil,
                  self.listenerReady,
                  HostBrowserPairingCode.isExpired(
                      issuedAt: self.pairingCodeIssuedAt,
                      lifetime: Self.pairingCodeLifetime
                  ) else {
                return
            }
            self.issuePairingCode()
            self.publishStatus()
        }
        pairingCodeExpiryWorkItem = expiryWorkItem
        queue.asyncAfter(
            deadline: .now() + Self.pairingCodeLifetime,
            execute: expiryWorkItem
        )
    }

    /// Returns true when a live listener had an expired code and a fresh one
    /// was issued. Callers use the result to publish the new code to the host
    /// UI immediately, including when the expiry callback was delayed by other
    /// work on the serial queue.
    @discardableResult
    private func refreshExpiredPairingCodeIfNeeded() -> Bool {
        guard listener != nil,
              listenerReady,
              HostBrowserPairingCode.isExpired(
                  issuedAt: pairingCodeIssuedAt,
                  lifetime: Self.pairingCodeLifetime
              ) else {
            return false
        }
        issuePairingCode()
        return true
    }

    private func revokeBrowserSessions(reason: String) {
        let currentClients = Array(clients.values)
        clients.removeAll()
        for client in currentClients {
            client.terminalService?.sessionDidEnd(reason: reason)
            client.connection.cancel()
        }
    }

    private func revokeWebSocketSessions(reason: String) {
        let websocketClients = clients.values.filter { $0.mode == .webSocket }
        for client in websocketClients {
            clients.removeValue(forKey: client.id)
            client.terminalService?.sessionDidEnd(reason: reason)
            client.connection.cancel()
        }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Effectively unreachable on Apple platforms; fall back to the
            // system CSPRNG rather than weakening the token.
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Data(lhs.utf8)
        let right = Data(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(left, right) { difference |= a ^ b }
        return difference == 0
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class BrowserClient: @unchecked Sendable {
    enum Mode { case http, webSocket }

    let id: UUID
    let connection: NWConnection
    var mode: Mode = .http
    var receiveBuffer = Data()
    var sessionID: UUID?
    var terminalService: HostTerminalService?
    var agentSemanticService: HostAgentSemanticService?

    init(id: UUID, connection: NWConnection) {
        self.id = id
        self.connection = connection
    }
}

private struct BrowserHTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
}

private struct BrowserWebSocketFrame {
    let opcode: UInt8
    let payload: Data
}

private enum HTTPStatus {
    case ok, badRequest, unauthorized, forbidden, notFound, conflict, tooManyRequests

    var code: Int {
        switch self {
        case .ok: return 200
        case .badRequest: return 400
        case .unauthorized: return 401
        case .forbidden: return 403
        case .notFound: return 404
        case .conflict: return 409
        case .tooManyRequests: return 429
        }
    }

    var reason: String {
        switch self {
        case .ok: return "OK"
        case .badRequest: return "Bad Request"
        case .unauthorized: return "Unauthorized"
        case .forbidden: return "Forbidden"
        case .notFound: return "Not Found"
        case .conflict: return "Conflict"
        case .tooManyRequests: return "Too Many Requests"
        }
    }
}

private struct BrowserPairRequest: Decodable {
    let code: String?
}

private struct BrowserPairResponse: Encodable {
    let token: String
    let expiresAt: Date
}

private struct BrowserStatusResponse: Encodable {
    let terminalModeEnabled: Bool
    let maxTerminals: Int
    let running: Bool
    let tailscaleHost: String?
    let pairingCodeExpiresAt: Date
}

private struct BrowserTerminalCommand: Decodable {
    let type: String?
    let terminalID: UUID?
    let cols: UInt16?
    let rows: UInt16?
    let term: String?
    let startupCommand: String?
    let workspaceID: UUID?
    let workingDirectory: String?
    let data: String?
    let text: String?
    let provider: String?
    let prompt: String?
}

private struct BrowserWorkspaceEvent: Encodable {
    let type = "workspaces"
    let workspaces: [RemoteWorkspace]
    let roots: [WorkspaceBrowseRoot]
    let error: String?
}

private struct BrowserHelloEvent: Encodable {
    let type = "hello"
    let sessionID: UUID
    let maxTerminals: Int
    let features: BrowserFeatureCapabilities
    let capabilities: [String]
}

private struct BrowserFeatureCapabilities: Encodable {
    let chat: Bool
    let taskPlans: Bool
    let workspaces: Bool
}

private struct BrowserReadyEvent: Encodable {
    let type = "ready"
    let terminalID: UUID
    let cols: UInt16
    let rows: UInt16
}

private struct BrowserOutputEvent: Encodable {
    let type = "output"
    let terminalID: UUID
    let data: String
    let sequence: UInt64
}

private struct BrowserCloseEvent: Encodable {
    let type = "close"
    let terminalID: UUID
    let reason: String
}

private struct BrowserTaskPlanEvent: Encodable {
    let type = "taskPlanEvent"
    let sessionID: UUID
    let terminalID: UUID
    let event: SessionTaskEvent
}

private struct BrowserProviderSemanticEvent: Encodable {
    let type = "providerSemanticEvent"
    let sessionID: UUID
    let terminalID: UUID
    let provider: AgentProviderKind
    let eventType: String
    let text: String?

    init(message: ProviderSemanticEventMessage) {
        sessionID = message.sessionID
        terminalID = message.terminalID
        provider = message.provider
        switch message.event {
        case .messageDelta(let value): eventType = "messageDelta"; text = value
        case .thinkingDelta(let value): eventType = "thinkingDelta"; text = value
        case .permissionRequested(let value): eventType = "permissionRequested"; text = value
        case .sessionIdentifier(let value): eventType = "sessionIdentifier"; text = value
        case .completed: eventType = "completed"; text = nil
        case .failed(let value): eventType = "failed"; text = value
        case .taskPlan: eventType = "taskPlan"; text = nil
        }
    }
}

private struct BrowserErrorEvent: Encodable {
    let type = "error"
    let code: String
    let terminalID: UUID?
}

private struct BrowserClipboardEvent: Encodable {
    let type = "clipboard"
    let text: String
}

private struct BrowserPongEvent: Encodable {
    let type = "pong"
}

private extension UInt16 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }
}

private extension UInt64 {
    var bigEndianBytes: [UInt8] {
        [
            UInt8((self >> 56) & 0xFF), UInt8((self >> 48) & 0xFF),
            UInt8((self >> 40) & 0xFF), UInt8((self >> 32) & 0xFF),
            UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)
        ]
    }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        let a = UInt16(self[self.startIndex + offset])
        let b = UInt16(self[self.startIndex + offset + 1])
        return (a << 8) | b
    }

    func readUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(self[self.startIndex + offset + index])
        }
        return value
    }
}

enum BrowserControlWebAssets {
    static let indexHTML = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#FFFFFF"><title>Vamp Terminal · Task chat</title>
<script>(function(){var value='light';try{value=localStorage.getItem('vamp.appearance')||'light'}catch(_){}document.documentElement.dataset.theme=value})();</script>
<style>
:root{color-scheme:light;--bg:#FFFFFF;--panel:#FFFFFF;--panel2:#FAFAFA;--line:#E4E4E7;--muted:#71717A;--text:#18181B;--accent:#18181B;--good:#22C55E;--warn:#F59E0B;--danger:#EF4444;--u:4px;--s1:4px;--s2:8px;--s3:12px;--s4:16px;--s5:20px;--s6:24px;--control:44px;--radius-card:14px;--radius-control:12px}
*{box-sizing:border-box}body{margin:0;background:#FFFFFF;color:var(--text);font:15px -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;min-height:100vh}button,input{font:inherit}button{color:inherit;border:0;cursor:pointer}.shell{max-width:980px;margin:auto;min-height:100vh;padding:env(safe-area-inset-top) 14px env(safe-area-inset-bottom);display:flex;flex-direction:column}.top{height:54px;display:flex;align-items:center;gap:11px;border-bottom:1px solid var(--line)}.back{background:none;color:#3F3F46;font-size:22px;width:32px}.title{font-weight:650;font-size:17px}.top .state{margin-left:auto;color:var(--muted);font-size:12px}.dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--muted);margin-right:6px}.dot.connected{background:var(--good)}.dot.connecting,.dot.pairing{background:var(--warn)}.dot.offline,.dot.error,.dot.disabled{background:var(--danger)}.tabs{display:flex;align-items:center;gap:8px;padding:12px 0 9px;overflow-x:auto;scrollbar-width:none}.tabs::-webkit-scrollbar{display:none}.tab{display:flex;align-items:center;gap:7px;white-space:nowrap;background:#FFFFFF;border:1px solid var(--line);border-radius:17px;padding:8px 12px;color:#3F3F46}.tab.active{border-color:#18181B;background:#18181B;color:#fff}.tab .close{color:#A1A1AA;background:none;padding:0 0 0 3px}.newtab{background:#FFFFFF;border:1px solid var(--line);border-radius:16px;padding:8px 11px;font-size:18px}.content{display:flex;flex:1;min-height:0}.chat{flex:1;min-width:0;padding:12px 0 120px}.stream{display:none}.stream.active{display:block}.message{margin:0 0 18px;line-height:1.55}.message .meta{color:#71717A;font-size:12px;margin-bottom:6px}.message .body{white-space:pre-wrap;word-break:break-word}.explore{color:#52525B;font-size:13px;margin:12px 0 18px}.explore span{color:#A1A1AA;margin:0 6px}.command-card{background:#FFFFFF;border:1px solid var(--line);border-radius:14px;padding:12px;margin:13px 0 20px;box-shadow:0 1px 2px rgba(0,0,0,.05)}.command-card .eyebrow{color:#18181B;font-size:13px;margin-bottom:10px}.command-card .approval{color:#71717A;margin:7px 0 11px}.command{background:#F4F4F5;border:1px solid var(--line);border-radius:10px;padding:12px;white-space:pre-wrap;overflow:auto;font:14px ui-monospace,SFMono-Regular,Menlo,monospace;color:#18181B}.command .prompt{color:#71717A}.approval-actions{display:flex;gap:8px;align-items:center;margin-top:11px}.approval-actions button{border-radius:11px;padding:10px 13px;background:#18181B;color:#fff;font-weight:650}.approval-actions button.secondary{background:#FFFFFF;border:1px solid var(--line);color:#3F3F46}.approval-actions button.danger{background:#FFFFFF;border:1px solid rgba(239,68,68,.35);color:#DC2626}.terminal{background:#0B0B0B;border:1px solid var(--line);border-radius:14px;padding:14px;min-height:150px;max-height:48vh;overflow:auto;font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;color:#E8E8E8;white-space:pre-wrap;word-break:break-word}.terminal:focus{outline:2px solid rgba(24,24,27,.35);outline-offset:2px}.quick{display:flex;gap:7px;overflow:auto;padding:10px 0;scrollbar-width:none}.quick::-webkit-scrollbar{display:none}.quick button{background:#FFFFFF;border:1px solid var(--line);border-radius:9px;padding:8px 11px;white-space:nowrap;color:#3F3F46}.composer{position:fixed;left:14px;right:14px;bottom:max(12px,env(safe-area-inset-bottom));margin:auto;max-width:952px;background:#FFFFFF;border:1px solid #E4E4E7;border-radius:16px;padding:8px;display:flex;gap:7px;box-shadow:0 1px 3px rgba(0,0,0,.07)}.composer input{flex:1;min-width:0;background:transparent;border:0;outline:0;color:#18181B;padding:8px}.composer input::placeholder{color:#A1A1AA}.composer button{width:42px;height:38px;border-radius:11px;background:#F4F4F5;font-size:17px;color:#3F3F46}.composer button.send{background:#18181B;color:#fff;font-weight:700}.empty{color:#71717A;padding:35px 8px;text-align:center}.badge{color:#71717A;font-size:12px;margin:5px 0 15px}.modal{position:fixed;inset:0;background:rgba(24,24,27,.4);display:flex;align-items:center;justify-content:center;padding:20px;z-index:3}.modal.hidden{display:none}.modal-card{width:min(420px,100%);background:#FFFFFF;border:1px solid #E4E4E7;border-radius:18px;padding:18px;box-shadow:0 16px 48px rgba(0,0,0,.16)}.modal-card h2{margin:0 0 7px;font-size:20px}.modal-card p{color:#71717A;line-height:1.45}.modal-card input{width:100%;background:#FFFFFF;border:1px solid #D4D4D8;border-radius:10px;padding:12px;color:#18181B;letter-spacing:.18em;text-align:center}.modal-card button{margin-top:12px;border-radius:11px;padding:11px 14px;background:#18181B;color:#fff;font-weight:650}.modal-card .error{color:#DC2626;min-height:18px;font-size:13px}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}@media(min-width:720px){.shell{padding-left:28px;padding-right:28px}.composer{left:28px;right:28px}.terminal{max-height:50vh}.chat{padding-top:20px}}@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important}}
/* The browser surface follows the same four-point rhythm as the iOS client.
   Keep the original CSS above intentionally small; these rules provide the
   responsive controls without making the embedded asset depend on a bundle. */
.tab{min-height:40px}.newtab{min-width:44px;min-height:44px}.quick button{min-height:40px}.composer{z-index:4}.composer input{min-height:44px}.clipboard-wrap{position:relative;flex:0 0 44px;width:44px;min-width:44px;overflow:visible}.clipboard-trigger{box-sizing:border-box;width:44px!important;min-width:44px;padding:0!important;display:flex;align-items:center;justify-content:center;font-size:0!important;overflow:hidden}.clipboard-trigger .clipboard-label{display:none!important}.clipboard-glyph{display:block;width:18px;height:18px;line-height:18px;font-size:19px!important;font-weight:500;text-align:center}.clipboard-menu{position:absolute;left:0;bottom:calc(100% + 8px);z-index:6;display:flex;flex-direction:column;align-items:stretch;gap:2px;width:max-content;min-width:230px;max-width:calc(100vw - 40px);padding:8px;background:rgba(43,43,43,.96);border:1px solid rgba(255,255,255,.18);border-radius:14px;box-shadow:0 18px 48px rgba(0,0,0,.42);backdrop-filter:blur(18px)}.clipboard-menu.hidden{display:none}.clipboard-menu button{display:block;box-sizing:border-box;width:100%!important;height:auto!important;min-height:40px;margin:0;padding:10px 12px;text-align:left;white-space:nowrap;background:transparent;border-radius:9px;font-size:14px;color:#eee}.clipboard-menu button:hover,.clipboard-menu button:focus-visible{background:rgba(255,255,255,.12)}.approval-actions{flex-wrap:wrap}.tab-dot{color:var(--muted);font-size:11px}.tab-dot.open{color:var(--good)}.tab-dot.opening{color:var(--warn)}.modal-card input,.modal-card button{min-height:44px}
.workspace-list{display:grid;gap:8px;max-height:min(52vh,420px);overflow:auto}.workspace-choice{display:flex!important;flex-direction:column;align-items:flex-start;gap:4px;width:100%;margin:0!important;padding:12px 14px!important;background:rgba(255,255,255,.08)!important;color:#fff!important;text-align:left}.workspace-choice small{color:#aaa;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;overflow-wrap:anywhere}
</style></head>
<body class="pairing"><div class="shell">
<header class="top"><button class="back" id="back" aria-label="Open sessions dashboard" title="Open sessions dashboard" onclick="vampToggleDashboard()">‹</button><div class="title" id="page-title">Task chat</div><div class="state"><span class="dot"></span><span id="state">Pairing</span></div></header>
<nav class="tabs" id="tabs" aria-label="Terminal tabs"><button class="newtab" id="newtab" aria-label="New terminal">＋</button></nav>
<nav class="mode-switch" id="mode-switch" aria-label="Session mode"><button id="mode-chat" type="button" aria-pressed="true"><span aria-hidden="true">▤</span> Chat</button><button id="mode-terminal" type="button" aria-pressed="false"><span aria-hidden="true">›_</span> Terminal</button></nav>
<main class="content">
<section class="dashboard hidden" id="dashboard" aria-labelledby="dashboard-title">
  <div class="dashboard-heading"><div><div class="dashboard-kicker">VAMP TERMINAL</div><h1 id="dashboard-title">Sessions</h1><p>Choose a live shell or return to the task stream. Tabs stay independent while you switch.</p></div><button class="dashboard-open" id="dashboard-open" type="button">Open task chat</button></div>
  <article class="host-card"><div><div class="dashboard-kicker">HOST CONNECTION</div><h2 id="dashboard-host-title">This Mac</h2><p id="dashboard-host-detail">Checking Vamp Host…</p></div><span class="host-state" id="dashboard-host-state">●</span></article>
  <div class="session-heading"><h2>Active sessions</h2><span id="dashboard-count">0 / 8</span></div>
  <div class="session-grid" id="session-grid"></div>
</section>
<section class="chat" id="chat"><div class="empty" id="empty">Pair this browser to start a terminal task.</div></section>
</main>
<div class="terminal-keybar" id="terminal-keybar" aria-label="Terminal controls" aria-hidden="true" hidden><button type="button" data-terminal-key="\u001b">Esc</button><button type="button" data-terminal-key="\u0003">Ctrl-C</button><button type="button" data-terminal-key="\u0009">Tab</button><button type="button" data-terminal-key="\u001b[A">↑</button><button type="button" data-terminal-key="\u001b[B">↓</button><button type="button" data-terminal-key="\u001b[D">←</button><button type="button" data-terminal-key="\u001b[C">→</button></div>
<div class="composer" id="composer"><div class="clipboard-wrap"><button id="clipboard" class="clipboard-trigger" type="button" title="Clipboard actions" aria-label="Clipboard actions" aria-expanded="false"><span class="clipboard-glyph" aria-hidden="true">⧉</span></button><div id="clipboard-menu" class="clipboard-menu hidden" role="menu" aria-label="Clipboard actions"><button id="paste" type="button" role="menuitem">Paste into terminal</button><button id="copyhost" type="button" role="menuitem">Copy Mac clipboard to Safari</button><button id="sethost" type="button" role="menuitem">Send Safari clipboard to Mac</button></div></div><input id="input" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="Type a command…"><button id="more" type="button" title="More controls" aria-label="More controls">•••</button><button class="send" id="send" type="button" title="Review command" aria-label="Review command">↑</button></div>
</div>
<div class="modal" id="pair" role="dialog" aria-modal="true" aria-labelledby="pair-title"><div class="modal-card"><div class="pair-mark" aria-hidden="true">⌁</div><h2 id="pair-title">Open this workspace</h2><p id="pair-help">Scan the QR code from Vamp Host, or enter the 12-digit code shown in Settings → Browser control. The code expires after ten minutes.</p><label class="field-label" for="code">Pairing code</label><input id="code" inputmode="numeric" maxlength="12" placeholder="000000000000" aria-describedby="pair-help pair-error" autocomplete="one-time-code"><div class="error" id="pair-error" role="alert" aria-live="polite"></div><button id="pair-button" type="button">Pair browser</button></div></div>
<div class="modal hidden" id="launch-modal"><div class="modal-card more-card"><div class="more-kicker">New session</div><h2 id="launch-title">Choose workspace</h2><p id="launch-copy">Every session keeps its own working directory.</p><div class="workspace-list" id="workspace-list"></div><div class="more-footer"><button id="launch-cancel" class="secondary" type="button">Cancel</button></div></div></div>
<div class="modal hidden" id="more-modal"><div class="modal-card more-card"><div class="more-kicker">Terminal actions</div><h2>Open a session</h2><p>Start a fresh shell, attach a persistent tmux or screen session, or open a coding agent in a new tab.</p><div class="more-actions"><button id="more-shell" type="button"><span class="provider-mark" style="--provider:#e8e8e8">›_</span><span><b>New shell</b><br><small>Open an independent terminal tab</small></span></button><button id="more-tmux" type="button" class="secondary"><span class="provider-mark" style="--provider:#9dd6ff">▣</span><span><b>Attach / create tmux</b><br><small>Resume a named workspace</small></span></button><button id="more-screen" type="button" class="secondary"><span class="provider-mark" style="--provider:#b8a6ff">▤</span><span><b>Attach screen</b><br><small>Resume a GNU screen session</small></span></button></div><div class="provider-title">Agent launchers</div><div class="provider-grid"><button type="button" data-provider="opencode" style="--provider:#00c8ce"><img class="provider-logo" src="/assets/providers/opencode.png" alt=""><span>OpenCode</span></button><button type="button" data-provider="pi" style="--provider:#f57a48"><span class="provider-mark">π</span><span>Pi</span></button><button type="button" data-provider="commandcode" style="--provider:#b883ff"><span class="provider-mark">⌘</span><span>CommandCode</span></button><button type="button" data-provider="chatgpt" style="--provider:#10a37f"><img class="provider-logo" src="/assets/providers/openai.jpg" alt=""><span>ChatGPT CLI</span></button><button type="button" data-provider="claude" style="--provider:#dc6a42"><img class="provider-logo" src="/assets/providers/claude.jpg" alt=""><span>Claude Code</span></button><button type="button" data-provider="kimi" style="--provider:#4c8dff"><img class="provider-logo" src="/assets/providers/kimi.jpg" alt=""><span>Kimi</span></button><button type="button" data-provider="qwen" style="--provider:#4678f2"><span class="provider-mark">Q</span><span>Qwen Code</span></button><button type="button" data-provider="codex" style="--provider:#10a37f"><img class="provider-logo" src="/assets/providers/openai.jpg" alt=""><span>Codex CLI</span></button><button type="button" data-provider="aider" style="--provider:#66c28c"><span class="provider-mark">A</span><span>Aider</span></button><button type="button" data-provider="grok" style="--provider:#e6a94f"><img class="provider-logo" src="/assets/providers/grok.jpg" alt=""><span>Grok CLI</span></button><button type="button" data-provider="gemini" style="--provider:#587fe8"><span class="provider-mark">Gm</span><span>Gemini CLI</span></button></div><label class="more-command">Custom command or session<input id="more-command" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="tmux attach -t work"></label><div class="more-footer"><button id="appearance-toggle" class="secondary appearance-toggle" type="button">Appearance · System</button><button id="more-cancel" class="secondary" type="button">Cancel</button><button id="more-open" type="button">Open tab</button></div></div></div>
<script>
const $=id=>document.getElementById(id);
let ws=null,token=null,sessionId=null,active=null,order=[],tabs=new Map();
function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
// Task plans are a semantic projection supplied by an agent adapter. They
// never read `.terminal`, `.out`, or any VT screen rows.
const vampTaskPlanProgress = (plan) => {
  const tasks = Array.isArray(plan?.tasks) ? plan.tasks : [];
  const running = tasks.find((task) => task.status === 'running');
  const position = running ? Math.max(1, tasks.indexOf(running) + 1)
    : plan?.state === 'completed' ? tasks.length : Math.min(tasks.length, Math.max(1, tasks.filter((task) => task.status === 'completed' || task.status === 'skipped').length + 1));
  return position + ' of ' + tasks.length;
};
const vampTaskPlanIcon = (status) => ({pending:'○',running:'◌',completed:'✓',failed:'!',skipped:'—'}[status] || '○');
const vampTaskPlanEventIsBound = (event, expectedSessionID, expectedTerminalID) => {
  if (!event || !event.kind) return false;
  if (event.kind === 'planCreated' || event.kind === 'planUpdated') {
    return event.plan?.sessionID === expectedSessionID && event.plan?.terminalID === expectedTerminalID;
  }
  return true;
};
const vampNormalizeTaskPlan = (plan) => {
  if (!plan || !Array.isArray(plan.tasks) || plan.tasks.length < 1) return null;
  return {
    id: plan.id || vampNewUUID(), sessionID: plan.sessionID || sessionId,
    terminalID: plan.terminalID, title: plan.title || 'Plan',
    state: plan.state || 'planning', source: plan.source || 'adapter',
    tasks: plan.tasks.map((task, index) => ({
      id: task.id || vampNewUUID(), order: Number(task.order || index + 1),
      title: String(task.title || '').slice(0, 240), detail: task.detail || null,
      status: task.status || 'pending', failureReason: task.failureReason || null,
      startedAt: task.startedAt || null,
      completedAt: task.completedAt || null
    })), updatedAt: plan.updatedAt || new Date().toISOString()
  };
};
const vampRenderTaskPlan = (tabID) => {
  const tab = tabs.get(tabID);
  if (!tab) return;
  let card = document.querySelector('.task-plan-message[data-tab-id="' + tabID + '"]');
  if (!tab.taskPlan) { card?.remove(); return; }
  if (!card) {
    card = document.createElement('article');
    card.className = 'message task-plan-message';
    card.dataset.tabId = tabID;
    $('chat').appendChild(card);
  }
  // Keep an explicit collapse choice stable while incremental task events
  // replace the card contents. A task transition must not reopen a plan the
  // user intentionally collapsed.
  const wasExpanded = card.querySelector('.task-plan-header')?.getAttribute('aria-expanded') !== 'false';
  const plan = tab.taskPlan;
  const rows = plan.tasks.slice().sort((a,b) => a.order - b.order).map((task) =>
    '<div class="task-plan-row ' + esc(task.status) + '"><span class="task-plan-symbol">' + vampTaskPlanIcon(task.status) + '</span><div><div class="task-plan-title">' + esc(task.order + '. ' + task.title) + '</div>' +
    (task.status === 'running' && task.detail ? '<div class="task-plan-detail">' + esc(task.detail) + '</div>' : task.status === 'failed' && task.failureReason ? '<div class="task-plan-detail failed">' + esc(task.failureReason) + '</div>' : '') + '</div></div>'
  ).join('');
  card.innerHTML = '<div class="task-plan-card"><button type="button" class="task-plan-header" aria-expanded="' + String(wasExpanded) + '"><span class="task-plan-status">' + (plan.state === 'completed' ? '✓' : plan.state === 'failed' ? '!' : '◌') + '</span><strong>' + esc(plan.title || 'Plan') + '</strong><span class="task-plan-progress">' + esc(vampTaskPlanProgress(plan)) + '</span><span class="task-plan-chevron">' + (wasExpanded ? '⌃' : '⌄') + '</span></button><div class="task-plan-body"' + (wasExpanded ? '' : ' hidden') + '>' + rows + '</div><div class="task-plan-footer"><span>' + esc(plan.source === 'inferred' ? 'Inferred from agent plan' : 'Agent task plan') + '</span>' + ((plan.state === 'planning' || plan.state === 'running') ? '<button type="button" class="task-plan-interrupt" aria-label="Interrupt task plan">■ Interrupt</button>' : plan.state === 'paused' ? '<button type="button" class="task-plan-resume" aria-label="Resume task plan">▶ Resume</button>' : '') + '</div></div>';
  const header = card.querySelector('.task-plan-header');
  header.onclick = () => {
    const body = card.querySelector('.task-plan-body');
    const expanded = header.getAttribute('aria-expanded') !== 'false';
    header.setAttribute('aria-expanded', String(!expanded));
    body.hidden = expanded;
    card.querySelector('.task-plan-chevron').textContent = expanded ? '⌄' : '⌃';
  };
  card.querySelector('.task-plan-interrupt')?.addEventListener('click', (event) => {
    event.stopPropagation();
    if (sendInput(tabID, '\u0003')) window.vampApplyTaskPlanEvent(tabID, {kind: 'planPaused'});
  });
  card.querySelector('.task-plan-resume')?.addEventListener('click', (event) => {
    event.stopPropagation();
    window.vampApplyTaskPlanEvent(tabID, {kind: 'planResumed'});
  });
  if (typeof filterTabContent === 'function') filterTabContent();
};
window.vampApplyTaskPlanEvent = (tabID, event) => {
  const tab = tabs.get(tabID);
  if (!tab || !event?.kind) return false;
  const tasks = () => tab.taskPlan?.tasks || [];
  switch (event.kind) {
    case 'planCreated': tab.taskPlan = vampNormalizeTaskPlan(event.plan); break;
    case 'planUpdated': tab.taskPlan = vampNormalizeTaskPlan(event.plan); break;
    case 'taskAdded': {
      const task = event.task ? {id: event.task.id || vampNewUUID(), order: Number(event.task.order || tasks().length + 1), title: String(event.task.title || ''), detail: event.task.detail || null, status: event.task.status || 'pending', startedAt: event.task.startedAt || null, completedAt: event.task.completedAt || null} : null;
      if (tab.taskPlan && task && !tasks().some((value) => value.id === task.id)) tab.taskPlan.tasks.push(task);
      break;
    }
    case 'taskRemoved': if (tab.taskPlan) tab.taskPlan.tasks = tasks().filter((task) => task.id !== event.id); break;
    case 'taskRenamed': { const task = tasks().find((value) => value.id === event.id); if (task) { task.title = event.title || task.title; task.detail = event.detail || null; } break; }
    case 'taskReordered': { const task = tasks().find((value) => value.id === event.id); if (task) task.order = Number(event.order || task.order); break; }
    case 'taskStarted': { const task = tasks().find((value) => value.id === event.id); if (task) { task.status = 'running'; task.failureReason = null; task.startedAt ||= new Date().toISOString(); task.completedAt = null; } if (tab.taskPlan) tab.taskPlan.state = 'running'; break; }
    case 'taskCompleted': { const task = tasks().find((value) => value.id === event.id); if (task) { task.status = 'completed'; task.failureReason = null; task.completedAt ||= new Date().toISOString(); } if (tab.taskPlan) tab.taskPlan.state = tasks().every((value) => value.status === 'completed' || value.status === 'skipped') ? 'completed' : 'running'; break; }
    case 'taskFailed': { const task = tasks().find((value) => value.id === event.id); if (task) { task.status = 'failed'; task.failureReason = event.reason ? String(event.reason).slice(0, 500) : null; } if (tab.taskPlan) tab.taskPlan.state = 'failed'; break; }
    case 'taskSkipped': { const task = tasks().find((value) => value.id === event.id); if (task) { task.status = 'skipped'; task.failureReason = null; } if (tab.taskPlan && tasks().every((value) => value.status === 'completed' || value.status === 'skipped')) tab.taskPlan.state = 'completed'; break; }
    case 'planPaused': if (tab.taskPlan) tab.taskPlan.state = 'paused'; break;
    case 'planResumed': if (tab.taskPlan) tab.taskPlan.state = 'running'; break;
    case 'planCompleted': if (tab.taskPlan) tab.taskPlan.state = 'completed'; break;
    case 'planFailed': if (tab.taskPlan) tab.taskPlan.state = 'failed'; break;
    case 'planCancelled': if (tab.taskPlan) tab.taskPlan.state = 'cancelled'; break;
    default: return false;
  }
  if (tab.taskPlan) tab.taskPlan.updatedAt = new Date().toISOString();
  vampRenderTaskPlan(tabID);
  if (typeof renderTabs === 'function') renderTabs();
  if (tabID === active && typeof isNearBottom === 'function' && isNearBottom()) scrollLatest(true);
  return true;
};
window.vampInferTaskPlan = (tabID, semanticText) => {
  if (!semanticText || /\u001b/.test(semanticText)) return false;
  const parsed = String(semanticText).replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n').map((line) => line.trim()).filter(Boolean).map((line) => {
    const numbered = line.match(/^(\d+)[.)]\s+(.{4,})$/);
    if (numbered) return {number: Number(numbered[1]), title: numbered[2], status: 'pending'};
    const checklist = line.match(/^[-*]\s+\[([ xX])\]\s+(.{4,})$/);
    if (checklist) return {number: 0, title: checklist[2], status: checklist[1].toLowerCase() === 'x' ? 'completed' : 'pending'};
    return null;
  }).filter(Boolean);
  const hasChecklist = parsed.length > 0 && parsed.every((item) => item.number === 0);
  const numbersAreSequential = parsed.length > 0 && parsed.every((item, index) => item.number === index + 1);
  const lower = String(semanticText).toLowerCase();
  const hasPlanMarker = /\b(plan|steps|checklist|todo|implementation)\b/.test(lower);
  // Two numbered paragraphs are ordinary prose; only strong task syntax or
  // an explicit plan marker may create a semantic plan card.
  if (parsed.length < 2 || (!hasChecklist && !numbersAreSequential) || (!hasChecklist && !hasPlanMarker)) return false;
  return window.vampApplyTaskPlanEvent(tabID, {kind: 'planCreated', plan: {id: vampNewUUID(), sessionID: sessionId, terminalID: tabID, title: 'Inferred plan', source: 'inferred', state: 'planning', tasks: parsed.map((item, index) => ({id: vampNewUUID(), order: index + 1, title: item.title, status: item.status}))}});
};
function setState(s){vampStateLabel=s;$('state').textContent=s;const dot=document.querySelector('.dot');if(dot){const key=String(s||'').toLowerCase().replace(/\s+/g,'-');dot.className='dot '+(key==='connected'?'connected':key==='connecting'?'connecting':key==='pairing'?'pairing':key==='disabled'?'disabled':key==='offline'||key.includes('error')?'offline':'pairing')}}
let vampStateLabel = 'Pairing';
let vampActivityAt = 0, vampWorkEpoch = 0;
const vampNoteActivity = () => {
  const now = Date.now();
  vampActivityAt = now;
  if (!vampWorkEpoch) vampWorkEpoch = now;
  vampRefreshWorkingState();
};
const vampWorkingActive = () => vampActivityAt > 0 && Date.now() - vampActivityAt < 30000 && vampStateLabel === 'Connected';
const vampWorkingLabel = () => {
  const sec = Math.max(1, Math.round((Date.now() - vampWorkEpoch) / 1000));
  return sec < 60 ? 'Working' : 'Working for ' + Math.floor(sec / 60) + 'm';
};
const vampRefreshWorkingState = () => {
  if (vampWorkingActive()) { $('state').textContent = vampWorkingLabel(); }
  else if (vampStateLabel === 'Connected') { vampWorkEpoch = 0; $('state').textContent = 'Connected'; }
};
setInterval(vampRefreshWorkingState, 10000);
function send(o){if(ws&&ws.readyState===1){ws.send(JSON.stringify(o));return true}return false}
</script>
<script>
// Harden the embedded browser client after the initial lightweight boot code:
// keep approvals and input tied to the tab that created them, preserve UTF-8
// across output chunks, expose both clipboard directions, and make reconnect
// and resize paths explicit.
let vampStatus = null;
let vampResizeFrame = 0;
const vampUpdateViewportInset = () => {
  const viewport = window.visualViewport;
  const layoutHeight = document.documentElement.clientHeight || window.innerHeight;
  const visibleBottom = viewport ? viewport.height + viewport.offsetTop : layoutHeight;
  const inset = Math.max(0, Math.round(layoutHeight - visibleBottom));
  document.documentElement.style.setProperty('--vamp-bottom-inset', inset + 'px');
  // iOS Safari may report the entire keyboard height here while the shell is
  // already sized to the visual viewport. Capping the composer lift avoids a
  // second full-height compensation that would strand the composer halfway
  // up the page instead of just above the keyboard.
  document.documentElement.style.setProperty('--vamp-composer-inset', Math.min(20, inset) + 'px');
  const visibleHeight = viewport ? Math.max(240, Math.round(viewport.height)) : layoutHeight;
  document.documentElement.style.setProperty('--vamp-visual-height', visibleHeight + 'px');
  const terminalHeight = Math.min(460, Math.max(160, Math.round(visibleHeight * 0.42)));
  document.documentElement.style.setProperty('--vamp-terminal-height', terminalHeight + 'px');
};
const vampRestoreShellPosition = () => {
  document.activeElement?.blur();
  const content = document.querySelector('.content');
  if (content) content.scrollTop = 0;
  window.scrollTo(0, 0);
  requestAnimationFrame(() => {
    if (content) content.scrollTop = 0;
    window.scrollTo(0, 0);
  });
};
const vampTerminalSize = (id = active) => {
  // PTY geometry follows the actual task viewport, not a guessed Safari
  // toolbar height. The card is a projection of the same terminal state, so
  // its monospace grid and the host's TIOCSWINSZ dimensions stay aligned.
  const content = document.querySelector('.content');
  const surface = tabs.get(id)?.outputCard?.querySelector('.rich-body');
  const width = Math.max(220, Math.floor(surface?.clientWidth || content?.clientWidth || innerWidth - 28));
  const viewport = window.visualViewport;
  const measuredHeight = content?.clientHeight || viewport?.height || innerHeight;
  const terminalMode = document.body.classList.contains('vamp-terminal-mode');
  const height = Math.max(120, Math.min(760, Math.floor(surface?.clientHeight || (terminalMode ? measuredHeight * 0.62 : 148))));
  const cellWidth = 8.4;
  const cellHeight = 19.6;
  return {
    cols: Math.max(24, Math.min(160, Math.floor((width - 20) / cellWidth))),
    rows: Math.max(6, Math.min(48, Math.floor((height - 20) / cellHeight)))
  };
};

let vampChatScrollFrame = 0;
const vampScrollChatToLatest = () => {
  const content = document.querySelector('.content');
  if (!content || vampChatScrollFrame) return;
  vampChatScrollFrame = requestAnimationFrame(() => {
    vampChatScrollFrame = 0;
    // Keep the latest assistant/approval card visible while output streams.
    // Coalescing this work prevents a burst of PTY packets from queueing
    // competing scroll layouts in Safari.
    content.scrollTop = content.scrollHeight;
  });
};

addMessage = (html, tabID = active) => {
  const element = document.createElement('article');
  element.className = 'message';
  if (tabID) element.dataset.tabId = tabID;
  element.innerHTML = html;
  $('chat').appendChild(element);
  vampScrollChatToLatest();
  return element;
};

const vampMoreStyle = document.createElement('style');
vampMoreStyle.textContent = `
  .tab-dot.closed,.tab-dot.error,.tab-dot.offline { color: var(--danger); }
  .rich-code-wrap { position: relative; }
  .rich-code-wrap .rich-code-copy { position: absolute; top: 8px; right: 8px; z-index: 2; min-height: 28px; padding: 4px 10px; border-radius: 8px; border: 1px solid rgba(255,255,255,.16); background: rgba(18,18,18,.72); color: #ddd; font-size: 12px; font-weight: 600; opacity: .82; }
  .rich-code-wrap .rich-code-copy:hover, .rich-code-wrap .rich-code-copy:focus-visible { opacity: 1; background: rgba(42,42,42,.92); }
  .rich-caret { display: inline-block; width: 8px; height: 15px; margin-left: 2px; vertical-align: text-bottom; border-radius: 2px; background: var(--good); animation: vampCaretBlink 1.1s steps(2, start) infinite; }
  @keyframes vampCaretBlink { 50% { opacity: .16; } }
  @media (prefers-reduced-motion: reduce) { .rich-caret { animation: none; } }
  .composer { box-sizing: border-box; width: calc(100% - 32px); min-height: 60px; height: 60px; padding: 8px; gap: 8px; }
  .composer input { box-sizing: border-box; height: 44px; min-height: 44px; padding: 8px 10px; }
  .composer > button { box-sizing: border-box; flex: 0 0 44px; width: 44px; height: 44px; min-height: 44px; padding: 0; }
  .clipboard-trigger { flex: 0 0 auto !important; min-width: 44px; height: 44px !important; }
  .tab-plan-progress { color: #aaa; font: 10px ui-monospace,SFMono-Regular,Menlo,monospace; }
  .task-plan-message { margin-top: 10px; }
  .task-plan-card { background: rgba(42,42,42,.78); border: 1px solid rgba(255,255,255,.16); border-radius: 18px; padding: 14px; box-shadow: 0 14px 42px rgba(0,0,0,.22); }
  .task-plan-header { display: flex; align-items: center; gap: 8px; width: 100%; min-height: 34px; padding: 0; background: transparent; color: #eee; text-align: left; }
  .task-plan-header strong { font-size: 12px; letter-spacing: .08em; text-transform: uppercase; }
  .task-plan-status { color: #bfbfbf; font-size: 15px; }
  .task-plan-progress { margin-left: auto; color: #aaa; font: 12px ui-monospace,SFMono-Regular,Menlo,monospace; }
  .task-plan-chevron { color: #888; font-size: 16px; }
  .task-plan-body { display: grid; gap: 8px; margin-top: 10px; }
  .task-plan-row { display: grid; grid-template-columns: 20px minmax(0,1fr); gap: 8px; align-items: start; color: #ddd; font-size: 14px; line-height: 1.35; }
  .task-plan-row.completed,.task-plan-row.skipped { color: #999; }
  .task-plan-row.running .task-plan-title { font-weight: 650; color: #fff; }
  .task-plan-symbol { color: #aaa; font-size: 16px; text-align: center; }
  .task-plan-row.completed .task-plan-symbol { color: #57d69b; }
  .task-plan-row.failed .task-plan-symbol { color: #ff8d85; }
  .task-plan-detail { color: #999; font-size: 12px; margin-top: 3px; }
  .task-plan-detail.failed { color: #ffaaa4; }
  .task-plan-footer { display: flex; align-items: center; gap: 8px; margin-top: 12px; color: #888; font-size: 11px; }
  .task-plan-interrupt,.task-plan-resume { margin-left: auto; border: 1px solid rgba(255,255,255,.16); border-radius: 10px; padding: 7px 9px; background: rgba(255,255,255,.08); color: #eee; font-size: 11px; font-weight: 650; }
  .more-card { max-height: min(720px, calc(100dvh - 40px)); overflow: auto; }
  .more-kicker { color: #999; font-size: 12px; text-transform: uppercase; letter-spacing: .08em; }
  .more-actions { display: grid; gap: 8px; margin: 14px 0; }
  .more-actions button, .provider-grid button { display: flex; align-items: center; gap: 10px; width: 100%; margin: 0; background: rgba(255,255,255,.08); color: #eee; text-align: left; font-weight: 600; }
  .more-actions button:hover, .more-actions button:focus-visible, .provider-grid button:hover, .provider-grid button:focus-visible { background: rgba(255,255,255,.14); }
  .more-actions button.secondary { background: rgba(255,255,255,.04); color: #ccc; }
  .more-command { display: block; margin-top: 12px; color: #aaa; font-size: 13px; }
  .more-command input { margin-top: 7px; letter-spacing: 0; text-align: left; }
  .provider-title { color: #aaa; font-size: 13px; margin: 18px 0 8px; }
  .provider-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
  .provider-grid button { min-width: 0; padding: 9px 10px; font-size: 13px; }
  .provider-mark { display: grid; place-items: center; flex: 0 0 28px; width: 28px; height: 28px; border-radius: 9px; background: color-mix(in srgb, var(--provider) 18%, transparent); color: var(--provider); border: 1px solid color-mix(in srgb, var(--provider) 45%, transparent); font-weight: 750; }
  .more-footer { display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px; }
  .more-footer button { margin: 0; }
  .more-footer .secondary { background: rgba(255,255,255,.10); color: #eee; }
  [hidden], .hidden { display: none !important; }
  html, body { height: 100%; overflow: hidden; }
  body { overscroll-behavior-y: none; }
  .shell { position: fixed; inset: 0; width: 100%; height: var(--vamp-visual-height, 100svh); min-height: 0; padding-bottom: 0; overflow: hidden; }
  .content { min-height: 0; overflow: auto; overscroll-behavior: contain; }
  .chat { min-height: 100%; padding-bottom: 24px; }
  /* Safari is a task-chat surface. The PTY emulator remains mounted in
     JavaScript for ANSI/cursor parsing, but its raw screen and desktop-style
     quick-key rail must never compete with the conversation or composer. */
  .stream, .terminal, .quick { display: none !important; }
  .message { max-width: 820px; }
  .message.user-message { margin-top: 18px; }
  .message.output-message { margin-top: 8px; }
  .message.output-message .meta { display: flex; align-items: center; gap: 8px; }
  .message.output-message .body { padding-left: 0; color: #f1f1f1; }
  .message.output-message .live-label { color: var(--good); font-size: 11px; }
  .message.output-message .live-label::before { content: '●'; margin-right: 4px; }
  .message.system-message .body { color: #ddd; }
  .command-card { margin-bottom: 18px; }
  .approval-actions { display: grid; gap: 8px; }
  .approval-choice { display: flex; align-items: center; gap: 10px; width: 100%; min-height: 48px; padding: 9px 12px; border: 1px solid rgba(255,255,255,.10); border-radius: 12px; background: rgba(255,255,255,.06); color: #eee; text-align: left; }
  .approval-choice.selected { border-color: rgba(255,255,255,.34); background: rgba(255,255,255,.14); }
  .approval-choice .choice-number { color: #aaa; flex: 0 0 20px; }
  .approval-choice strong { display: block; }
  .approval-choice small { display: block; margin-top: 2px; color: #999; font-size: 12px; }
  .approval-footer { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-top: 12px; }
  .approval-footer .hint { margin: 0; color: #999; font-size: 12px; line-height: 1.35; }
  .approval-footer .confirm { flex: 0 0 auto; min-height: 44px; border-radius: 11px; padding: 0 16px; background: #f5f5f5; color: #111; font-weight: 700; }
  .composer { position: fixed; left: 14px; right: 14px; bottom: calc(max(12px, env(safe-area-inset-bottom)) + var(--vamp-bottom-inset, 0px)); width: min(calc(100% - 28px), 952px); margin: 0 auto; }
  .modal { z-index: 20; height: var(--vamp-visual-height, 100svh); bottom: auto; }
  .modal-card { max-height: calc(var(--vamp-visual-height, 100svh) - 32px); overflow: auto; }
  .dashboard, .dashboard-heading, .dashboard-heading > div, .host-card, .session-card, .session-card-top { min-width: 0; max-width: 100%; }
  .dashboard { width: 100%; min-height: 100%; padding: 24px 0 40px; overflow-x: hidden; }
  .dashboard-heading { display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; margin-bottom: 20px; }
  .dashboard-kicker { color: #999; font-size: 11px; font-weight: 700; letter-spacing: .12em; }
  .dashboard h1, .dashboard h2, .dashboard p { margin: 0; }
  .dashboard h1 { margin-top: 6px; font-size: clamp(26px, 7vw, 36px); letter-spacing: -.03em; }
  .dashboard-heading p { max-width: 560px; margin-top: 8px; color: #aaa; line-height: 1.5; overflow-wrap: anywhere; word-break: break-word; }
  .dashboard-open { min-height: 44px; padding: 0 14px; border: 1px solid rgba(255,255,255,.18); border-radius: 12px; background: rgba(255,255,255,.9); color: #111; font-weight: 700; white-space: nowrap; }
  .host-card, .session-card { border: 1px solid rgba(255,255,255,.16); border-radius: 18px; background: linear-gradient(145deg, rgba(61,61,61,.72), rgba(28,28,28,.72)); box-shadow: 0 18px 46px rgba(0,0,0,.20), inset 0 1px 0 rgba(255,255,255,.08); backdrop-filter: blur(18px); }
  .host-card { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 18px; }
  .host-card h2 { margin-top: 5px; font-size: 19px; }
  .host-card p { margin-top: 7px; color: #aaa; font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; overflow-wrap: anywhere; }
  .host-state { color: var(--good); font-size: 18px; }
  .session-heading { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin: 26px 0 10px; }
  .session-heading h2 { font-size: 15px; }
  .session-heading span { color: #999; font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; }
  .session-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
  .session-card { min-height: 138px; display: flex; flex-direction: column; justify-content: space-between; padding: 15px; }
  .session-card-top { display: flex; align-items: flex-start; justify-content: space-between; gap: 10px; }
  .session-card-title { display: flex; align-items: center; gap: 8px; min-width: 0; font-weight: 700; }
  .session-card-title span:last-child { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .session-card-dot { width: 9px; height: 9px; flex: 0 0 auto; border-radius: 50%; background: #999; }
  .session-card-dot.open { background: var(--good); }
  .session-card-dot.opening { background: var(--warn); }
  .session-card-dot.closed, .session-card-dot.error, .session-card-dot.offline { background: var(--danger); }
  .session-card-meta { margin-top: 10px; color: #aaa; font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; line-height: 1.45; }
  .session-card-action { align-self: flex-start; min-height: 36px; margin-top: 14px; padding: 0 11px; border: 1px solid rgba(255,255,255,.16); border-radius: 10px; background: rgba(255,255,255,.09); color: #eee; font-size: 13px; font-weight: 650; }
  .dashboard-empty { grid-column: 1 / -1; padding: 34px 18px; border: 1px dashed rgba(255,255,255,.18); border-radius: 16px; color: #999; text-align: center; }
  @media (min-width: 720px) { .composer { width: min(calc(100% - 56px), 952px); } }
  @media (max-width: 520px) {
    .shell { padding-top: max(44px, env(safe-area-inset-top)); }
    .composer { left: 0; right: 0; width: 100%; min-height: 60px; height: 60px; padding: 8px; border-radius: 14px; }
    .composer > button { flex-basis: 44px; width: 44px; }
    .approval-footer { align-items: flex-end; }
    .approval-footer .hint { max-width: 58%; }
    .provider-grid { grid-template-columns: 1fr; }
    .dashboard-heading { display: block; }
    .dashboard-heading p { max-width: 100%; }
    .dashboard-open { width: 100%; margin-top: 16px; }
    .session-grid { grid-template-columns: 1fr; }
  }
`;
document.head.appendChild(vampMoreStyle);

// Swift's UUID Codable representation is uppercase while crypto.randomUUID()
// returns lowercase. IDs are case-insensitive on the wire, but Map keys are
// not; normalize host events before routing them to the tab that opened them.
const vampNewUUID = () => {
  if (globalThis.crypto && typeof globalThis.crypto.randomUUID === 'function') {
    // WebKit versions have not been consistent about UUID letter casing.
    // Terminal IDs are case-insensitive on the Swift wire but Map keys are
    // case-sensitive, so canonicalize at creation as well as reception.
    return globalThis.crypto.randomUUID().toLowerCase();
  }
  const bytes = new Uint8Array(16);
  if (globalThis.crypto && typeof globalThis.crypto.getRandomValues === 'function') {
    globalThis.crypto.getRandomValues(bytes);
  } else {
    for (let index = 0; index < bytes.length; index += 1) bytes[index] = Math.floor(Math.random() * 256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (value) => value.toString(16).padStart(2, '0')).join('');
  return (hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20)).toLowerCase();
};
const vampTerminalKey = (value) => String(value || '').toLowerCase();

// A small, dependency-free terminal emulator for Safari. Rendering PTY bytes
// with `textContent` is not enough: carriage returns, cursor movement, erase
// commands, and alternate-screen TUIs are what make agents such as Grok and
// Claude look like joined text with replacement boxes. This keeps a bounded
// screen + scrollback buffer and handles the control sequences used by common
// shells and coding agents while preserving UTF-8 text.
class VampBrowserTerminal {
  constructor(cols = 80, rows = 24) {
    this.cols = Math.max(1, cols); this.rows = Math.max(1, rows);
    this.reset();
  }
  blank() { return Array(this.cols).fill(' '); }
  reset() {
    this.scrollback = []; this.screen = Array.from({length: this.rows}, () => this.blank());
    this.row = 0; this.col = 0; this.saved = {row: 0, col: 0}; this.alt = null; this.pending = '';
  }
  resize(cols, rows) {
    cols = Math.max(1, cols); rows = Math.max(1, rows);
    if (cols === this.cols && rows === this.rows) return;
    const old = this.screen.map((line) => line.join(''));
    this.cols = cols; this.rows = rows;
    this.screen = Array.from({length: rows}, () => this.blank());
    old.slice(-rows).forEach((line, index) => {
      [...line.slice(0, cols)].forEach((character, column) => { this.screen[index][column] = character; });
    });
    this.row = Math.min(this.row, rows - 1); this.col = Math.min(this.col, cols - 1);
  }
  scroll() {
    this.scrollback.push(this.screen.shift().join('').replace(/\s+$/, ''));
    if (this.scrollback.length > 2000) this.scrollback.splice(0, this.scrollback.length - 2000);
    this.screen.push(this.blank()); this.row = this.rows - 1;
  }
  lineFeed() { if (this.row >= this.rows - 1) this.scroll(); else this.row += 1; }
  carriageReturn() { this.col = 0; }
  put(character) {
    if (this.col >= this.cols) { this.col = 0; this.lineFeed(); }
    this.screen[this.row][this.col] = character; this.col += 1;
  }
  eraseLine(mode = 0) {
    const start = mode === 1 ? 0 : this.col;
    const end = mode === 1 ? this.col : this.cols - 1;
    if (mode === 2) { for (let index = 0; index < this.cols; index += 1) this.screen[this.row][index] = ' '; return; }
    for (let index = start; index <= end; index += 1) this.screen[this.row][index] = ' ';
  }
  eraseDisplay(mode = 0) {
    if (mode === 2 || mode === 3) {
      this.screen = Array.from({length: this.rows}, () => this.blank()); this.row = 0; this.col = 0;
      if (mode === 3) this.scrollback = [];
      return;
    }
    if (mode === 0) { this.eraseLine(0); for (let index = this.row + 1; index < this.rows; index += 1) this.screen[index] = this.blank(); }
    if (mode === 1) { this.eraseLine(1); for (let index = 0; index < this.row; index += 1) this.screen[index] = this.blank(); }
  }
  params(raw) {
    const privateMode = raw.startsWith('?');
    const value = privateMode ? raw.slice(1) : raw;
    const values = value === '' ? [] : value.split(';').map((entry) => parseInt(entry, 10) || 0);
    return { privateMode, values };
  }
  csi(raw, final) {
    const parsed = this.params(raw); const values = parsed.values; const first = values[0] || 1;
    if (parsed.privateMode && (final === 'h' || final === 'l')) {
      if (values.includes(1049) || values.includes(47)) {
        if (final === 'h' && !this.alt) {
          this.alt = {screen: this.screen, scrollback: this.scrollback, row: this.row, col: this.col};
          this.scrollback = []; this.screen = Array.from({length: this.rows}, () => this.blank()); this.row = 0; this.col = 0;
        } else if (final === 'l' && this.alt) {
          const saved = this.alt; this.screen = saved.screen; this.scrollback = saved.scrollback; this.row = saved.row; this.col = saved.col; this.alt = null;
        }
      }
      return;
    }
    switch (final) {
      case 'A': this.row = Math.max(0, this.row - first); break;
      case 'B': case 'e': this.row = Math.min(this.rows - 1, this.row + first); break;
      case 'C': case 'a': this.col = Math.min(this.cols - 1, this.col + first); break;
      case 'D': this.col = Math.max(0, this.col - first); break;
      case 'E': this.row = Math.min(this.rows - 1, this.row + first); this.col = 0; break;
      case 'F': this.row = Math.max(0, this.row - first); this.col = 0; break;
      case 'G': case '`': this.col = Math.max(0, Math.min(this.cols - 1, first - 1)); break;
      case 'd': this.row = Math.max(0, Math.min(this.rows - 1, first - 1)); break;
      case 'H': case 'f': {
        const row = Math.max(1, values[0] || 1); const col = Math.max(1, values[1] || 1);
        this.row = Math.min(this.rows - 1, row - 1); this.col = Math.min(this.cols - 1, col - 1); break;
      }
      case 'J': this.eraseDisplay(values[0] || 0); break;
      case 'K': this.eraseLine(values[0] || 0); break;
      case 'P': {
        const count = Math.min(first, this.cols - this.col);
        this.screen[this.row].splice(this.col, count); this.screen[this.row].push(...Array(count).fill(' ')); break;
      }
      case '@': {
        const count = Math.min(first, this.cols - this.col);
        this.screen[this.row].splice(this.col, 0, ...Array(count).fill(' ')); this.screen[this.row].splice(this.cols); break;
      }
      case 's': this.saved = {row: this.row, col: this.col}; break;
      case 'u': this.row = Math.min(this.rows - 1, this.saved.row); this.col = Math.min(this.cols - 1, this.saved.col); break;
      case 'L': {
        const count = Math.min(first, this.rows - this.row);
        for (let index = 0; index < count; index += 1) { this.screen.splice(this.row, 0, this.blank()); this.screen.pop(); } break;
      }
      case 'M': {
        const count = Math.min(first, this.rows - this.row);
        for (let index = 0; index < count; index += 1) { this.screen.splice(this.row, 1); this.screen.push(this.blank()); } break;
      }
      case 'h': case 'l': case 'm': case 'n': case 'r': case 't': case 'c': break;
      default: break;
    }
  }
  feed(text) {
    const input = (this.pending || '') + text; this.pending = '';
    for (let index = 0; index < input.length; index += 1) {
      const code = input.charCodeAt(index); const character = input[index];
      if (character === '\u001b' || character === '\u009b') {
        if (index + 1 >= input.length) { this.pending = input.slice(index); break; }
        const next = character === '\u009b' ? null : input[index + 1];
        if (character === '\u009b' || next === '[') {
          const start = character === '\u009b' ? index + 1 : index + 2;
          let end = start; while (end < input.length && !(/[\x40-\x7e]/.test(input[end]))) end += 1;
          if (end < input.length) { this.csi(input.slice(start, end), input[end]); index = end; continue; }
          this.pending = input.slice(index); break;
        }
        if (next === ']') {
          let end = index + 2; while (end < input.length && input.charCodeAt(end) !== 7 && !(input[end] === '\u001b' && input[end + 1] === '\\')) end += 1;
          if (end >= input.length) { this.pending = input.slice(index); break; }
          index = input[end] === '\u001b' ? end + 1 : end; continue;
        }
        if (next === '7') this.saved = {row: this.row, col: this.col};
        else if (next === '8') { this.row = this.saved.row; this.col = this.saved.col; }
        else if (next === 'D') this.lineFeed();
        else if (next === 'M') { if (this.row > 0) this.row -= 1; }
        else if (next === 'E') { this.carriageReturn(); this.lineFeed(); }
        else if (next === 'c') this.reset();
        index += 1; continue;
      }
      if (character === '\r') { this.carriageReturn(); continue; }
      if (character === '\n') { this.lineFeed(); continue; }
      if (character === '\b') { this.col = Math.max(0, this.col - 1); continue; }
      if (character === '\t') { this.col = Math.min(this.cols - 1, this.col + (8 - (this.col % 8))); continue; }
      if (code < 0x20 || code === 0x7f) continue;
      this.put(character);
    }
  }
  clearScreen() { this.screen = Array.from({length: this.rows}, () => this.blank()); this.row = 0; this.col = 0; }
  render() { return this.scrollback.concat(this.screen.map((line) => line.join('').replace(/\s+$/, ''))).join('\n'); }
}

// Authoritative browser terminal model. It consumes decoded UTF-8 incrementally
// and projects a VT-like screen buffer; network packets are never treated as
// lines and raw ANSI text is never appended to the chat surface.
class VampBrowserVT {
  constructor(cols = 80, rows = 24) {
    this.maxScrollback = 2000;
    this.decoder = new TextDecoder();
    this.cols = Math.max(1, Math.floor(cols));
    this.rows = Math.max(1, Math.floor(rows));
    this.reset();
  }
  blankCell() { return {ch:' ',fg:null,bg:null,bold:false,dim:false,italic:false,underline:false,inverse:false,strike:false,continuation:false}; }
  blank() { return Array.from({length:this.cols}, () => this.blankCell()); }
  cloneCell(cell) { return {...cell}; }
  cloneRow(row) { return row.map((cell) => this.cloneCell(cell)); }
  defaultStyle() { return {fg:null,bg:null,bold:false,dim:false,italic:false,underline:false,inverse:false,strike:false}; }
  reset() {
    this.scrollback=[];
    this.screen=Array.from({length:this.rows},()=>this.blank());
    this.row=0; this.col=0; this.style=this.defaultStyle();
    this.saved={row:0,col:0,style:{...this.style}};
    this.scrollTop=0; this.scrollBottom=this.rows-1; this.alt=null; this.wrap=true; this.wrapNext=false;
    this.cursorVisible=true; this.applicationCursorKeys=false; this.bracketedPaste=false; this.originMode=false;
    this.tabStops=new Set(); this.resetTabStops();
    this.parserState='ground'; this.csiBuffer=''; this.oscBuffer='';
  }
  resetTabStops() { this.tabStops.clear(); for (let column=0; column<this.cols; column+=8) this.tabStops.add(column); }
  cursorSnapshot() { return {row:this.row,col:this.col,style:{...this.style}}; }
  restoreCursor(snapshot) {
    this.row=Math.max(0,Math.min(this.rows-1,snapshot?.row||0));
    this.col=Math.max(0,Math.min(this.cols-1,snapshot?.col||0));
    if (snapshot?.style) this.style={...snapshot.style};
    this.wrapNext=false;
  }
  resize(cols, rows) {
    cols=Math.max(1,Math.floor(cols)); rows=Math.max(1,Math.floor(rows));
    if (cols===this.cols && rows===this.rows) return;
    const old=this.screen; const oldCols=this.cols;
    this.cols=cols; this.rows=rows; this.screen=Array.from({length:rows},()=>this.blank());
    old.slice(-rows).forEach((oldRow,rowIndex)=>oldRow.slice(0,Math.min(oldCols,cols)).forEach((cell,column)=>{this.screen[rowIndex][column]=this.cloneCell(cell);}));
    this.row=Math.min(this.row,rows-1); this.col=Math.min(this.col,cols-1);
    this.scrollTop=0; this.scrollBottom=rows-1; this.tabStops=new Set(); this.resetTabStops();
  }
  scrollRegionUp(count=1) {
    const amount=Math.max(1,Math.min(count,this.scrollBottom-this.scrollTop+1));
    for (let index=0; index<amount; index+=1) {
      const removed=this.screen.splice(this.scrollTop,1)[0]||this.blank();
      if (this.scrollTop===0&&!this.alt) {
        this.scrollback.push(this.cloneRow(removed));
        if (this.scrollback.length>this.maxScrollback) this.scrollback.splice(0,this.scrollback.length-this.maxScrollback);
      }
      this.screen.splice(this.scrollBottom,0,this.blank());
    }
  }
  scrollRegionDown(count=1) { const amount=Math.max(1,Math.min(count,this.scrollBottom-this.scrollTop+1)); for(let index=0;index<amount;index+=1){this.screen.splice(this.scrollBottom,1);this.screen.splice(this.scrollTop,0,this.blank());} }
  lineFeed() { this.wrapNext=false; if(this.row===this.scrollBottom)this.scrollRegionUp(); else this.row=Math.min(this.rows-1,this.row+1); }
  reverseIndex() { if(this.row===this.scrollTop)this.scrollRegionDown(); else this.row=Math.max(0,this.row-1); }
  carriageReturn() { this.col=0; this.wrapNext=false; }
  tab(direction=1) {
    const stops=[...this.tabStops].sort((a,b)=>a-b);
    this.col=direction>0?(stops.find((stop)=>stop>this.col)??this.cols-1):(stops.filter((stop)=>stop<this.col).pop()??0);
    this.wrapNext=false;
  }
  charWidth(character) {
    const code=character.codePointAt(0)||0;
    if((code>=0x300&&code<=0x36f)||(code>=0x1ab0&&code<=0x1aff)||(code>=0x1dc0&&code<=0x1dff)||(code>=0x20d0&&code<=0x20ff)||(code>=0xfe00&&code<=0xfe0f))return 0;
    if((code>=0x1100&&code<=0x115f)||(code>=0x2329&&code<=0x232a)||(code>=0x2e80&&code<=0xa4cf)||(code>=0xac00&&code<=0xd7a3)||(code>=0xf900&&code<=0xfaff)||(code>=0xfe10&&code<=0xfe19)||(code>=0xfe30&&code<=0xfe6f)||(code>=0xff00&&code<=0xff60)||(code>=0x1f300&&code<=0x1faff))return 2;
    return code<0x20||(code>=0x7f&&code<=0x9f)?0:1;
  }
  put(character) {
    const width=this.charWidth(character);
    if(width===0){if(this.col>0)this.screen[this.row][this.col-1].ch+=character;return;}
    if(this.wrapNext){this.col=0;this.lineFeed();}
    if(width===2&&this.col===this.cols-1){if(this.wrap){this.col=0;this.lineFeed();}else return;}
    this.screen[this.row][this.col]={...this.style,ch:character,continuation:false};
    if(width===2&&this.col+1<this.cols)this.screen[this.row][this.col+1]={...this.blankCell(),continuation:true};
    this.col+=width;
    if(this.col>=this.cols){this.col=this.cols-1;this.wrapNext=this.wrap;}
  }
  eraseCell(row,column){if(this.screen[row]?.[column])this.screen[row][column]=this.blankCell();}
  eraseLine(mode=0){
    const start=mode===1?0:this.col; const end=mode===1?this.col:this.cols-1;
    if(mode===2){for(let column=0;column<this.cols;column+=1)this.eraseCell(this.row,column);return;}
    for(let column=Math.max(0,start);column<=Math.min(this.cols-1,end);column+=1)this.eraseCell(this.row,column);
  }
  eraseDisplay(mode=0){
    if(mode===2||mode===3){for(let row=0;row<this.rows;row+=1)this.screen[row]=this.blank();if(mode===3)this.scrollback=[];return;}
    if(mode===0){this.eraseLine(0);for(let row=this.row+1;row<this.rows;row+=1)this.screen[row]=this.blank();}
    if(mode===1){this.eraseLine(1);for(let row=0;row<this.row;row+=1)this.screen[row]=this.blank();}
  }
  eraseCharacters(count=1){for(let column=this.col;column<Math.min(this.cols,this.col+count);column+=1)this.eraseCell(this.row,column);}
  insertCharacters(count=1){const row=this.screen[this.row];row.splice(this.col,count,...Array.from({length:count},()=>this.blankCell()));row.splice(this.cols);}
  deleteCharacters(count=1){const row=this.screen[this.row];row.splice(this.col,count);row.push(...Array.from({length:count},()=>this.blankCell()));row.splice(this.cols);}
  insertLines(count=1){for(let index=0;index<Math.min(count,this.scrollBottom-this.row+1);index+=1){this.screen.splice(this.row,0,this.blank());this.screen.splice(this.scrollBottom+1,1);}}
  deleteLines(count=1){for(let index=0;index<Math.min(count,this.scrollBottom-this.row+1);index+=1){this.screen.splice(this.row,1);this.screen.splice(this.scrollBottom,0,this.blank());}}

  color256(index){
    const palette=['#000000','#800000','#008000','#808000','#000080','#800080','#008080','#c0c0c0','#808080','#ff0000','#00ff00','#ffff00','#0000ff','#ff00ff','#00ffff','#ffffff'];
    if(index<16)return palette[index];
    if(index>=232){const value=8+(index-232)*10;return `rgb(${value},${value},${value})`;}
    const value=index-16;const red=Math.floor(value/36);const green=Math.floor((value%36)/6);const blue=value%6;const channel=(entry)=>entry===0?0:55+entry*40;
    return `rgb(${channel(red)},${channel(green)},${channel(blue)})`;
  }
  sgr(values){
    if(!values.length)values=[0];
    for(let index=0;index<values.length;index+=1){const value=values[index]??0;
      if(value===0)this.style=this.defaultStyle();else if(value===1)this.style.bold=true;else if(value===2)this.style.dim=true;else if(value===3)this.style.italic=true;else if(value===4)this.style.underline=true;else if(value===7)this.style.inverse=true;else if(value===9)this.style.strike=true;
      else if(value===22){this.style.bold=false;this.style.dim=false;}else if(value===23)this.style.italic=false;else if(value===24)this.style.underline=false;else if(value===27)this.style.inverse=false;else if(value===29)this.style.strike=false;
      else if(value>=30&&value<=37)this.style.fg=this.color256(value-30);else if(value>=90&&value<=97)this.style.fg=this.color256(value-90+8);else if(value===39)this.style.fg=null;
      else if(value>=40&&value<=47)this.style.bg=this.color256(value-40);else if(value>=100&&value<=107)this.style.bg=this.color256(value-100+8);else if(value===49)this.style.bg=null;
      else if(value===38||value===48){const target=value===38?'fg':'bg';const mode=values[++index];if(mode===5&&values[index+1]!=null)this.style[target]=this.color256(values[++index]);else if(mode===2&&values[index+3]!=null){this.style[target]=`rgb(${values[index+1]},${values[index+2]},${values[index+3]})`;index+=3;}}
    }
  }
  params(raw){const privateMode=raw.startsWith('?');const body=privateMode?raw.slice(1):raw;const values=body===''?[]:body.split(';').map((entry)=>entry===''?0:parseInt(entry,10)).map((value)=>Number.isFinite(value)?value:0);return {privateMode,values};}
  enterAlternate(){
    if(this.alt)return;
    this.alt={screen:this.screen,scrollback:this.scrollback,row:this.row,col:this.col,saved:this.saved,style:{...this.style},scrollTop:this.scrollTop,scrollBottom:this.scrollBottom};
    this.screen=Array.from({length:this.rows},()=>this.blank());this.scrollback=[];this.row=0;this.col=0;this.saved=this.cursorSnapshot();this.scrollTop=0;this.scrollBottom=this.rows-1;this.wrapNext=false;
  }
  leaveAlternate(){
    if(!this.alt)return;
    const saved=this.alt;this.screen=saved.screen;this.scrollback=saved.scrollback;this.row=saved.row;this.col=saved.col;this.saved=saved.saved;this.style=saved.style;this.scrollTop=saved.scrollTop;this.scrollBottom=saved.scrollBottom;this.alt=null;this.wrapNext=false;
  }
  setMode(values,enabled,privateMode){
    values.forEach((value)=>{if(privateMode&&(value===1049||value===1047||value===47)){if(enabled)this.enterAlternate();else this.leaveAlternate();}else if(privateMode&&value===25)this.cursorVisible=enabled;else if(privateMode&&value===1)this.applicationCursorKeys=enabled;else if(privateMode&&value===7)this.wrap=enabled;else if(privateMode&&value===6)this.originMode=enabled;else if(privateMode&&value===2004)this.bracketedPaste=enabled;});
  }
  csi(raw,final){
    const parsed=this.params(raw);const values=parsed.values;const first=values[0]||1;
    if(final==='h'||final==='l'){this.setMode(values,final==='h',parsed.privateMode);return;}
    switch(final){
      case'A':this.row=Math.max(this.originMode?this.scrollTop:0,this.row-first);break;
      case'B':case'e':this.row=Math.min(this.originMode?this.scrollBottom:this.rows-1,this.row+first);break;
      case'C':case'a':this.col=Math.min(this.cols-1,this.col+first);this.wrapNext=false;break;
      case'D':this.col=Math.max(0,this.col-first);this.wrapNext=false;break;
      case'E':this.row=Math.min(this.rows-1,this.row+first);this.col=0;break;
      case'F':this.row=Math.max(0,this.row-first);this.col=0;break;
      case'G':case'`':this.col=Math.max(0,Math.min(this.cols-1,first-1));this.wrapNext=false;break;
      case'd':this.row=Math.max(0,Math.min(this.rows-1,first-1));this.wrapNext=false;break;
      case'H':case'f':{const row=Math.max(1,values[0]||1);const column=Math.max(1,values[1]||1);this.row=Math.min(this.originMode?this.scrollBottom:this.rows-1,(this.originMode?this.scrollTop:0)+row-1);this.col=Math.min(this.cols-1,column-1);this.wrapNext=false;break;}
      case'J':this.eraseDisplay(values[0]||0);break;case'K':this.eraseLine(values[0]||0);break;case'P':this.deleteCharacters(first);break;case'@':this.insertCharacters(first);break;case'X':this.eraseCharacters(first);break;case'L':this.insertLines(first);break;case'M':this.deleteLines(first);break;case'S':this.scrollRegionUp(first);break;case'T':this.scrollRegionDown(first);break;case's':this.saved=this.cursorSnapshot();break;case'u':this.restoreCursor(this.saved);break;case'm':this.sgr(values);break;
      case'r':{const top=Math.max(1,values[0]||1)-1;const bottom=Math.min(this.rows,values[1]||this.rows)-1;if(top<bottom){this.scrollTop=top;this.scrollBottom=bottom;this.row=this.originMode?top:0;this.col=0;}break;}
      case'g':if((values[0]||0)===3)this.tabStops.delete(this.col);break;case'I':for(let index=0;index<first;index+=1)this.tab(1);break;case'Z':for(let index=0;index<first;index+=1)this.tab(-1);break;default:break;
    }
  }

  feedBytes(bytes){this.feed(this.decoder.decode(bytes,{stream:true}));}
  finish(){const rest=this.decoder.decode();if(rest)this.feed(rest);this.parserState='ground';this.csiBuffer='';this.oscBuffer='';}
  feed(text){
    for(const character of String(text||'')){const code=character.codePointAt(0)||0;
      if(this.parserState==='csi'){if(code>=0x40&&code<=0x7e){this.csi(this.csiBuffer,character);this.csiBuffer='';this.parserState='ground';}else if(character==='\u001b'){this.csiBuffer='';this.parserState='escape';}else this.csiBuffer+=character;continue;}
      if(this.parserState==='osc'||this.parserState==='string'){if(character==='\u0007'||character==='\u009c'){this.parserState='ground';this.oscBuffer='';}else if(character==='\u001b')this.parserState='string-escape';else if(this.parserState==='osc')this.oscBuffer+=character;continue;}
      if(this.parserState==='string-escape'){this.parserState='string';if(character==='\\'){this.parserState='ground';this.oscBuffer='';}continue;}
      if(this.parserState==='escape'){if(character==='['){this.parserState='csi';this.csiBuffer='';continue;}if(character===']'){this.parserState='osc';this.oscBuffer='';continue;}if('PX^_'.includes(character)){this.parserState='string';continue;}if(character==='7')this.saved=this.cursorSnapshot();else if(character==='8')this.restoreCursor(this.saved);else if(character==='D')this.lineFeed();else if(character==='M')this.reverseIndex();else if(character==='E'){this.carriageReturn();this.lineFeed();}else if(character==='c')this.reset();else if(character==='H')this.tabStops.add(this.col);this.parserState='ground';continue;}
      if(character==='\u001b'){this.parserState='escape';continue;}if(character==='\u009b'){this.parserState='csi';this.csiBuffer='';continue;}if(character==='\u009d'){this.parserState='osc';this.oscBuffer='';continue;}if(character==='\r'){this.carriageReturn();continue;}if(character==='\n'){this.lineFeed();continue;}if(character==='\b'){this.col=Math.max(0,this.col-1);this.wrapNext=false;continue;}if(character==='\t'){this.tab(1);continue;}if(code===0x07||code===0x0e||code===0x0f||code===0x7f||code<0x20)continue;this.put(character);
    }
  }
  rowText(row){return row.map((cell)=>cell.continuation?'':cell.ch).join('').replace(/\s+$/,'');}
  render(){return this.scrollback.slice(-200).map((row)=>this.rowText(row)).concat(this.screen.map((row)=>this.rowText(row))).join('\n').replace(/\n+$/,'');}
  renderHTML(){
    const color=(cell)=>{let fg=cell.fg;let bg=cell.bg;if(cell.inverse)[fg,bg]=[bg,fg];const styles=[];if(fg)styles.push('color:'+fg);if(bg)styles.push('background-color:'+bg);if(cell.bold)styles.push('font-weight:700');if(cell.dim)styles.push('opacity:.72');if(cell.italic)styles.push('font-style:italic');if(cell.underline)styles.push('text-decoration:underline');if(cell.strike)styles.push('text-decoration:line-through');return styles.join(';');};
    const rows=this.scrollback.slice(-200).concat(this.screen);
    return rows.map((row)=>{let html='';let run='';let runStyle=null;const flush=()=>{if(!run)return;html+='<span'+(runStyle?' style="'+runStyle+'"':'')+'>'+esc(run)+'</span>';run='';};row.forEach((cell)=>{if(cell.continuation)return;const style=color(cell);if(runStyle!==null&&style!==runStyle)flush();runStyle=style;run+=cell.ch;});flush();return'<div class="terminal-row">'+(html||'&nbsp;')+'</div>';}).join('');
  }
}

// Chat is a semantic projection of the process byte stream, not a rendering
// of the mutable VT screen. This incremental consumer preserves packet-split
// UTF-8/control sequences while discarding cursor/style commands. The full VT
// parser above remains authoritative for Terminal mode.
class VampSemanticStream {
  constructor() {
    this.decoder = new TextDecoder();
    this.state = 'text';
    this.text = '';
    this.pendingCarriageReturn = false;
  }
  feedBytes(bytes) {
    const value = this.decoder.decode(bytes, {stream:true});
    for (const character of value) {
      const code = character.codePointAt(0);
      if (this.pendingCarriageReturn) {
        this.pendingCarriageReturn = false;
        if (character === '\n') { this.text += '\n'; continue; }
        const newline = this.text.lastIndexOf('\n');
        this.text = newline >= 0 ? this.text.slice(0, newline + 1) : '';
      }
      if (this.state === 'text') {
        if (code === 0x1b) { this.state = 'escape'; continue; }
        if (code === 0x9b) { this.state = 'csi'; continue; }
        if (character === '\r') { this.pendingCarriageReturn = true; continue; }
        if (character === '\b') { this.text = this.text.slice(0, -1); continue; }
        if (character === '\t') { this.text += '    '; continue; }
        if (character === '\n' || code >= 0x20) this.text += character;
        continue;
      }
      if (this.state === 'escape') {
        if (character === '[') this.state = 'csi';
        else if (character === ']') this.state = 'osc';
        else this.state = 'text';
        continue;
      }
      if (this.state === 'csi') {
        if (code >= 0x40 && code <= 0x7e) this.state = 'text';
        continue;
      }
      if (this.state === 'osc') {
        if (code === 0x07) this.state = 'text';
        else if (code === 0x1b) this.state = 'oscEscape';
        continue;
      }
      if (this.state === 'oscEscape') this.state = character === '\\' ? 'text' : 'osc';
    }
    if (this.text.length > 24000) this.text = this.text.slice(-24000);
    return this.text.replace(/^\n+|\n+$/g, '');
  }
}

const vampNextTerminalTitle = () => {
  const titles = new Set([...tabs.values()].map((tab) => tab.title));
  let number = 1;
  while (titles.has('Terminal ' + number)) number += 1;
  return 'Terminal ' + number;
};

const vampOpenTerminal = (id) => {
  const tab = tabs.get(id);
  if (!tab || !ws || ws.readyState !== WebSocket.OPEN) return false;
  tab.state = 'opening';
  tab.readyNotified = false;
  renderTabs();
  ensureStream(id);
  const size = vampTerminalSize(id);
  tab.lastSize = size;
  tab.terminal ||= new VampBrowserVT(size.cols, size.rows);
  tab.terminal.resize(size.cols, size.rows);
  const openCommand = {
    type: 'open',
    terminalID: id,
    cols: size.cols,
    rows: size.rows
  };
  // Keep optional fields off the wire instead of encoding JSON nulls. Apart
  // from making the command unambiguous to Swift's decoder, a normal Home
  // shell stays inside the compact WebSocket-frame form used by every browser.
  // Agent/workspace launches still exercise the extended-length frame path.
  if (tab.startupCommand) openCommand.startupCommand = tab.startupCommand;
  if (tab.workspace?.id) openCommand.workspaceID = tab.workspace.id;
  if (tab.workspace?.path) openCommand.workingDirectory = tab.workspace.path;
  const sent = send(openCommand);
  if (!sent) {
    tab.state = 'error';
    addMessage('<div class="badge">The host connection is not ready. Reconnect and retry this terminal.</div>', id);
  }
  if (sent) {
    const openingID = vampTerminalKey(id);
    clearTimeout(tab.openTimeout);
    tab.openTimeout = setTimeout(() => {
      const current = tabs.get(openingID);
      if (!current || current.opened || current.state !== 'opening') return;
      current.state = 'error';
      renderTabs();
      addMessage('<div class="badge">The shell did not acknowledge startup. Retry this terminal.</div>', openingID);
    }, 8000);
  }
  return sent;
};

const vampResizeTerminal = (id) => {
  const tab = tabs.get(id);
  if (!tab || !tab.opened || !ws || ws.readyState !== WebSocket.OPEN || id !== active) return;
  const size = vampTerminalSize(id);
  if (tab.lastSize && tab.lastSize.cols === size.cols && tab.lastSize.rows === size.rows) return;
  tab.lastSize = size;
  tab.terminal?.resize(size.cols, size.rows);
  const element = ensureStream(id);
  const terminal = element?.querySelector('.terminal');
  if (terminal && tab.terminal) terminal.innerHTML = tab.terminal.renderHTML();
  send({ type: 'resize', terminalID: id, cols: size.cols, rows: size.rows });
};

renderTabs = () => {
  const navigation = $('tabs');
  const existing = new Map([...navigation.querySelectorAll('.tab')].map((element) => [element.dataset.id, element]));
  const visible = new Set();
  order.forEach((id) => {
    const tab = tabs.get(id);
    if (!tab) return;
    visible.add(id);
    const button = existing.get(id) || document.createElement('button');
    if (!button.parentNode) {
      button.type = 'button';
      button.dataset.id = id;
      button.onclick = (event) => event.target.closest('.close') ? closeTab(id) : selectTab(id);
      button.oncontextmenu = (event) => {
        event.preventDefault();
        const title = prompt('Rename terminal', tabs.get(id)?.title || 'Terminal');
        if (title && title.trim()) { const current = tabs.get(id); if (current) current.title = title.trim().slice(0, 48); renderTabs(); }
      };
      navigation.insertBefore(button, $('newtab'));
    }
    button.className = 'tab ' + (id === active ? 'active' : '');
    button.setAttribute('aria-pressed', String(id === active));
    const stateClass = tab.opened ? 'open' : (tab.state || 'opening');
    button.innerHTML = '<span class="tab-dot ' + stateClass + '" aria-hidden="true">●</span>' +
      '<span>' + esc(tab.title) + '</span>' +
      (tab.taskPlan && tab.taskPlan.state !== 'completed' && tab.taskPlan.state !== 'cancelled' ? '<span class="tab-plan-progress">' + esc(vampTaskPlanProgress(tab.taskPlan)) + '</span>' : '') +
      (tab.unread ? '<span class="tab-dot" aria-label="Unread output">•</span>' : '') +
      '<span class="close" aria-label="Close">×</span>';
  });
  existing.forEach((button, id) => { if (!visible.has(id)) button.remove(); });
  const selected = navigation.querySelector('.tab.active');
  if (selected) {
    requestAnimationFrame(() => {
      const margin = 12;
      const left = selected.offsetLeft;
      const right = left + selected.offsetWidth;
      const newTab = $('newtab');
      const focusRight = selected.nextElementSibling === newTab
        ? Math.max(right, newTab.offsetLeft + newTab.offsetWidth)
        : right;
      const visibleLeft = navigation.scrollLeft;
      const visibleRight = visibleLeft + navigation.clientWidth;
      if (focusRight > visibleRight - margin) {
        navigation.scrollLeft = Math.min(
          navigation.scrollWidth - navigation.clientWidth,
          focusRight - navigation.clientWidth + margin
        );
      } else if (left < visibleLeft + margin) {
        navigation.scrollLeft = Math.max(0, left - margin);
      }
    });
  }
  renderDashboard();
};

function renderDashboard() {
  const grid = $('session-grid');
  const count = $('dashboard-count');
  const dashboard = $('dashboard');
  if (!grid || !count || dashboard?.classList.contains('hidden')) return;
  count.textContent = order.length + ' / 8';
  const status = vampStatus;
  // The WebSocket is the authoritative signal once a browser is paired. The
  // status endpoint can still contain the previous pre-pair result while its
  // refresh is in flight, which used to make a live dashboard look offline.
  const socketReady = Boolean(ws && ws.readyState === WebSocket.OPEN);
  const hostReady = Boolean(status?.running) || socketReady;
  const hostDetail = status?.tailscaleHost
    ? 'Tailscale · ' + status.tailscaleHost + ':' + (status.port || 9475)
    : hostReady ? 'Connected to Vamp Host' : 'Host control is offline';
  $('dashboard-host-detail').textContent = hostDetail;
  const state = $('dashboard-host-state');
  state.textContent = hostReady ? '●' : '○';
  state.style.color = hostReady ? 'var(--good)' : 'var(--danger)';
  grid.innerHTML = '';
  if (order.length === 0) {
    grid.innerHTML = '<div class="dashboard-empty">No shell tabs yet. Open task chat to start a session.</div>';
    return;
  }
  order.forEach((id) => {
    const tab = tabs.get(id); if (!tab) return;
    const card = document.createElement('article'); card.className = 'session-card';
    const stateClass = tab.opened ? 'open' : (tab.state || 'opening');
    const stateText = tab.opened ? 'Connected' : (tab.state === 'opening' ? 'Opening' : (tab.state || 'Closed'));
    card.innerHTML = '<div class="session-card-top"><div class="session-card-title"><span class="session-card-dot ' + stateClass + '"></span><span>' + esc(tab.title) + '</span></div>' +
      (tab.unread ? '<span class="tab-dot open" aria-label="Unread output">●</span>' : '') +
      '</div><div class="session-card-meta">' + esc(stateText) + '<br>Independent PTY session</div>';
    const action = document.createElement('button'); action.type = 'button'; action.className = 'session-card-action'; action.textContent = id === active ? 'In task chat' : 'Open session';
    action.onclick = () => { selectTab(id); vampToggleDashboard(false); };
    card.append(action); grid.append(card);
  });
}

function vampToggleDashboard(force) {
  const dashboard = $('dashboard');
  const show = typeof force === 'boolean' ? force : dashboard.classList.contains('hidden');
  dashboard.classList.toggle('hidden', !show);
  $('chat').classList.toggle('hidden', show);
  $('tabs').classList.toggle('hidden', show);
  $('composer').classList.toggle('hidden', show);
  $('page-title').textContent = show ? 'Sessions' : 'Task chat';
  $('back').textContent = show ? '×' : '‹';
  $('back').setAttribute('aria-label', show ? 'Close sessions dashboard' : 'Open sessions dashboard');
  $('back').setAttribute('title', show ? 'Close sessions dashboard' : 'Open sessions dashboard');
  if (show) renderDashboard();
  else {
    vampRestoreShellPosition();
    if (active) { selectTab(active); requestAnimationFrame(() => vampResizeTerminal(active)); }
  }
}

$('dashboard-open').onclick = () => vampToggleDashboard(false);

createTab = (startup = null, title = null, agent = null, workspace = null) => {
  if (order.length >= 8) {
    addMessage('<div class="badge">Terminal capacity reached (8 tabs).</div>');
    return null;
  }
  const id = vampTerminalKey(vampNewUUID());
  // Keep the launcher's semantic identity even if a browser/WebKit callback
  // loses the optional dataset argument while the workspace sheet is being
  // presented. Titles are application-owned constants, so this fallback does
  // not guess an agent from arbitrary terminal output or user commands.
  const knownAgentTitles = {
    'OpenCode': 'opencode',
    'Pi': 'pi',
    'CommandCode': 'commandcode',
    'ChatGPT / Codex CLI': 'chatgpt',
    'Claude Code': 'claude',
    'Kimi': 'kimi',
    'Qwen Code': 'qwen',
    'Codex CLI': 'codex',
    'Aider': 'aider',
    'Grok CLI': 'grok',
    'Gemini CLI': 'gemini'
  };
  const sessionAgent = agent || knownAgentTitles[title] || null;
  const tab = {
    id,
    title: title || vampNextTerminalTitle(),
    agent: sessionAgent,
    workspace: workspace || null,
    startupCommand: startup,
    out: '',
    outputCard: null,
    outputText: '',
    semanticBaseline: '',
    responseSemantic: null,
    responseText: '',
    thinkingText: '',
    lastSubmittedCommand: null,
    pendingCommand: null,
    turnState: 'idle',
    pendingInput: null,
    pendingAgentPrompt: null,
    unread: false,
    opened: false,
    readyNotified: false,
    followOutput: false,
    startupSeen: false,
    state: 'opening',
    decoder: new TextDecoder(),
    semantic: new VampSemanticStream(),
    approvals: new Set(),
    terminal: new VampBrowserVT(),
    taskPlan: null
  };
  tabs.set(id, tab);
  order.push(id);
  active = id;
  renderTabs();
  ensureStream(id);
  document.querySelectorAll('.stream').forEach((element) => {
    element.classList.toggle('active', element.dataset.id === id);
  });
  if (ws && ws.readyState === WebSocket.OPEN) vampOpenTerminal(id);
  else showPair();
  return id;
};

selectTab = (id) => {
  const tab = tabs.get(id);
  if (!tab) return;
  active = id;
  tab.unread = false;
  if (tab.opened) ensureStream(id);
  document.querySelectorAll('.stream').forEach((element) => {
    element.classList.toggle('active', element.dataset.id === id);
  });
  renderTabs();
  requestAnimationFrame(() => vampResizeTerminal(id));
  vampScrollChatToLatest();
};

closeTab = (id) => {
  const tab = tabs.get(id);
  if (!tab) return;
  if (tab.opened && !window.confirm('Close ' + tab.title + '? This ends the shell unless it is inside tmux or screen.')) return;
  if (tab.opened && ws && ws.readyState === WebSocket.OPEN) {
    send({ type: 'close', terminalID: id });
  }
  document.querySelector('.stream[data-id="' + id + '"]')?.remove();
  tabs.delete(id);
  order = order.filter((value) => value !== id);
  if (active === id) active = order[0] || null;
  if (!active && vampWorkspaces.length) chooseWorkspaceForLaunch(null, 'Shell');
  if (active) selectTab(active);
  renderTabs();
};

ensureStream = (id) => {
  const tab = tabs.get(id);
  if (!tab) return null;
  let element = document.querySelector('.stream[data-id="' + id + '"]');
  if (!element) {
    element = document.createElement('div');
    element.className = 'stream';
    element.dataset.id = id;
    element.setAttribute('aria-hidden', 'true');
    $('chat').appendChild(element);
  }
  return element;
};

const vampAppendOutputChunk = (id, encoded) => {
  const tab = tabs.get(id);
  if (!tab) return;
  const bytes = Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
  tab.terminal ||= new VampBrowserVT();
  tab.semantic ||= new VampSemanticStream();
  tab.semanticText = tab.semantic.feedBytes(bytes);
  // Plain shells can project a command-scoped byte stream into Chat. Agent
  // tabs cannot: their PTY is an interactive TUI whose cursor redraws, tmux
  // status line, and alternate-screen contents are not semantic messages.
  // Structured agents populate Chat exclusively through
  // providerSemanticEvent; their original bytes remain available in the VT
  // emulator and therefore in Terminal mode.
  const structuredAgent = Boolean(tab.agent && vampStructuredProviders.has(tab.agent));
  if (tab.responseSemantic && !structuredAgent) tab.responseText = tab.responseSemantic.feedBytes(bytes);
  tab.terminal.feedBytes(bytes);
  appendOutput(id);
};

sendInput = (id, text) => {
  const tab = tabs.get(id);
  if (!tab || !ws || ws.readyState !== WebSocket.OPEN || tab.state === 'error' || tab.state === 'closed' || tab.state === 'offline') return false;
  const bytes = new TextEncoder().encode(text);
  if (!tab.opened) {
    const queued = tab.pendingInput || '';
    if (new TextEncoder().encode(queued).length + bytes.length > 16 * 1024) return false;
    tab.pendingInput = queued + text;
    return true;
  }
  let binary = '';
  bytes.forEach((value) => { binary += String.fromCharCode(value); });
  return send({ type: 'input', terminalID: id, data: btoa(binary) });
};

appendCommand = (value, status, tabID = active) => {
  const tab = tabs.get(tabID);
  if (tab) {
    tab.pendingCommand = value;
    // A tab owns one stable semantic stream card for its entire lifetime.
    // Clearing only the JavaScript reference left the previous card mounted
    // in the DOM, so the next PTY chunk created a duplicate Terminal card and
    // split one session's output across two scrolling surfaces. Keep the
    // existing reference; the later presentation layer updates it in place.
  }
  const title = tab?.title || 'Terminal';
  const element = addMessage('<div class="meta">You · ' + esc(title) + ' · ' + esc(status) +
    '</div><div class="body"><span style="color:#aaa">$ </span>' + esc(value) + '</div>', tabID);
  element.classList.add('user-message');
  return element;
};

reviewCommand = () => {
  const value = $('input').value.trim();
  const tabID = active;
  const tab = tabs.get(tabID);
  if (!value || !tabID) return;
  if (!tab || !ws || ws.readyState !== WebSocket.OPEN) {
    addMessage('<div class="badge">This terminal is still opening. Your command is still in the composer.</div>', tabID);
    return;
  }
  if (!tab.opened) {
    if (tab.pendingInput) {
      addMessage('<div class="badge">One command is already queued. It will run when this terminal is ready.</div>', tabID);
      return;
    }
    tab.pendingInput = value + '\r';
    $('input').value = '';
    appendCommand(value, 'Queued · starting', tabID);
    vampScrollChatToLatest();
    return;
  }
  tab.approvals ||= new Set();
  if (tab.approvals.has(value)) {
    if (sendInput(tabID, value + '\r')) {
      $('input').value = '';
      appendCommand(value, 'Running', tabID);
    } else {
      addMessage('<div class="badge">The host connection is not ready. Try again; your command is still in the composer.</div>', tabID);
    }
    return;
  }
  const card = document.createElement('div');
  card.className = 'command-card';
  card.innerHTML =
    '<div class="eyebrow">⌁ Permission required</div>' +
    '<div class="approval">Awaiting approval · ' + esc(tab.title) + '</div>' +
    '<div class="command"><span class="prompt">$ </span>' + esc(value) +
    '<br><span style="color:#888">No output yet.</span></div>' +
    '<div class="approval-actions">' +
    '<button type="button" class="approval-choice selected" data-choice="once"><span class="choice-number">1.</span><span><strong>Allow</strong><small>Allow only this time</small></span></button>' +
    '<button type="button" class="approval-choice" data-choice="always"><span class="choice-number">2.</span><span><strong>Always allow</strong><small>Do not ask again for this command</small></span></button>' +
    '<button type="button" class="approval-choice" data-choice="deny"><span class="choice-number">3.</span><span><strong>Deny</strong><small>Reject it for now</small></span></button>' +
    '</div><div class="approval-footer"><p class="hint">Choose an action, then press Confirm.</p><button type="button" class="confirm">Confirm</button></div>';
  let choice = 'once';
  card.querySelectorAll('[data-choice]').forEach((button) => {
    button.onclick = () => {
      choice = button.dataset.choice || 'once';
      card.querySelectorAll('[data-choice]').forEach((candidate) => candidate.classList.toggle('selected', candidate === button));
    };
  });
  card.querySelector('.confirm').onclick = () => {
    card.remove();
    if (choice === 'deny') {
      $('input').value = '';
      appendCommand(value, 'Denied', tabID);
      return;
    }
    const current = tabs.get(tabID);
    if (choice === 'always' && current) {
      current.approvals ||= new Set();
      current.approvals.add(value);
    }
    if (sendInput(tabID, value + '\r')) {
      $('input').value = '';
      appendCommand(value, choice === 'always' ? 'Always allowed · running' : 'Running', tabID);
    } else {
      if (choice === 'always' && current) current.approvals.delete(value);
      $('input').value = value;
      addMessage('<div class="badge">The host connection closed before the command was sent. Try again.</div>', tabID);
    }
  };
  $('chat').appendChild(card);
  $('input').value = '';
  vampScrollChatToLatest();
};

showPair = () => {
  document.body.classList.add('pairing');
  const shell = document.querySelector('.shell');
  shell?.setAttribute('aria-hidden', 'true');
  if (shell) shell.inert = true;
  $('pair').classList.remove('hidden');
  $('composer').classList.add('hidden');
  $('pair-error').textContent = '';
  if (!$('pair-button').disabled && !matchMedia('(pointer: coarse)').matches) $('code').focus();
};

const vampRefreshStatus = async () => {
  try {
    const response = await fetch('/api/status', { cache: 'no-store' });
    const status = await response.json();
    vampStatus = status;
    if (!status.terminalModeEnabled) {
      setState('Disabled');
      $('empty').textContent = 'Turn on Terminal Mode in Vamp Host before pairing this browser.';
      $('pair-error').textContent = 'Terminal Mode is disabled on the Mac.';
      $('pair-button').disabled = true;
    } else {
      $('pair-button').disabled = false;
      if (!ws || ws.readyState !== WebSocket.OPEN) setState('Pairing');
      $('empty').textContent = 'Pair this browser to start a terminal task.';
    }
    renderDashboard();
  } catch (_) {
    vampStatus = { running: false };
    setState('Offline');
    $('pair-error').textContent = 'Vamp Host is not reachable.';
    renderDashboard();
  }
};

const vampNormalizePairingCode = (raw) => {
  const value = String(raw || '').normalize('NFKC');
  let digits = '';
  for (const character of Array.from(value)) {
    // iOS Safari may insert LRM/RLM or directional-isolate marks into a
    // numeric one-time-code field. They are invisible in the UI but used to
    // make a visibly correct 12-digit code fail local validation.
    if (/\s/u.test(character) || /\p{Cf}/u.test(character) || character === '-' || character === '·') continue;
    if (/^[0-9]$/.test(character)) {
      digits += character;
      continue;
    }
    const codePoint = character.codePointAt(0);
    if (codePoint >= 0x660 && codePoint <= 0x669) digits += String(codePoint - 0x660);
    else if (codePoint >= 0x6f0 && codePoint <= 0x6f9) digits += String(codePoint - 0x6f0);
    else return '';
  }
  return digits.length === 12 ? digits : '';
};

let vampPairInFlight = false;
pair = async (pairingCodeFromURL = null) => {
  if (vampPairInFlight) return;
  const code = vampNormalizePairingCode(pairingCodeFromURL || $('code').value);
  if (!code) {
    $('pair-error').textContent = 'Enter the 12-digit code from Vamp Host.';
    return;
  }
  vampPairInFlight = true;
  $('code').value = code;
  const button = $('pair-button');
  button.disabled = true;
  try {
    const response = await fetch('/api/pair', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code })
    });
    if (!response.ok) {
      if (response.status === 403) {
        $('pair-error').textContent = 'Terminal Mode is disabled on the Mac.';
      } else if (response.status === 409) {
        $('pair-error').textContent = 'Another browser is already connected to this host.';
      } else if (response.status === 429) {
        $('pair-error').textContent = 'Too many attempts. Rotate the code on the host, then try again.';
      } else {
        $('pair-error').textContent = 'That code is invalid or expired.';
      }
      return;
    }
    const result = await response.json();
    if (!result.token) throw new Error('missing-pair-token');
    token = result.token;
    document.body.classList.remove('pairing');
    const shell = document.querySelector('.shell');
    shell?.removeAttribute('aria-hidden');
    if (shell) shell.inert = false;
    $('pair').classList.add('hidden');
    $('composer').classList.remove('hidden');
    vampRestoreShellPosition();
    connect();
  } catch (_) {
    $('pair-error').textContent = 'Could not reach Vamp Host.';
  } finally {
    vampPairInFlight = false;
    button.disabled = false;
  }
};

connect = () => {
  if (!token) return;
  setState('Connecting');
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  // Carry the bearer token in the Sec-WebSocket-Protocol handshake header
  // (a subprotocol list) rather than a ?token= URL query. URLs are written to
  // browser history, referrer headers, and any intermediary logs; handshake
  // headers are not. The server validates the token and echoes only the
  // fixed 'vamp-auth' name back.
  const connection = new WebSocket(
    protocol + '//' + location.host + '/socket',
    ['vamp-auth', token]
  );
  ws = connection;
  connection.onopen = () => {
    setState('Connected');
    // A reconnect can follow a temporarily unavailable browser socket. Do
    // not leave that transient notice above the fresh task stream once the
    // new session is actually live.
    document.querySelectorAll('.message').forEach((element) => {
      if (element.textContent?.trim() === 'Browser session ended. Pair again to reconnect.') element.remove();
    });
    // A reconnect starts a fresh PTY workspace. Remove cards from the prior
    // socket so ready/output history cannot be mistaken for live state.
    chat.querySelectorAll('[data-tab-id], .explore-row[data-tab-id]').forEach((element) => element.remove());
    tabs.forEach((tab) => {
      tab.readyNotified = false;
      tab.outputCard = null;
      tab.outputText = '';
      tab.pendingCommand = null;
      tab.pendingInput = null;
      tab.commandCount = 0;
      tab.followOutput = false;
      tab.startupSeen = false;
      tab.taskPlan = null;
    });
    // Refresh the host card after pairing/reconnect so the dashboard reflects
    // the same live host that accepted this WebSocket.
    void vampRefreshStatus();
    renderDashboard();
    $('empty').hidden = true;
    if (order.length !== 0) order.forEach((id) => {
      const tab = tabs.get(id);
      if (tab && !tab.opened) vampOpenTerminal(id);
    });
  };
  connection.onclose = () => {
    if (ws !== connection) return;
    ws = null;
    token = null;
    setState('Offline');
    $('empty').hidden = false;
    $('empty').textContent = 'Pair this browser to start a terminal task.';
    tabs.forEach((tab) => {
      tab.opened = false;
      tab.state = 'offline';
      tab.out = '';
      tab.unread = false;
      tab.decoder = new TextDecoder();
      tab.terminal = new VampBrowserVT();
      tab.lastSize = null;
      tab.readyNotified = false;
      tab.pendingInput = null;
      tab.pendingAgentPrompt = null;
      tab.followOutput = false;
      tab.startupSeen = false;
      tab.taskPlan = null;
    });
    document.querySelectorAll('.stream').forEach((element) => element.remove());
    chat.querySelectorAll('[data-tab-id], .explore-row[data-tab-id]').forEach((element) => element.remove());
    const notice = addMessage('<div class="badge">Browser session ended. Pair again to reconnect.</div>');
    notice.classList.add('session-ended');
    showPair();
    vampRefreshStatus();
  };
  connection.onerror = () => setState('Connection error');
  connection.onmessage = (event) => {
    let value;
    try { value = JSON.parse(event.data); } catch (_) { return; }
    const terminalErrorText = (code) => {
      const messages = {
        'terminal-disabled': 'Terminal Mode is disabled on the host. Enable it in Vamp Host, then retry this tab.',
        'terminal-capacity': 'This host already has 8 terminal tabs. Close one, then retry.',
        'terminal-start-timeout': 'The shell did not start in time. Check Terminal Mode and retry.',
        'shell-exited': 'The shell exited. Retry this tab to open a fresh shell.',
        'eof': 'The host closed the shell. Retry this tab to open a fresh shell.',
        'user-closed': 'This terminal was closed.',
        'invalid-terminal-size': 'The terminal size was rejected. Resize the browser and retry.',
        'invalid-input': 'That input was rejected by the host.',
        'startup-command-too-large': 'The launcher command is too long.',
        'unknown-command': 'The browser sent an unsupported terminal action.',
        'browser-capacity': 'The host already has another browser connected.'
      };
      if (messages[code]) return messages[code];
      if (String(code || '').startsWith('forkpty failed')) return 'The host could not create a shell. Check macOS permissions and retry.';
      if (String(code || '').startsWith('read-error')) return 'The host shell stopped reading. Retry this tab.';
      return code ? 'Host rejected this terminal action: ' + code : 'The host rejected this terminal action.';
    };
    if (value.type === 'hello') {
      sessionId = value.sessionID;
      window.vampHostFeatures = {
        chat: value.features?.chat === true || value.capabilities?.includes('chat'),
        taskPlans: value.features?.taskPlans === true || value.capabilities?.includes('task-plans'),
        workspaces: value.features?.workspaces === true || value.capabilities?.includes('workspaces')
      };
      setState('Connected');
    } else if (value.type === 'ready') {
      const terminalID = vampTerminalKey(value.terminalID);
      const tab = tabs.get(terminalID);
      if (tab) {
        clearTimeout(tab.openTimeout);
        tab.openTimeout = null;
        // A reconnect or host-side PTY notification can repeat ready for the
        // same terminal. Treat it as an idempotent state repair: the stream or
        // preview node may have been removed by a reconnect, a projection
        // switch, or WebKit memory pressure even though the PTY is still live.
        // Do not return before rebuilding that presentation.
        const firstReady = !tab.readyNotified;
        const queuedInput = tab.pendingInput;
        const queuedAgentPrompt = tab.pendingAgentPrompt;
        tab.pendingInput = null;
        tab.pendingAgentPrompt = null;
        tab.readyNotified = true;
        tab.opened = true;
        tab.state = 'open';
        if (tab.turnState === 'opening') tab.turnState = 'idle';
        tab.terminal ||= new VampBrowserVT(value.cols, value.rows);
        tab.terminal.resize(value.cols, value.rows);
        ensureStream(terminalID);
        if (typeof window.vampEnsureTerminalPreview === 'function') window.vampEnsureTerminalPreview(terminalID);
        if (typeof window.vampRefreshTerminalCard === 'function') window.vampRefreshTerminalCard(terminalID);
        vampResizeTerminal(terminalID);
        renderTabs();
        // The semantic response card can be created after the prior tab
        // filter pass. Re-run it so a newly-ready shell never presents a
        // confusing blank Chat canvas.
        if (typeof window.vampFilterTabContent === 'function') window.vampFilterTabContent();
        if (firstReady && queuedInput && !sendInput(terminalID, queuedInput)) {
          tab.pendingInput = queuedInput;
          addMessage('<div class="badge">The host connection closed before the queued input was sent. Try again.</div>', terminalID);
        }
        if (firstReady && queuedAgentPrompt && !sendAgentPrompt(terminalID, queuedAgentPrompt)) {
          tab.pendingAgentPrompt = queuedAgentPrompt;
          addMessage('<div class="badge">The host connection closed before the queued agent prompt was sent. Try again.</div>', terminalID);
        }
      }
    } else if (value.type === 'workspaces') {
      const discovered = Array.isArray(value.workspaces) ? value.workspaces : [];
      const roots = (Array.isArray(value.roots) ? value.roots : []).map((root) => ({
        id: null,
        name: root.name,
        path: root.path,
        kind: root.name === 'Home' ? 'home' : 'folder',
        isAvailable: true
      }));
      const byPath = new Map();
      [...discovered, ...roots].forEach((workspace) => {
        if (workspace && workspace.path && !byPath.has(workspace.path)) byPath.set(workspace.path, workspace);
      });
      vampWorkspaces = [...byPath.values()];
      if (!$('launch-modal').classList.contains('hidden')) {
        chooseWorkspaceForLaunch(vampPendingLaunch.command, vampPendingLaunch.title, vampPendingLaunch.agent);
      } else if (!active && vampWorkspaces.length) {
        chooseWorkspaceForLaunch(null, 'Shell');
      }
    } else if (value.type === 'output') {
      vampNoteActivity();
      vampAppendOutputChunk(vampTerminalKey(value.terminalID), value.data);
    } else if (value.type === 'taskPlanEvent') {
      if (value.sessionID && value.sessionID !== sessionId) return;
      const terminalID = vampTerminalKey(value.terminalID);
      // Semantic task events are the only source for this card. Do not pass
      // terminal output or rendered rows through the task-plan reducer.
      if (!vampTaskPlanEventIsBound(value.event, sessionId, terminalID)) return;
      window.vampApplyTaskPlanEvent(terminalID, value.event);
    } else if (value.type === 'providerSemanticEvent') {
      if (value.sessionID && value.sessionID !== sessionId) return;
      const terminalID = vampTerminalKey(value.terminalID);
      const tab = tabs.get(terminalID);
      if (!tab) return;
      if (value.eventType === 'messageDelta') {
        vampNoteActivity();
        tab.responseText = (tab.responseText || '') + String(value.text || '');
        tab.pendingCommand = tab.pendingCommand || 'agent';
        tab.turnState = 'working';
        scheduleTerminalRender(terminalID);
      } else if (value.eventType === 'thinkingDelta') {
        vampNoteActivity();
        tab.thinkingText = ((tab.thinkingText || '') + String(value.text || '')).slice(-8000);
        tab.agentState = 'Working';
        tab.turnState = 'working';
        scheduleTerminalRender(terminalID);
      } else if (value.eventType === 'completed') {
        tab.pendingCommand = null;
        tab.agentState = 'Ready';
        tab.turnState = 'completed';
        if (typeof window.vampRefreshTerminalCard === 'function') window.vampRefreshTerminalCard(terminalID);
        else scheduleTerminalRender(terminalID);
      } else if (value.eventType === 'failed') {
        tab.pendingCommand = null;
        tab.agentState = 'Failed';
        tab.turnState = 'failed';
        addMessage('<div class="agent-error-card"><div class="agent-error-head"><span class="agent-error-glyph" aria-hidden="true">⚠</span><strong>' + esc(tab.title) + ' — run failed</strong></div><div class="agent-error-body">' + esc(value.text || 'The agent request failed.') + '</div><div class="agent-error-hint">Check that the ' + esc(tab.title) + ' CLI is installed and signed in, then send again. Open Terminal to inspect the raw session.</div></div>', terminalID);
        if (typeof window.vampRefreshTerminalCard === 'function') window.vampRefreshTerminalCard(terminalID);
        else scheduleTerminalRender(terminalID);
      } else if (value.eventType === 'permissionRequested') {
        addMessage('<div class="meta">Permission required · ' + esc(tab.title) + '</div><div class="body">' + esc(value.text || 'The agent needs approval in Terminal mode.') + '</div>', terminalID);
      }
    } else if (value.type === 'close') {
      const terminalID = vampTerminalKey(value.terminalID);
      const tab = tabs.get(terminalID);
      if (tab) {
        tab.terminal?.finish();
        appendOutput(terminalID);
        tab.opened = false;
        tab.state = String(value.reason || '').startsWith('terminal-') ? 'error' : 'closed';
        tab.readyNotified = false;
        tab.pendingInput = null;
        tab.unread = active !== terminalID;
        renderTabs();
      }
      addMessage('<div class="meta">System · ' + (String(value.reason || '').startsWith('terminal-') ? 'terminal unavailable' : 'terminal closed') +
        '</div><div class="body">' + esc(terminalErrorText(value.reason || 'closed')) + '</div>', terminalID || active);
    } else if (value.type === 'clipboard') {
      void (async () => {
        try {
          await navigator.clipboard.writeText(value.text || '');
          addMessage('<div class="meta">System · clipboard</div><div class="body">' +
            'Mac clipboard copied to Safari.</div>');
        } catch (_) {
          addMessage('<div class="badge">Safari blocked clipboard writing. Open Clipboard and use the copy action again.</div>');
        }
      })();
    } else if (value.type === 'error') {
      const terminalID = vampTerminalKey(value.terminalID);
      const tab = tabs.get(terminalID);
      if (tab) {
        tab.opened = false;
        tab.state = 'error';
        tab.readyNotified = false;
        tab.pendingInput = null;
        tab.unread = active !== terminalID;
        renderTabs();
      }
      if (value.code === 'terminal-disabled') setState('Disabled');
      addMessage('<div class="badge">' + esc(terminalErrorText(value.code)) + '</div>', terminalID || active);
    }
  };
};

const clipboardButton = $('clipboard');
const clipboardMenu = $('clipboard-menu');
const closeClipboardMenu = () => {
  clipboardMenu.classList.add('hidden');
  clipboardButton.setAttribute('aria-expanded', 'false');
};
clipboardButton.onclick = (event) => {
  event.stopPropagation();
  const hidden = clipboardMenu.classList.toggle('hidden');
  clipboardButton.setAttribute('aria-expanded', String(!hidden));
};
clipboardMenu.onclick = (event) => event.stopPropagation();
document.addEventListener('click', closeClipboardMenu);
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') closeClipboardMenu();
});

$('newtab').onclick = () => openMoreModal();
// Resolve the handler at click time. The presentation layer below replaces
// `reviewCommand` with the Chat/Terminal-aware implementation after this boot
// block runs; capturing the old function here would bypass Terminal mode.
$('send').onclick = () => reviewCommand();
$('pair-button').onclick = () => pair();
$('paste').title = 'Paste browser clipboard into the active terminal';
$('paste').setAttribute('aria-label', 'Paste browser clipboard into the active terminal');
$('paste').onclick = async () => {
  try {
    const text = await navigator.clipboard?.readText();
    if (text && active) sendInput(active, text);
  } catch (_) {
    addMessage('<div class="badge">Browser clipboard permission was not granted.</div>');
  }
};
$('copyhost').onclick = () => {
  if (ws && ws.readyState === WebSocket.OPEN) send({ type: 'clipboardGet' });
  closeClipboardMenu();
};
$('sethost').onclick = async () => {
  closeClipboardMenu();
  try {
    const text = await navigator.clipboard.readText();
    if (!text) {
      addMessage('<div class="badge">Your Safari clipboard is empty.</div>');
    } else if (ws && ws.readyState === WebSocket.OPEN) {
      send({ type: 'clipboardSet', text });
      addMessage('<div class="meta">System · clipboard</div><div class="body">Safari clipboard sent to the Mac.</div>');
    }
  } catch (_) {
    addMessage('<div class="badge">Safari clipboard permission was not granted.</div>');
  }
};
$('paste').onclick = async () => {
  closeClipboardMenu();
  try {
    const text = await navigator.clipboard.readText();
    if (text && active) sendInput(active, text);
    else if (!text) addMessage('<div class="badge">Your Safari clipboard is empty.</div>');
  } catch (_) {
    addMessage('<div class="badge">Safari clipboard permission was not granted.</div>');
  }
};
const moreModal = $('more-modal');
const moreCommand = $('more-command');
const vampAppearanceOrder = ['system', 'light', 'dark'];
const vampAppearanceMedia = matchMedia('(prefers-color-scheme: dark)');
let vampAppearance = document.documentElement.dataset.theme || 'light';
const vampApplyAppearance = (value) => {
  vampAppearance = vampAppearanceOrder.includes(value) ? value : 'light';
  document.documentElement.dataset.theme = vampAppearance;
  const resolved = vampAppearance === 'system' ? (vampAppearanceMedia.matches ? 'dark' : 'light') : vampAppearance;
  document.documentElement.dataset.resolvedTheme = resolved;
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', resolved === 'light' ? '#FFFFFF' : '#09090B');
  const button = $('appearance-toggle');
  if (button) button.textContent = 'Appearance · ' + vampAppearance.charAt(0).toUpperCase() + vampAppearance.slice(1);
  try { localStorage.setItem('vamp.appearance', vampAppearance); } catch (_) {}
};
vampAppearanceMedia.addEventListener?.('change', () => { if (vampAppearance === 'system') vampApplyAppearance('system'); });
vampApplyAppearance(vampAppearance);
$('appearance-toggle').onclick = () => vampApplyAppearance(vampAppearanceOrder[(vampAppearanceOrder.indexOf(vampAppearance) + 1) % vampAppearanceOrder.length]);
var vampWorkspaces = [];
let vampPendingLaunch = { command: null, title: 'Shell', agent: null };
const closeMoreModal = () => moreModal.classList.add('hidden');
let vampModalPresentationToken = 0;
const vampEndComposerEditing = () => {
  const composerInput = $('input');
  if (document.activeElement === composerInput) composerInput.blur();
  // The presentation layer installs these globals below. Updating them here
  // makes modal launch deterministic even before Safari emits focusout or its
  // delayed VisualViewport resize events.
  if (typeof window.vampComposerDidBlur === 'function') window.vampComposerDidBlur();
};
const vampPresentAfterKeyboard = (present) => {
  const token = ++vampModalPresentationToken;
  vampEndComposerEditing();
  const viewport = window.visualViewport;
  const layoutHeight = document.documentElement.clientHeight || window.innerHeight;
  const keyboardVisible = viewport && viewport.height < layoutHeight - 80;
  // Present immediately when no software keyboard exists. When it does,
  // wait for WebKit's visual viewport to return instead of showing a sheet
  // that visibly grows and recenters during keyboard dismissal.
  if (!keyboardVisible) { present(); return; }
  const started = performance.now();
  const settle = () => {
    if (token !== vampModalPresentationToken) return;
    const current = window.visualViewport;
    const restored = !current || current.height >= layoutHeight - 80;
    if (restored || performance.now() - started > 420) { present(); return; }
    requestAnimationFrame(settle);
  };
  requestAnimationFrame(settle);
};
const openMoreModal = () => vampPresentAfterKeyboard(() => {
  moreCommand.value = '';
  moreModal.classList.remove('hidden');
  // A launcher menu is not a text-entry surface. Autofocus reopened the iOS
  // keyboard underneath the agent list and made the whole sheet flutter.
  if (!matchMedia('(pointer: coarse)').matches) moreCommand.focus();
});
const closeLaunchModal = () => $('launch-modal').classList.add('hidden');
const openMoreTab = (command, title, agent = null, workspace = null) => {
  closeMoreModal();
  if (order.length >= 8) {
    addMessage('<div class="badge">Terminal capacity reached (8 tabs).</div>');
    return;
  }
  createTab(command || null, title || null, agent, workspace);
};
const chooseWorkspaceForLaunch = (command, title, agent = null) => {
  vampPendingLaunch.command = command;
  vampPendingLaunch.title = title;
  vampPendingLaunch.agent = agent;
  $('launch-title').textContent = agent ? 'Choose workspace for ' + title : 'Choose shell workspace';
  $('launch-copy').textContent = agent ? title + ' starts directly in this folder.' : 'The shell starts directly in the selected folder.';
  const list = $('workspace-list'); list.innerHTML = '';
  if (!vampWorkspaces.length) list.innerHTML = '<div class="badge">No host workspaces are available.</div>';
  vampWorkspaces.filter((item) => item.isAvailable !== false).forEach((item) => {
    const button = document.createElement('button');
    button.type = 'button'; button.className = 'workspace-choice';
    button.innerHTML = '<strong>' + esc(item.name) + '</strong><small>' + esc(item.path) + '</small>';
    button.onclick = () => { closeLaunchModal(); openMoreTab(command, title, agent, item); };
    list.append(button);
  });
  const addFolder = document.createElement('button');
  addFolder.type = 'button'; addFolder.className = 'workspace-choice workspace-add';
  addFolder.innerHTML = '<strong>＋ Add Mac folder…</strong><small>A secure folder chooser opens on the connected Mac</small>';
  addFolder.onclick = () => {
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      addFolder.querySelector('small').textContent = 'Reconnect to the Mac and try again.';
      return;
    }
    addFolder.disabled = true;
    addFolder.querySelector('small').textContent = 'Waiting for selection on the Mac…';
    ws.send(JSON.stringify({type:'addWorkspace'}));
  };
  list.append(addFolder);
  vampPresentAfterKeyboard(() => $('launch-modal').classList.remove('hidden'));
};
$('more').onclick = openMoreModal;
$('more-cancel').onclick = closeMoreModal;
$('more-shell').onclick = () => { closeMoreModal(); chooseWorkspaceForLaunch(null, 'Shell'); };
$('more-tmux').onclick = () => { moreCommand.value = 'tmux new-session -A -s work'; moreCommand.focus(); };
$('more-screen').onclick = () => { moreCommand.value = 'screen -D -RR work'; moreCommand.focus(); };
$('more-open').onclick = () => {
  const command = moreCommand.value.trim();
  openMoreTab(command || null, command ? 'Session ' + (order.length + 1) : null);
};
const vampShellQuote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";
const vampProviderCommand = (executable, session, label) => {
  const quotedExecutable = vampShellQuote(executable);
  const quotedSession = vampShellQuote(session);
  const quotedLabel = vampShellQuote(label);
  return [`if ! command -v tmux >/dev/null 2>&1; then printf '\\nVamp Terminal: tmux is not installed or not on PATH.\\n'; elif ! command -v ${quotedExecutable} >/dev/null 2>&1; then printf '\\nVamp Terminal: ${quotedLabel} CLI (${quotedExecutable}) is not installed or not on PATH.\\n'; else tmux kill-session -t ${quotedSession} 2>/dev/null || true; exec tmux new-session -s ${quotedSession} -- ${quotedExecutable}; fi`, label];
};
const providerCommands = {
  opencode: vampProviderCommand('opencode', 'opencode', 'OpenCode'),
  pi: vampProviderCommand('pi', 'pi', 'Pi'),
  commandcode: vampProviderCommand('cmd', 'command-code', 'CommandCode'),
  chatgpt: vampProviderCommand('codex', 'chatgpt', 'ChatGPT / Codex CLI'),
  claude: vampProviderCommand('claude', 'claude', 'Claude Code'),
  kimi: vampProviderCommand('kimi', 'kimi', 'Kimi'),
  qwen: vampProviderCommand('qwen', 'qwen', 'Qwen Code'),
  codex: vampProviderCommand('codex', 'codex', 'Codex CLI'),
  aider: vampProviderCommand('aider', 'aider', 'Aider'),
  grok: vampProviderCommand('grok', 'grok', 'Grok CLI'),
  gemini: vampProviderCommand('gemini', 'gemini', 'Gemini CLI')
};
document.querySelectorAll('[data-provider]').forEach((button) => {
  button.onclick = () => {
    const value = providerCommands[button.dataset.provider];
    if (value) { closeMoreModal(); chooseWorkspaceForLaunch(value[0], value[1], button.dataset.provider || null); }
  };
});
moreModal.addEventListener('click', (event) => { if (event.target === moreModal) closeMoreModal(); });
$('launch-cancel').onclick = closeLaunchModal;
$('launch-modal').addEventListener('click', (event) => { if (event.target === $('launch-modal')) closeLaunchModal(); });
document.addEventListener('keydown', (event) => { if (event.key === 'Escape') closeMoreModal(); });
moreCommand.addEventListener('keydown', (event) => { if (event.key === 'Enter') openMoreTab(moreCommand.value.trim(), null); });
$('code').addEventListener('keydown', (event) => { if (event.key === 'Enter') { event.preventDefault(); pair(); } });
$('code').addEventListener('input', () => { $('code').value = $('code').value.replace(/[^0-9٠-٩۰-۹]/g, '').slice(0, 6); });
let vampViewportFrame = 0;
let vampViewportDirty = true;
const vampScheduleViewportUpdate = () => {
  vampViewportDirty = true;
  if (vampViewportFrame) return;
  vampViewportFrame = requestAnimationFrame(() => {
    vampViewportFrame = 0;
    if (!vampViewportDirty) return;
    vampViewportDirty = false;
    vampUpdateViewportInset();
    if (active) {
      cancelAnimationFrame(vampResizeFrame);
      vampResizeFrame = requestAnimationFrame(() => { vampResizeFrame = 0; vampResizeTerminal(active); });
    }
  });
};
document.addEventListener('visibilitychange', vampScheduleViewportUpdate);
window.addEventListener('resize', vampScheduleViewportUpdate, { passive: true });
window.visualViewport?.addEventListener('resize', vampScheduleViewportUpdate, { passive: true });
window.visualViewport?.addEventListener('scroll', vampScheduleViewportUpdate, { passive: true });
window.addEventListener('orientationchange', vampScheduleViewportUpdate, { passive: true });
if (globalThis.ResizeObserver) {
  const vampContentElement = document.querySelector('.content');
  const vampContentResizeObserver = new ResizeObserver(vampScheduleViewportUpdate);
  if (vampContentElement) vampContentResizeObserver.observe(vampContentElement);
}
vampScheduleViewportUpdate();
if (!$('pair').classList.contains('hidden')) $('composer').classList.add('hidden');
renderDashboard();
window.addEventListener('beforeunload', () => ws?.close());
vampRefreshStatus();

</script>
<script>
// The browser client is a task stream, not a miniature terminal window. Keep
// the PTY emulator mounted for protocol correctness, then project its useful
// events into a readable, z.ai-style conversation surface.
(() => {
  const shell = document.querySelector('.shell');
  const chat = $('chat');
  const content = document.querySelector('.content');
  if (!shell || !chat || !content) return;

  const style = document.createElement('style');
  style.textContent = `
    :root { --vamp-surface: rgba(255,255,255,.9); --vamp-surface-strong: #FFFFFF; --vamp-border: rgba(24,24,27,.12); --vamp-grid: rgba(24,24,27,.04); }
    html, body { position: fixed !important; inset: 0 !important; width: 100% !important; height: 100% !important; min-height: 0 !important; overflow: hidden !important; overscroll-behavior: none !important; }
    body { background: #FFFFFF !important; }
    .shell { position: fixed !important; inset: 0 !important; width: 100% !important; max-width: 1080px !important; height: 100dvh !important; min-height: 0 !important; margin: 0 auto !important; padding: env(safe-area-inset-top) clamp(12px, 3vw, 28px) 0 !important; overflow: hidden !important; transform: none !important; }
    .shell.vamp-keyboard-open { height: var(--vamp-keyboard-height, 100dvh) !important; }
    .top { flex: 0 0 54px; height: 54px !important; }
    .task-context { flex: 0 0 52px; min-width: 0; display: flex; align-items: center; gap: 8px; border-bottom: 1px solid var(--line); overflow: hidden; }
    .task-context .workspace { min-width: 0; max-width: min(42vw, 270px); color: #f3f3f3; font-size: 15px; font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .context-pill, .context-icon { flex: 0 0 auto; min-height: 34px; border: 1px solid rgba(255,255,255,.10); border-radius: 11px; background: rgba(255,255,255,.075); color: #c8c8c8; }
    .context-pill { max-width: 38vw; padding: 0 11px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .context-icon { width: 36px; padding: 0; font-size: 16px; }
    .context-icon:active, .context-pill:active { background: rgba(255,255,255,.16); }
    .tabs { flex: 0 0 64px; min-height: 64px; padding: 10px 0 !important; }
    .content { flex: 1 1 auto !important; height: 0 !important; min-height: 0 !important; display: block !important; overflow-x: hidden !important; overflow-y: auto !important; overscroll-behavior: contain !important; -webkit-overflow-scrolling: touch; scrollbar-gutter: stable; }
    .chat { min-height: 100% !important; padding: 18px 0 calc(112px + env(safe-area-inset-bottom)) !important; }
    .chat > .hidden, .chat > [data-tab-id].vamp-tab-hidden { display: none !important; }
    .message, .command-card, .stream-card, .explore-row { max-width: 820px; margin-left: auto; margin-right: auto; }
    .message { margin-bottom: 22px; line-height: 1.62; }
    .message .meta { display: flex; align-items: center; gap: 8px; color: #858585; font-size: 12px; letter-spacing: .01em; }
    .message .body { color: #ededed; }
    .message.user-message { margin-top: 18px; }
    .message.user-message .body { color: #dcdcdc; }
    .message.system-message { margin-top: 8px; }
    .message.system-message .body { color: #d7d7d7; }
    .explore-row { display: flex; align-items: center; gap: 7px; width: 100%; margin: 15px auto 16px; color: #808080; font-size: 13px; }
    .explore-row .explore-icon { color: #6b6b6b; font-size: 18px; line-height: 1; }
    .explore-row .explore-kind { color: #bcbcbc; font-weight: 650; }
    .explore-row .explore-detail { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .status-chip { display: inline-flex; align-items: center; gap: 7px; width: fit-content; max-width: 100%; margin: 0 0 18px; padding: 8px 12px; border: 1px solid rgba(66,211,146,.24); border-radius: 999px; background: rgba(66,211,146,.10); color: #d7f7e7; font-size: 13px; font-weight: 650; }
    .status-chip .check { color: var(--good); }
    .stream-card { margin-top: 12px; margin-bottom: 24px; padding: 14px; border: 1px solid var(--vamp-border); border-radius: 18px; background: linear-gradient(145deg, rgba(45,45,45,.78), rgba(25,25,25,.88)); box-shadow: 0 16px 44px rgba(0,0,0,.20), inset 0 1px 0 rgba(255,255,255,.045); }
    .stream-card-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; min-width: 0; }
    .stream-card-actions { display: flex; align-items: center; justify-content: flex-end; gap: 8px; min-width: 0; }
    .stream-card-title { display: flex; align-items: center; gap: 9px; min-width: 0; color: #f3f3f3; font-weight: 700; }
    .stream-card-title span:last-child { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .card-glyph { display: grid; place-items: center; width: 28px; height: 28px; flex: 0 0 28px; border-radius: 9px; background: rgba(255,255,255,.10); color: #e9e9e9; font-size: 17px; }
    .stream-state { flex: 0 0 auto; color: var(--good); font-size: 11px; font-weight: 700; letter-spacing: .04em; text-transform: uppercase; }
    .stream-state::before { content: '●'; margin-right: 5px; }
    .stream-caption { margin: 9px 0 12px 37px; color: #8f8f8f; font-size: 12px; }
    .rich-body { min-width: 0; color: #ededed; overflow-wrap: anywhere; }
    .terminal-rendered { padding: 12px; background: rgba(8,8,8,.86); }
    .terminal-rendered .stream-caption { margin-bottom: 10px; }
    .terminal-rendered .rich-body { max-height: min(58dvh, 620px); overflow: auto; overscroll-behavior: contain; border: 1px solid rgba(255,255,255,.10); border-radius: 12px; background: #080808; padding: 12px; }
    .terminal-row { min-height: 1.4em; width: max-content; min-width: 100%; white-space: pre; color: #e8e8e8; font: 14px/1.4 ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-variant-ligatures: none; letter-spacing: 0; tab-size: 8; overflow-wrap: normal; word-break: normal; }
    .rich-body p { margin: 0 0 12px; line-height: 1.6; }
    .rich-body p:last-child { margin-bottom: 0; }
    .rich-body h3 { margin: 0 0 10px; color: #f5f5f5; font-size: 16px; }
    .inline-code { display: inline; padding: 2px 5px; border: 1px solid rgba(255,255,255,.12); border-radius: 5px; background: rgba(255,255,255,.09); color: #f2f2f2; font: .92em ui-monospace, SFMono-Regular, Menlo, monospace; }
    .rich-code, .rich-box { margin: 0 0 12px; padding: 12px; border: 1px solid rgba(255,255,255,.11); border-radius: 12px; background: rgba(10,10,10,.74); color: #e7e7e7; font: 13px/1.52 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; overflow-x: auto; }
    .rich-code:last-child, .rich-box:last-child { margin-bottom: 0; }
    .rich-code .code-language { display: block; margin-bottom: 7px; color: #8d8d8d; font: 10px -apple-system, BlinkMacSystemFont, sans-serif; letter-spacing: .10em; text-transform: uppercase; }
    .rich-table-wrap { margin: 0 0 12px; overflow-x: auto; border: 1px solid rgba(255,255,255,.11); border-radius: 12px; background: rgba(10,10,10,.50); }
    .rich-table { width: 100%; min-width: 360px; border-collapse: collapse; font-size: 13px; }
    .rich-table th, .rich-table td { padding: 9px 10px; border-bottom: 1px solid rgba(255,255,255,.10); text-align: left; vertical-align: top; }
    .rich-table th { color: #f0f0f0; background: rgba(255,255,255,.07); font-weight: 700; }
    .rich-table td { color: #d1d1d1; }
    .rich-table tr:last-child td { border-bottom: 0; }
    .rich-step { display: flex; align-items: flex-start; gap: 8px; margin: 0 0 10px; padding: 9px 10px; border-left: 2px solid rgba(255,255,255,.22); color: #dedede; }
    .rich-step.good { border-color: var(--good); background: rgba(66,211,146,.07); }
    .rich-step.warn { border-color: var(--warn); background: rgba(255,200,87,.07); }
    .rich-step.bad { border-color: var(--danger); background: rgba(255,117,107,.07); }
    .rich-step .step-mark { flex: 0 0 auto; font-weight: 800; }
    .rich-step.good .step-mark { color: var(--good); }
    .rich-step.warn .step-mark { color: var(--warn); }
    .rich-step.bad .step-mark { color: var(--danger); }
    .rich-empty { color: #969696; font-size: 13px; }
    .command-card { margin-top: 14px; margin-bottom: 24px; padding: 16px; border: 1px solid rgba(255,255,255,.15); border-radius: 18px; background: linear-gradient(145deg, rgba(52,52,52,.88), rgba(35,35,35,.94)); box-shadow: 0 18px 48px rgba(0,0,0,.24); }
    .command-card .eyebrow { color: #d0d0d0; font-size: 15px; font-weight: 700; }
    .command-card .approval { color: #a7a7a7; margin: 6px 0 13px; font-size: 13px; }
    .command-card .command { padding: 13px; border-radius: 13px; background: rgba(12,12,12,.76); font-size: 13px; line-height: 1.5; }
    .command-card .command .prompt { color: #aaa; }
    .approval-actions { gap: 7px !important; }
    .approval-choice { min-height: 52px; padding: 10px 12px; border: 1px solid rgba(255,255,255,.12); color: #f1f1f1 !important; background: rgba(255,255,255,.055) !important; }
    .approval-choice strong { color: #f1f1f1 !important; }
    .approval-choice small { color: #a7a7a7 !important; }
    .approval-choice.selected { border-color: rgba(66,211,146,.62); background: rgba(66,211,146,.13) !important; }
    .approval-choice:focus-visible, .confirm:focus-visible, .context-icon:focus-visible, .context-pill:focus-visible { outline: 2px solid rgba(255,255,255,.72); outline-offset: 2px; }
    .approval-footer { margin-top: 14px; }
    .approval-footer .hint { color: #a7a7a7; }
    .composer { left: 12px !important; right: 12px !important; bottom: max(10px, env(safe-area-inset-bottom)) !important; width: min(calc(100% - 24px), 952px) !important; height: 60px !important; min-height: 60px !important; margin: 0 auto !important; }
    .modal { height: 100% !important; }
    .modal-card { max-height: calc(100% - 32px) !important; }
    @media (min-width: 720px) { .shell { left: 50% !important; right: auto !important; width: min(100%, 1080px) !important; transform: translateX(-50%) !important; } .chat { padding-left: 24px !important; padding-right: 24px !important; } }
    @media (max-width: 520px) { .shell { padding-left: 12px !important; padding-right: 12px !important; } .task-context .workspace { max-width: 36vw; } .context-pill { max-width: 31vw; } .message, .command-card, .stream-card, .explore-row { max-width: none; } }
    @media (prefers-reduced-motion: reduce) { .content { scroll-behavior: auto !important; } }
    /* Final iPhone fit pass. Safari zooms the page when a text field is below
       16px and fixed left/right/width combinations can create a second
       horizontal layout viewport. Keep every mobile surface inside the
       device bounds and let the browser resize the visual viewport naturally. */
    html { -webkit-text-size-adjust: 100%; overflow-x: hidden !important; }
    body { width: 100% !important; max-width: 100% !important; overflow-x: hidden !important; }
    .shell { left: 0 !important; right: auto !important; width: 100% !important; max-width: none !important; margin: 0 !important; transform: none !important; overflow-x: hidden !important; }
    .top { position: relative !important; z-index: 8 !important; display: flex !important; visibility: visible !important; opacity: 1 !important; color: var(--bc-text) !important; background: rgba(255,255,255,.97) !important; }
    .top .back, .top .title { visibility: visible !important; opacity: 1 !important; color: var(--bc-text) !important; -webkit-text-fill-color: var(--bc-text) !important; }
    .top .state, .top .state .dot, .top .state span { visibility: visible !important; opacity: 1 !important; color: var(--bc-secondary) !important; -webkit-text-fill-color: var(--bc-secondary) !important; }
    .top .back { display: grid !important; place-items: center !important; flex: 0 0 32px !important; width: 32px !important; min-width: 32px !important; }
    .top .title { display: block !important; flex: 0 1 auto !important; min-width: 0 !important; }
    .top .state { display: flex !important; align-items: center !important; white-space: nowrap !important; }
    .task-context { width: 100% !important; max-width: 100% !important; padding-left: 0 !important; padding-right: 0 !important; gap: 5px !important; }
    .task-context .workspace { flex: 1 1 auto !important; width: auto !important; max-width: none !important; min-width: 0 !important; }
    .task-context .context-pill { flex: 0 1 108px !important; width: auto !important; max-width: 108px !important; min-width: 0 !important; padding-left: 8px !important; padding-right: 8px !important; }
    .task-context .context-icon { flex: 0 0 32px !important; width: 32px !important; min-width: 32px !important; }
    .tabs { width: 100% !important; max-width: 100% !important; min-width: 0 !important; }
    .content { width: 100% !important; max-width: 100% !important; min-width: 0 !important; }
    .chat { width: 100% !important; max-width: 100% !important; min-width: 0 !important; }
    .composer { left: 12px !important; right: auto !important; width: calc(100% - 24px) !important; max-width: none !important; margin: 0 !important; transform: none !important; }
    .composer input, .modal-card input, .more-command input { font-size: 16px !important; line-height: 22px !important; -webkit-text-size-adjust: 100%; }
    @media (min-width: 720px) {
      .shell { left: 50% !important; right: auto !important; width: min(100%, 1080px) !important; max-width: 1080px !important; margin: 0 !important; transform: translateX(-50%) !important; }
      .composer { left: 50% !important; right: auto !important; width: min(calc(100% - 56px), 952px) !important; transform: translateX(-50%) !important; }
    }
    /* iOS Safari can pan a flex document when its keyboard is presented even
       when the document has no page scroll. Pin the navigation chrome to the
       visual viewport in that mode and give the conversation its own bounded
       scrolling region. This keeps the task header, tabs, latest text, and
       composer on the same screen while typing. */
    @media (max-width: 719px) {
      .shell.vamp-keyboard-open { padding-top: 0 !important; }
      .shell.vamp-keyboard-open .top,
      .shell.vamp-keyboard-open .task-context,
      .shell.vamp-keyboard-open .tabs {
        position: fixed !important;
        left: 12px !important;
        right: 12px !important;
        width: auto !important;
        max-width: none !important;
        margin: 0 !important;
        background: rgba(255,255,255,.98) !important;
      }
      .shell.vamp-keyboard-open .top {
        top: max(44px, env(safe-area-inset-top)) !important;
        height: 54px !important;
        z-index: 12 !important;
      }
      .shell.vamp-keyboard-open .task-context {
        top: calc(max(44px, env(safe-area-inset-top)) + 54px) !important;
        height: 52px !important;
        z-index: 11 !important;
      }
      .shell.vamp-keyboard-open .tabs {
        top: calc(max(44px, env(safe-area-inset-top)) + 106px) !important;
        height: 64px !important;
        z-index: 10 !important;
      }
      .shell.vamp-keyboard-open .content {
        position: fixed !important;
        top: calc(max(44px, env(safe-area-inset-top)) + 170px) !important;
        left: 12px !important;
        right: 12px !important;
        bottom: 72px !important;
        width: auto !important;
        height: auto !important;
        max-width: none !important;
        overflow-x: hidden !important;
        overflow-y: auto !important;
        z-index: 1 !important;
      }
      .shell.vamp-keyboard-open .composer {
        z-index: 20 !important;
      }
    }
    /* Final viewport-canvas pass. Keep the layout document permanently locked
       and let only the content region scroll. WebKit otherwise scrolls the document to
       reveal a focused input even when overflow is hidden, which moves the
       complete task header above the visual viewport when the keyboard opens. */
    html {
      position: fixed !important;
      inset: 0 !important;
      width: 100% !important;
      height: 100% !important;
      overflow: hidden !important;
      overscroll-behavior: none !important;
    }
    body {
      position: fixed !important;
      inset: 0 !important;
      width: 100% !important;
      height: 100% !important;
      min-height: 0 !important;
      overflow: hidden !important;
      overscroll-behavior: none !important;
      touch-action: manipulation;
    }
    .shell {
      position: fixed !important;
      left: 0 !important;
      top: 0 !important;
      right: auto !important;
      bottom: auto !important;
      width: var(--vamp-visual-width, 100%) !important;
      height: var(--vamp-visual-height, 100dvh) !important;
      max-width: none !important;
      min-height: 0 !important;
      margin: 0 !important;
      transform: none !important;
      padding: env(safe-area-inset-top) clamp(12px, 3vw, 28px) env(safe-area-inset-bottom) !important;
      overflow: hidden !important;
    }
    .top, .task-context, .tabs {
      position: relative !important;
      top: auto !important;
      left: auto !important;
      right: auto !important;
      bottom: auto !important;
      width: 100% !important;
      transform: none !important;
    }
    .task-context .context-pill {
      flex: 0 0 76px !important;
      width: 76px !important;
      max-width: 76px !important;
      padding-left: 8px !important;
      padding-right: 8px !important;
    }
    .task-context .context-pill span {
      min-width: 0 !important;
      overflow: hidden !important;
      text-overflow: ellipsis !important;
      white-space: nowrap !important;
    }
    .content {
      position: relative !important;
      top: auto !important;
      left: auto !important;
      right: auto !important;
      bottom: auto !important;
      width: 100% !important;
      height: 0 !important;
      flex: 1 1 auto !important;
      min-height: 0 !important;
      overflow-x: hidden !important;
      overflow-y: auto !important;
      transform: none !important;
    }
    .composer {
      position: absolute !important;
      left: 12px !important;
      right: auto !important;
      bottom: max(10px, env(safe-area-inset-bottom)) !important;
      width: calc(100% - 24px) !important;
      max-width: none !important;
      margin: 0 !important;
      transform: none !important;
      z-index: 30 !important;
    }
    .modal {
      position: fixed !important;
      top: 0 !important;
      left: 0 !important;
      right: auto !important;
      bottom: auto !important;
      width: var(--vamp-visual-width, 100%) !important;
      height: var(--vamp-visual-height, 100dvh) !important;
      z-index: 50 !important;
    }
    @media (max-width: 520px) {
      .task-context { gap: 4px !important; }
      .task-context .workspace { font-size: 14px !important; }
      .task-context .context-pill { flex-basis: 66px !important; width: 66px !important; max-width: 66px !important; }
      .task-context .context-pill span { font-size: 12px !important; }
      .task-context .context-icon { flex-basis: 30px !important; width: 30px !important; min-width: 30px !important; }
    }
    @media (min-width: 720px) {
      .shell {
        left: 50% !important;
        width: min(var(--vamp-visual-width, 100%), 1080px) !important;
        transform: translateX(-50%) !important;
      }
      .composer {
        left: 50% !important;
        width: min(calc(100% - 56px), 952px) !important;
        transform: translateX(-50%) !important;
      }
    }
    @media (max-width: 719px) {
      .shell.vamp-keyboard-open { padding-top: env(safe-area-inset-top) !important; }
      .shell.vamp-keyboard-open .top,
      .shell.vamp-keyboard-open .task-context,
      .shell.vamp-keyboard-open .tabs,
      .shell.vamp-keyboard-open .content {
        position: relative !important;
        top: auto !important;
        left: auto !important;
        right: auto !important;
        bottom: auto !important;
        width: 100% !important;
        transform: none !important;
      }
      .shell.vamp-keyboard-open .content {
        height: 0 !important;
        flex: 1 1 auto !important;
        min-height: 0 !important;
        overflow-x: hidden !important;
        overflow-y: auto !important;
      }
      .shell.vamp-keyboard-open .composer { position: absolute !important; z-index: 30 !important; }
    }
    /* Final chat projection contract: one stacking context, one scroll owner,
       and a visual hierarchy that reads like a task conversation instead of
       a terminal window. */
    :root {
      --vamp-z-content: 1;
      --vamp-z-chrome: 10;
      --vamp-z-composer: 30;
      --vamp-z-menu: 40;
      --vamp-z-modal: 50;
    }
    .shell { isolation: isolate !important; }
    .top, .task-context, .tabs { z-index: var(--vamp-z-chrome) !important; }
    .tabs { padding-right: 12px !important; }
    .tabs > .tab, .tabs > .newtab { flex: 0 0 auto; }
    .content { z-index: var(--vamp-z-content) !important; touch-action: pan-y; }
    .composer { z-index: var(--vamp-z-composer) !important; }
    .clipboard-menu { z-index: var(--vamp-z-menu) !important; }
    .modal { z-index: var(--vamp-z-modal) !important; }
    .message, .command-card, .stream-card, .explore-row { width: 100%; min-width: 0; }
    .message.ready-message.status-chip {
      display: flex !important;
      align-items: center;
      gap: 8px;
      width: fit-content;
      max-width: min(100%, 360px);
      margin: 12px 0 20px auto !important;
      padding: 9px 13px;
      border: 1px solid rgba(66,211,146,.25);
      border-radius: 999px;
      background: rgba(66,211,146,.10);
      color: #d7f7e7;
      font-size: 13px;
      font-weight: 650;
      line-height: 1.25;
    }
    .message.ready-message .check { color: var(--good); font-size: 16px; line-height: 1; }
    .stream-card.output-message {
      padding: 0;
      border-color: transparent;
      background: transparent;
      box-shadow: none;
    }
    .stream-card.output-message:not(.structured-output) .rich-body {
      padding-left: 37px;
    }
    .stream-card.output-message:not(.structured-output) .rich-body p {
      color: #f0f0f0;
      font-size: 16px;
      line-height: 1.62;
    }
    .stream-card.output-message.structured-output {
      padding: 16px;
      border-color: var(--vamp-border);
      background: linear-gradient(145deg, rgba(45,45,45,.78), rgba(25,25,25,.90));
      box-shadow: 0 16px 44px rgba(0,0,0,.20), inset 0 1px 0 rgba(255,255,255,.045);
    }
    .stream-card.output-message.structured-output .rich-body { margin-top: 12px; }
    .rich-body .rich-code, .rich-body .rich-box, .rich-body .rich-table-wrap {
      max-width: 100%;
      overflow-x: auto;
      -webkit-overflow-scrolling: touch;
    }
    .rich-body .rich-code, .rich-body .rich-box { white-space: pre-wrap; overflow-wrap: anywhere; }
    @media (max-width: 719px) {
      html, body { overscroll-behavior: none !important; }
      .content { overscroll-behavior-y: contain !important; }
      .stream-card.output-message:not(.structured-output) .rich-body { padding-left: 0; }
    }
  `;
  document.head.appendChild(style);

  const modeStyle = document.createElement('style');
  modeStyle.textContent = `
    .mode-switch {
      flex: 0 0 46px;
      min-height: 46px;
      display: flex;
      align-items: center;
      justify-content: flex-end;
      gap: 2px;
      padding: 6px 0;
      border-bottom: 1px solid var(--line);
    }
    .mode-switch button {
      min-height: 34px;
      padding: 0 13px;
      border-radius: 11px;
      background: transparent;
      color: #8e8e8e;
      font-size: 13px;
      font-weight: 650;
    }
    .mode-switch button[aria-pressed="true"] {
      background: rgba(255,255,255,.13);
      color: #f4f4f4;
      box-shadow: inset 0 1px 0 rgba(255,255,255,.08);
    }
    .mode-switch button:focus-visible,
    .terminal-keybar button:focus-visible,
    .open-terminal-preview:focus-visible {
      outline: 2px solid rgba(255,255,255,.72);
      outline-offset: 2px;
    }
    .terminal-keybar {
      display: none;
      position: absolute;
      left: 12px;
      right: 12px;
      bottom: 76px;
      z-index: 29;
      gap: 7px;
      overflow-x: auto;
      padding: 5px 0;
      scrollbar-width: none;
    }
    .terminal-keybar::-webkit-scrollbar { display: none; }
    .terminal-keybar button {
      flex: 0 0 auto;
      min-width: 44px;
      min-height: 38px;
      padding: 0 11px;
      border: 1px solid rgba(255,255,255,.11);
      border-radius: 11px;
      background: rgba(48,48,48,.94);
      color: #e7e7e7;
      font: 12px ui-monospace, SFMono-Regular, Menlo, monospace;
    }
    body.vamp-terminal-mode .terminal-keybar { display: flex; }
    body.vamp-terminal-mode .chat {
      display: flex !important;
      flex-direction: column;
      height: 100% !important;
      min-height: 0 !important;
      padding: 12px 0 96px !important;
    }
    body.vamp-terminal-mode .chat > .message:not(.stream-card),
    body.vamp-terminal-mode .chat > .command-card,
    body.vamp-terminal-mode .chat > .explore-row {
      display: none !important;
    }
    body.vamp-terminal-mode .stream-card.output-message {
      display: flex !important;
      flex: 1 1 auto;
      flex-direction: column;
      width: 100%;
      max-width: none;
      min-height: 0;
      margin: 0;
      padding: 12px;
      border-color: rgba(255,255,255,.14);
      border-radius: 16px;
      background: #080808;
      box-shadow: none;
    }
    body.vamp-terminal-mode .stream-card.output-message .rich-body {
      flex: 1 1 auto;
      min-height: 0;
      max-height: none !important;
      overflow: auto;
      border: 1px solid rgba(255,255,255,.10);
      border-radius: 11px;
      background: #080808;
      padding: 10px;
    }
    body.vamp-terminal-mode .stream-card.output-message .terminal-row {
      min-height: 1.4em;
      font-size: 14px;
      line-height: 1.4;
    }
    body.vamp-terminal-mode .stream-card.output-message .stream-caption { margin-bottom: 9px; }
    body:not(.vamp-terminal-mode) .stream-card.output-message { max-height: none; overflow: visible; }
    body:not(.vamp-terminal-mode) .stream-card.output-message .rich-body {
      max-height: none;
      overflow: visible;
      pointer-events: auto;
    }
    .open-terminal-preview {
      flex: 0 0 auto;
      min-height: 30px;
      padding: 0 9px;
      border: 1px solid rgba(255,255,255,.12);
      border-radius: 9px;
      background: rgba(255,255,255,.08);
      color: #d8d8d8;
      font-size: 11px;
      font-weight: 650;
    }
    @media (max-width: 520px) {
      .mode-switch { flex-basis: 44px; min-height: 44px; }
      .mode-switch button { padding: 0 10px; font-size: 12px; }
      .terminal-keybar { left: 12px; right: 12px; }
    }

    /* Mobile layout contract: the terminal surface owns the flexible middle
       of the viewport. The key rail and composer are siblings in normal flow
       so they can never paint over a terminal row when Safari changes the
       visual viewport for its keyboard. */
    .shell {
      display: flex !important;
      flex-direction: column !important;
      left: var(--vamp-vv-left, 0px) !important;
      top: var(--vamp-vv-top, 0px) !important;
      height: var(--vamp-visual-height, 100dvh) !important;
      min-height: 0 !important;
      padding-bottom: 0 !important;
    }
    .content {
      flex: 1 1 0 !important;
      height: auto !important;
      min-height: 0 !important;
    }
    .chat {
      min-height: 0 !important;
      height: auto !important;
      padding-bottom: 18px !important;
    }
    .chat > [data-tab-id].vamp-tab-hidden {
      display: none !important;
    }
    .terminal-keybar {
      position: static !important;
      flex: 0 0 auto !important;
      width: 100% !important;
      min-height: 48px;
      margin: 0 !important;
      padding: 5px 0 4px !important;
      z-index: auto !important;
    }
    .composer {
      position: static !important;
      flex: 0 0 auto !important;
      width: calc(100% - 24px) !important;
      margin: 0 12px max(8px, env(safe-area-inset-bottom)) !important;
      left: auto !important;
      right: auto !important;
      bottom: auto !important;
      transform: none !important;
      z-index: auto !important;
    }
    /* A legacy keyboard rule targets the more-specific
       .shell.vamp-keyboard-open .composer selector. Match that specificity so
       the composer remains the final normal-flow sibling of the key rail when
       Safari presents the keyboard; otherwise it paints back over the VT
       surface and the key rail. */
    .shell.vamp-keyboard-open .composer {
      position: static !important;
      left: auto !important;
      right: auto !important;
      bottom: auto !important;
      width: calc(100% - 24px) !important;
      margin: 0 12px max(8px, env(safe-area-inset-bottom)) !important;
      transform: none !important;
    }
            .modal {
                /* The fixed shell already follows visualViewport.pageLeft /
                   pageTop. Applying those offsets to its modal child again
                   double-pans the card above the iOS keyboard. */
                left: 0 !important;
                top: 0 !important;
                width: 100% !important;
                height: 100% !important;
            }
            .shell.vamp-keyboard-open .modal {
                align-items: flex-start !important;
                overflow: hidden !important;
                /* WebKit positions a fixed descendant in the already-panned
                   shell coordinate space. Counter that parent pan so the
                   pairing card begins inside the visible keyboard viewport. */
                top: calc(-1 * var(--vamp-vv-top, 0px)) !important;
                padding-top: max(10px, env(safe-area-inset-top)) !important;
                padding-bottom: 10px !important;
            }
            .shell.vamp-keyboard-open .modal-card {
                max-height: 100% !important;
                /* The pairing card fits in the portrait keyboard viewport.
                   Keeping it scrollable lets WebKit pan its contents to the
                   focused field and hide the title; lock that internal
                   viewport while the keyboard is present. */
                overflow-y: hidden !important;
                overscroll-behavior: contain;
                padding: 14px 18px !important;
                /* WebKit applies a final focus-reveal pan after visualViewport
                   has settled. Reserve a small top rail so the title remains
                   visible instead of landing behind Safari's status area. */
                transform: translateY(64px) !important;
            }
            /* Keep the focused pairing control and its title in one compact
               keyboard viewport. Safari otherwise scrolls the explanatory
               paragraph above the visual viewport while revealing the
               number pad, making the dialog appear broken. The full copy is
               restored as soon as the keyboard closes. */
            .shell.vamp-keyboard-open .modal-card p {
                display: none !important;
            }
            .shell.vamp-keyboard-open .modal-card h2 {
                margin-bottom: 10px !important;
            }
            .shell.vamp-keyboard-open .modal-card .error:empty {
                display: none !important;
            }
    body.vamp-terminal-mode .chat {
      display: flex !important;
      flex: 1 1 auto !important;
      height: 100% !important;
      min-height: 0 !important;
      padding: 10px 0 !important;
    }
    body.vamp-terminal-mode .content {
      display: flex !important;
      flex-direction: column !important;
      overflow: hidden !important;
    }
    body.vamp-terminal-mode .stream-card.output-message {
      min-height: 0 !important;
      padding: 0 !important;
      border: 0 !important;
      border-radius: 0 !important;
      background: transparent !important;
    }
    /* The full Terminal projection must not keep presenting itself as the
       compact read-only Chat preview. Session identity already lives in the
       selected tab, so give the VT surface every remaining row. */
    body.vamp-terminal-mode .stream-card-head,
    body.vamp-terminal-mode .stream-caption,
    body.vamp-terminal-mode .open-terminal-preview {
      display: none !important;
    }
    body.vamp-terminal-mode .stream-card.output-message .rich-body {
      border-radius: 12px !important;
    }
    body.vamp-terminal-mode .chat > [data-tab-id].vamp-tab-hidden {
      display: none !important;
    }
    @media (min-width: 720px) {
      .composer {
        width: min(calc(100% - 56px), 952px) !important;
        margin: 0 auto 12px !important;
      }
      .terminal-keybar {
        width: min(calc(100% - 56px), 952px) !important;
        margin: 0 auto !important;
      }
    }
    @media (max-width: 719px) {
      /* Keyboard focus must not swap the page into a second hierarchy. Hiding
         the workspace and tabs on focus made every Safari keyboard frame
         reflow the entire task surface, which users saw as image flutter.
         The visual viewport already supplies the available height; flexbox
         only needs to redistribute that height among the same children. */
      .shell.vamp-keyboard-open .top { flex-basis: 54px !important; min-height: 54px !important; }
      .shell.vamp-keyboard-open .task-context { display: flex !important; }
      .shell.vamp-keyboard-open .tabs { display: flex !important; }
      .shell.vamp-keyboard-open .mode-switch { flex-basis: 46px !important; min-height: 46px !important; }
      .shell.vamp-keyboard-open .content { overflow-x: hidden !important; overflow-y: auto !important; }
      /* The middle viewport shrinks naturally. Do not also resize response
         cards on focus: that second geometry change made the conversation
         jump before Safari had finished presenting its keyboard. */
    }
  `;
  document.head.appendChild(modeStyle);

  // One final design system owns the browser-control surface. Earlier rules
  // remain as compatibility fallbacks for older WebKit builds, but this layer
  // deliberately resolves their competing fixed/absolute layout models into
  // a single flex hierarchy with one scrolling region.
  const browserControlDesign = document.createElement('style');
  browserControlDesign.textContent = `
    :root {
      --bc-page: #FFFFFF;
      --bc-panel: #FFFFFF;
      --bc-panel-strong: #FFFFFF;
      --bc-raised: #F4F4F5;
      --bc-track: #F4F4F5;
      --bc-line: #E4E4E7;
      --bc-line-strong: #D4D4D8;
      --bc-text: #18181B;
      --bc-secondary: #71717A;
      --bc-tertiary: #A1A1AA;
      --bc-shadow: 0 1px 2px rgba(0,0,0,.06);
      --bc-radius: 14px;
      --bc-control-radius: 12px;
      --bc-page-inset: clamp(14px, 3vw, 28px);
      --bc-readable: 820px;
    }

    html, body {
      background: var(--bc-page) !important;
      color: var(--bc-text) !important;
    }
    body {
      background-image: none !important;
    }
    button { -webkit-tap-highlight-color: transparent; }
    button:active { transform: scale(.975); }

    .shell,
    .shell.vamp-keyboard-open {
      display: flex !important;
      flex-direction: column !important;
      width: min(var(--vamp-visual-width, 100%), 1120px) !important;
      height: var(--vamp-visual-height, 100dvh) !important;
      padding: env(safe-area-inset-top) var(--bc-page-inset) 0 !important;
      background: var(--bc-page) !important;
      overflow: hidden !important;
    }

    .top {
      flex: 0 0 58px !important;
      height: 58px !important;
      gap: 10px !important;
      border: 0 !important;
      background: transparent !important;
    }
    .back {
      display: grid !important;
      place-items: center !important;
      width: 40px !important;
      min-width: 40px !important;
      height: 40px !important;
      border: 1px solid var(--bc-line) !important;
      border-radius: 12px !important;
      background: #FFFFFF !important;
      color: #3F3F46 !important;
      font-size: 23px !important;
      box-shadow: none !important;
    }
    .title {
      font-size: 16px !important;
      font-weight: 700 !important;
      letter-spacing: -.015em !important;
    }
    .top .state {
      display: inline-flex !important;
      align-items: center !important;
      min-height: 34px !important;
      margin-left: auto !important;
      padding: 0 4px !important;
      border: 0 !important;
      border-radius: 0 !important;
      background: transparent !important;
      color: var(--bc-secondary) !important;
      font-size: 13px !important;
    }

    .task-context {
      flex: 0 0 46px !important;
      min-height: 46px !important;
      gap: 6px !important;
      border: 0 !important;
      border-top: 1px solid var(--bc-line) !important;
    }
    .task-context .workspace {
      font-size: 13px !important;
      font-weight: 670 !important;
      color: var(--bc-text) !important;
    }
    .context-pill, .context-icon {
      min-height: 32px !important;
      border-color: var(--bc-line) !important;
      border-radius: 10px !important;
      background: var(--bc-raised) !important;
      color: var(--bc-secondary) !important;
    }

    .tabs {
      flex: 0 0 56px !important;
      min-height: 56px !important;
      gap: 7px !important;
      padding: 7px 0 !important;
      border-top: 1px solid var(--bc-line) !important;
      scroll-padding-inline: 8px 58px !important;
    }
    .tab {
      min-height: 40px !important;
      padding: 0 12px !important;
      border: 1px solid var(--bc-line) !important;
      border-radius: 12px !important;
      background: #FFFFFF !important;
      color: #3F3F46 !important;
      font-size: 13px !important;
      font-weight: 620 !important;
      box-shadow: none !important;
    }
    .tab.active {
      border-color: var(--bc-text) !important;
      background: var(--bc-text) !important;
      color: #FFFFFF !important;
      box-shadow: none !important;
    }
    .tab.active::after {
      content: none !important;
    }
    .tab { position: relative; }
    .tab .close { min-width: 22px; min-height: 22px; color: var(--bc-tertiary) !important; }
    .tab.active .close { color: rgba(255,255,255,.72) !important; }
    .newtab {
      position: sticky !important;
      right: 0 !important;
      z-index: 3 !important;
      flex: 0 0 44px !important;
      width: 44px !important;
      min-width: 44px !important;
      min-height: 40px !important;
      padding: 0 !important;
      border: 1px solid var(--bc-line) !important;
      border-radius: 12px !important;
      background: #FFFFFF !important;
      box-shadow: none !important;
      font-size: 21px !important;
      color: #3F3F46 !important;
    }

    .mode-switch {
      flex: 0 0 48px !important;
      min-height: 48px !important;
      justify-content: flex-end !important;
      gap: 3px !important;
      padding: 6px 0 !important;
      border: 0 !important;
    }
    .mode-switch button {
      min-height: 36px !important;
      padding: 0 13px !important;
      border-radius: 10px !important;
      color: var(--bc-secondary) !important;
      font-size: 12px !important;
    }
    .mode-switch button[aria-pressed="true"] {
      border: 1px solid var(--bc-line) !important;
      background: #FFFFFF !important;
      color: var(--bc-text) !important;
      box-shadow: var(--bc-shadow) !important;
    }

    .content {
      flex: 1 1 0 !important;
      width: 100% !important;
      height: auto !important;
      min-height: 0 !important;
      border-top: 1px solid var(--bc-line) !important;
      overflow-x: hidden !important;
      overflow-y: auto !important;
      scrollbar-gutter: stable !important;
    }
    .chat {
      width: min(100%, var(--bc-readable)) !important;
      min-height: 100% !important;
      margin: 0 auto !important;
      padding: 18px 2px 22px !important;
    }
    .empty {
      display: grid !important;
      place-items: center !important;
      min-height: min(46vh, 360px) !important;
      padding: 32px 18px !important;
      color: var(--bc-tertiary) !important;
    }
    .empty[hidden] { display: none !important; }
    .message { margin-bottom: 20px !important; }
    .message .meta { color: var(--bc-secondary) !important; }
    .message.system-message .body { color: var(--bc-secondary) !important; }
    .message .body { color: var(--bc-text) !important; font-size: 15px !important; line-height: 1.6 !important; }
    .explore-row { margin: 12px auto 16px !important; }
    .explore-row .explore-icon { color: var(--bc-tertiary) !important; }

    .stream-card,
    .stream-card.output-message.structured-output,
    .command-card,
    .task-plan-card {
      border: 1px solid var(--bc-line) !important;
      border-radius: var(--bc-radius) !important;
      background: var(--bc-panel) !important;
      box-shadow: var(--bc-shadow) !important;
    }
    .stream-card { padding: 15px !important; margin: 8px auto 22px !important; }
    .stream-card.output-message:not(.structured-output) {
      padding: 15px !important;
      border-color: var(--bc-line) !important;
      background: var(--bc-panel) !important;
    }
    .stream-card-head { min-height: 34px !important; }
    .stream-caption { margin: 7px 0 10px 37px !important; }
    body:not(.vamp-terminal-mode) .stream-card.output-message .rich-body {
      max-height: none !important;
      padding: 0 0 2px 37px !important;
      overflow: visible !important;
      mask-image: none !important;
    }
    body:not(.vamp-terminal-mode) .stream-card.output-message.structured-output .rich-body {
      padding-left: 0 !important;
      mask-image: none !important;
    }
    .open-terminal-preview {
      min-height: 32px !important;
      padding: 0 11px !important;
      border-radius: 10px !important;
      background: var(--bc-raised) !important;
      border-color: var(--bc-line) !important;
      color: var(--bc-secondary) !important;
    }

    /* Rich content in cards: light code fences and tables, dark terminal rows stay dark. */
    .rich-code, .rich-box { background: var(--bc-raised) !important; border-color: var(--bc-line) !important; color: var(--bc-text) !important; }
    .rich-code .code-language { color: var(--bc-tertiary) !important; }
    .rich-table-wrap { background: var(--bc-raised) !important; border-color: var(--bc-line) !important; }
    .rich-table th { background: var(--bc-track) !important; color: var(--bc-text) !important; border-color: var(--bc-line) !important; }
    .rich-table td { color: var(--bc-text) !important; border-color: var(--bc-line) !important; }
    .rich-step { border-left-color: var(--bc-line-strong) !important; color: var(--bc-text) !important; }
    .rich-step.good { background: rgba(34,197,94,.07) !important; }
    .rich-step.warn { background: rgba(245,158,11,.08) !important; }
    .rich-step.bad { background: rgba(239,68,68,.07) !important; }
    .rich-empty { color: var(--bc-tertiary) !important; }

    .command-card { padding: 16px !important; }
    .command-card .command { background: var(--bc-raised) !important; border-color: var(--bc-line) !important; color: var(--bc-text) !important; }
    .approval-actions { grid-template-columns: 1fr !important; }
    .approval-choice { min-height: 52px !important; border-radius: 12px !important; }
    .approval-choice.selected {
      border-color: var(--bc-line-strong) !important;
      background: var(--bc-raised) !important;
    }
    .approval-footer .confirm { min-height: 46px !important; border-radius: 12px !important; }

    /* Ready chip: flat green-tinted pill. */
    .message.ready-message.status-chip {
      background: rgba(34,197,94,.08) !important;
      border-color: rgba(34,197,94,.28) !important;
      color: #15803D !important;
    }

    .terminal-keybar {
      display: none !important;
      visibility: hidden !important;
      height: 0 !important;
      min-height: 0 !important;
      padding: 0 !important;
      overflow: hidden !important;
      flex: 0 0 auto !important;
      width: min(100%, var(--bc-readable)) !important;
      margin: 0 auto !important;
      gap: 7px !important;
    }
    .terminal-keybar button {
      min-height: 38px !important;
      border-color: var(--bc-line) !important;
      background: var(--bc-panel-strong) !important;
      color: var(--bc-text) !important;
    }
    body.vamp-terminal-mode .terminal-keybar {
      display: flex !important;
      visibility: visible !important;
      height: auto !important;
      min-height: 48px !important;
      padding: 5px 0 !important;
      overflow-x: auto !important;
      overflow-y: hidden !important;
    }
    body:not(.vamp-terminal-mode) #terminal-keybar {
      display: none !important;
      visibility: hidden !important;
      position: fixed !important;
      width: 0 !important;
      height: 0 !important;
      min-height: 0 !important;
      padding: 0 !important;
      margin: 0 !important;
      clip-path: inset(100%) !important;
      pointer-events: none !important;
    }
    .composer,
    .shell.vamp-keyboard-open .composer {
      flex: 0 0 auto !important;
      width: min(calc(100% - 8px), var(--bc-readable)) !important;
      min-height: 60px !important;
      height: 60px !important;
      margin: 4px auto max(10px, env(safe-area-inset-bottom)) !important;
      padding: 7px !important;
      gap: 6px !important;
      border: 1px solid var(--bc-line-strong) !important;
      border-radius: 16px !important;
      background: var(--bc-panel-strong) !important;
      box-shadow: 0 1px 3px rgba(0,0,0,.07) !important;
      backdrop-filter: none !important;
    }
    .composer input { font-size: 16px !important; }
    .composer button {
      flex: 0 0 44px !important;
      width: 44px !important;
      height: 44px !important;
      border-radius: 12px !important;
      background: var(--bc-raised) !important;
      color: var(--bc-text) !important;
    }
    .composer .send {
      background: var(--bc-text) !important;
      color: var(--bc-page) !important;
      border-radius: 50% !important;
    }

    .clipboard-menu {
      background: var(--bc-panel-strong) !important;
      border: 1px solid var(--bc-line) !important;
      border-radius: 14px !important;
      box-shadow: 0 16px 44px rgba(0,0,0,.14) !important;
      backdrop-filter: none !important;
    }
    .clipboard-menu button { color: var(--bc-text) !important; }
    .clipboard-menu button:hover, .clipboard-menu button:focus-visible { background: var(--bc-raised) !important; }

    body.vamp-terminal-mode .content { border-top-color: transparent !important; }
    body.vamp-terminal-mode .chat { padding: 8px 0 !important; }
    body.vamp-terminal-mode .stream-card.output-message {
      border: 1px solid var(--bc-line) !important;
      border-radius: var(--bc-radius) !important;
      background: #050505 !important;
      padding: 8px !important;
    }
    body.vamp-terminal-mode .stream-card.output-message .rich-body {
      border: 0 !important;
      border-radius: 12px !important;
      background: #050505 !important;
      padding: 10px !important;
    }

    .dashboard { padding: 24px 0 32px !important; }
    .dashboard-heading { align-items: center !important; }
    .dashboard-heading p { color: var(--bc-secondary) !important; }
    .dashboard-kicker { color: var(--bc-tertiary) !important; }
    .dashboard-open, .session-card-action { border-radius: 12px !important; }
    .dashboard-open {
      background: var(--bc-text) !important;
      border: 1px solid var(--bc-text) !important;
      color: var(--bc-page) !important;
    }
    .session-card-action {
      background: #FFFFFF !important;
      border: 1px solid var(--bc-line) !important;
      color: var(--bc-text) !important;
    }
    .host-card, .session-card {
      border-color: var(--bc-line) !important;
      background: var(--bc-panel) !important;
      box-shadow: var(--bc-shadow) !important;
    }
    .host-card p, .session-card-meta { color: var(--bc-secondary) !important; }
    .dashboard-empty { border-color: var(--bc-line-strong) !important; color: var(--bc-secondary) !important; }
    .session-grid { grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)) !important; }

    .modal {
      padding: 18px !important;
      background: rgba(24,24,27,.4) !important;
      backdrop-filter: none !important;
    }
    .modal-card,
    .shell.vamp-keyboard-open .modal-card {
      width: min(460px, 100%) !important;
      max-height: min(760px, calc(100% - 24px)) !important;
      padding: 20px !important;
      border: 1px solid var(--bc-line) !important;
      border-radius: 20px !important;
      background: var(--bc-panel-strong) !important;
      box-shadow: 0 24px 64px rgba(0,0,0,.16) !important;
      overflow-y: auto !important;
      transform: none !important;
    }
    .modal-card h2 { font-size: 20px !important; letter-spacing: -.025em !important; color: var(--bc-text) !important; }
    .modal-card p { color: var(--bc-secondary) !important; }
    .modal-card input { background: var(--bc-page) !important; border-color: var(--bc-line-strong) !important; color: var(--bc-text) !important; }
    .modal-card .more-command input { letter-spacing: 0 !important; text-align: left !important; }
    .more-kicker { color: var(--bc-tertiary) !important; }
    .workspace-list { gap: 8px !important; }
    .workspace-choice {
      min-height: 60px !important;
      border-radius: 12px !important;
      background: var(--bc-raised) !important;
      border: 1px solid var(--bc-line) !important;
      color: var(--bc-text) !important;
    }
    .workspace-choice small { color: var(--bc-secondary) !important; }
    .provider-title { color: var(--bc-tertiary) !important; }
    .more-actions button, .provider-grid button {
      background: var(--bc-raised) !important;
      border: 1px solid var(--bc-line) !important;
      border-radius: 12px !important;
      color: var(--bc-text) !important;
    }
    .more-actions button:hover, .more-actions button:focus-visible,
    .provider-grid button:hover, .provider-grid button:focus-visible {
      background: var(--bc-track) !important;
    }
    .more-actions button.secondary { background: #FFFFFF !important; color: var(--bc-text) !important; }
    .more-footer .secondary { background: var(--bc-raised) !important; color: var(--bc-text) !important; }
    .more-footer button { border-radius: 12px !important; }
    .more-footer .appearance-toggle { border: 1px solid var(--bc-line) !important; }
    .provider-grid { grid-template-columns: repeat(2, minmax(0,1fr)) !important; }
    .provider-grid button { min-height: 48px !important; border-radius: 12px !important; }
    .provider-logo {
      flex: 0 0 30px !important;
      width: 30px !important;
      height: 30px !important;
      border: 1px solid color-mix(in srgb, var(--provider) 42%, transparent) !important;
      border-radius: 9px !important;
      object-fit: cover !important;
      background: color-mix(in srgb, var(--provider) 12%, transparent) !important;
      box-shadow: none !important;
    }
    .appearance-toggle { margin-right: auto !important; }

    html[data-resolved-theme="dark"] {
      color-scheme: dark;
      --bg: #09090B;
      --panel: #18181B;
      --panel2: #101013;
      --line: rgba(255,255,255,.12);
      --muted: #A1A1AA;
      --text: #FAFAFA;
      --accent: #FAFAFA;
      --bc-page: #09090B;
      --bc-panel: #18181B;
      --bc-panel-strong: #1C1C1F;
      --bc-raised: #27272A;
      --bc-track: #1C1C1F;
      --bc-line: rgba(255,255,255,.12);
      --bc-line-strong: rgba(255,255,255,.22);
      --bc-text: #FAFAFA;
      --bc-secondary: #A1A1AA;
      --bc-tertiary: #71717A;
      --bc-shadow: 0 1px 2px rgba(0,0,0,.4);
    }
    html[data-resolved-theme="dark"] .back,
    html[data-resolved-theme="dark"] .tab,
    html[data-resolved-theme="dark"] .newtab,
    html[data-resolved-theme="dark"] .mode-switch button[aria-pressed="true"],
    html[data-resolved-theme="dark"] .session-card-action,
    html[data-resolved-theme="dark"] .more-actions button.secondary { background: var(--bc-panel) !important; }
    html[data-resolved-theme="dark"] .tab.active { background: var(--bc-text) !important; border-color: var(--bc-text) !important; color: var(--bc-page) !important; }
    html[data-resolved-theme="dark"] .tab.active .close { color: var(--bc-page) !important; }
    html[data-resolved-theme="dark"] .message.ready-message.status-chip { color: #86EFAC !important; }
    html[data-resolved-theme="dark"] .rich-step,
    html[data-resolved-theme="dark"] .rich-table td,
    html[data-resolved-theme="dark"] .rich-table th { color: var(--bc-text) !important; }

    @media (min-width: 720px) {
      .shell,
      .shell.vamp-keyboard-open {
        left: 50% !important;
        right: auto !important;
        transform: translateX(-50%) !important;
      }
    }

    @media (min-width: 900px) {
      .shell,
      .shell.vamp-keyboard-open {
        /* Desktop geometry must not inherit VisualViewport values captured
           while Chrome was narrow, zoomed, or restoring a mobile-sized
           window. Normal-flow centering also avoids the left-half clipping
           caused by competing left/translate overrides in older layers. */
        left: 0 !important;
        right: 0 !important;
        width: min(calc(100vw - 80px), 1120px) !important;
        max-width: 1120px !important;
        margin-inline: auto !important;
        transform: none !important;
        top: 0 !important;
        height: 100dvh !important;
        border: 0 !important;
        border-radius: 0 !important;
        box-shadow: none !important;
      }
      .top { flex-basis: 60px !important; height: 60px !important; }
      .task-context { padding-inline: 4px !important; }
      .composer, .shell.vamp-keyboard-open .composer { margin-bottom: 14px !important; }
    }

    @media (max-width: 719px) {
      :root { --bc-page-inset: 14px; --bc-radius: 16px; }
      .shell, .shell.vamp-keyboard-open {
        left: var(--vamp-vv-left, 0px) !important;
        top: var(--vamp-vv-top, 0px) !important;
        width: var(--vamp-visual-width, 100%) !important;
        padding-top: max(env(safe-area-inset-top), 8px) !important;
      }
      .top, .shell.vamp-keyboard-open .top { flex-basis: 52px !important; height: 52px !important; min-height: 52px !important; }
      .back { width: 36px !important; min-width: 36px !important; height: 36px !important; border-radius: 12px !important; }
      .top .state { min-height: 32px !important; padding: 0 9px !important; }
      .task-context { flex-basis: 42px !important; min-height: 42px !important; }
      .task-context .workspace { font-size: 12px !important; }
      .context-pill { flex-basis: 64px !important; width: 64px !important; max-width: 64px !important; }
      .context-icon { flex-basis: 30px !important; width: 30px !important; min-width: 30px !important; min-height: 32px !important; }
      .tabs, .shell.vamp-keyboard-open .tabs { flex-basis: 52px !important; min-height: 52px !important; padding: 5px 0 !important; }
      .tab { min-height: 40px !important; }
      .newtab { min-height: 40px !important; }
      .mode-switch, .shell.vamp-keyboard-open .mode-switch { flex-basis: 44px !important; min-height: 44px !important; }
      .chat { padding: 14px 0 18px !important; }
      .stream-card { padding: 13px !important; }
      .stream-card-actions { gap: 5px !important; }
      .stream-state { font-size: 10px !important; }
      body:not(.vamp-terminal-mode) .stream-card.output-message .rich-body {
        max-height: none !important;
        overflow: visible !important;
        padding-left: 0 !important;
      }
      .stream-caption { margin-left: 0 !important; }
      .terminal-keybar { width: 100% !important; }
      .composer, .shell.vamp-keyboard-open .composer {
        width: 100% !important;
        margin: 4px 0 max(8px, env(safe-area-inset-bottom)) !important;
        border-radius: 17px !important;
      }
      .clipboard-label { display: none !important; }
      .modal { align-items: flex-end !important; padding: 10px !important; }
      .shell.vamp-keyboard-open .modal { align-items: flex-end !important; top: 0 !important; padding: 10px !important; }
      .modal-card, .shell.vamp-keyboard-open .modal-card {
        width: 100% !important;
        max-height: min(86dvh, calc(100% - 8px)) !important;
        padding: 18px !important;
        border-radius: 24px !important;
        overflow-y: auto !important;
      }
      .shell.vamp-keyboard-open .modal-card p { display: block !important; }
      .provider-grid { grid-template-columns: repeat(2, minmax(0,1fr)) !important; }
      .dashboard { padding-top: 18px !important; }
      .dashboard-heading { display: block !important; }
      .dashboard-open { width: 100% !important; margin-top: 14px !important; }
      .session-grid { grid-template-columns: 1fr !important; }
    }

    /* Mobile browser control is one continuous task surface. Older style
       layers positioned the mode selector and composer like loose overlays,
       which left an empty band and made the controls feel detached. */
    @media (max-width: 719px) {
      .mode-switch,
      .shell.vamp-keyboard-open .mode-switch {
        width: 100% !important;
        justify-content: stretch !important;
        gap: 4px !important;
        margin: 0 !important;
        padding: 4px !important;
        border: 1px solid var(--bc-line) !important;
        border-radius: 14px !important;
        background: rgba(255,255,255,.035) !important;
      }
      .mode-switch button {
        flex: 1 1 0 !important;
        min-width: 0 !important;
        padding-inline: 10px !important;
      }
      .mode-switch,
      .shell.vamp-keyboard-open .mode-switch {
        width: 100% !important;
        justify-content: stretch !important;
        gap: 4px !important;
        margin: 0 !important;
        padding: 4px !important;
        border: 1px solid var(--bc-line) !important;
        border-radius: 14px !important;
        background: var(--bc-track) !important;
      }
      .content { border-top: 0 !important; }
      .empty { min-height: 210px !important; }
      .composer,
      .shell.vamp-keyboard-open .composer {
        position: relative !important;
        inset: auto !important;
        flex: 0 0 60px !important;
      }
    }

    @media (max-height: 600px) and (max-width: 719px) {
      .task-context { display: none !important; }
      .tabs { flex-basis: 46px !important; min-height: 46px !important; }
      .mode-switch { flex-basis: 40px !important; min-height: 40px !important; }
      .chat { padding-top: 8px !important; }
      body:not(.vamp-terminal-mode) .stream-card.output-message .rich-body { max-height: none !important; overflow: visible !important; }
    }

    /* When the iOS keyboard opens, the visible viewport is roughly half the
       screen. The workspace row and tab strip are not needed while typing;
       collapsing them returns that height to the conversation so the composer
       never floats over chat content and the latest message stays readable
       above the keyboard. The mode switch and composer remain in normal flow. */
    @media (max-width: 719px) {
      .shell.vamp-keyboard-open .task-context,
      .shell.vamp-keyboard-open .tabs {
        flex: 0 0 0 !important;
        min-height: 0 !important;
        height: 0 !important;
        max-height: 0 !important;
        padding: 0 !important;
        margin: 0 !important;
        border: 0 !important;
        overflow: hidden !important;
        visibility: hidden !important;
      }
      .shell.vamp-keyboard-open .chat { padding-bottom: 24px !important; }
    }

    @media (prefers-reduced-transparency: reduce) {
      .shell, .composer, .modal-card, .top .state { backdrop-filter: none !important; background: var(--bc-panel) !important; }
    }
    @media (prefers-contrast: more) {
      :root { --bc-line: rgba(120,120,126,.4); --bc-line-strong: rgba(120,120,126,.6); }
    }
    @media (prefers-reduced-motion: reduce) {
      *, *::before, *::after { scroll-behavior: auto !important; transition: none !important; animation: none !important; }
    }
    body.pairing .shell { visibility: hidden !important; }
    body.pairing .modal#pair {
      display: flex !important;
      align-items: center !important;
      justify-content: center !important;
      padding: 20px !important;
      background: var(--bc-page) !important;
      backdrop-filter: none !important;
    }
    body.pairing .modal#pair .modal-card {
      width: min(420px, 100%) !important;
      max-height: none !important;
      padding: 28px 24px !important;
      border-radius: 22px !important;
      border: 1px solid var(--bc-line) !important;
      background: var(--bc-panel-strong) !important;
      box-shadow: 0 30px 80px rgba(0,0,0,.16) !important;
      text-align: center !important;
    }
    .pair-mark { width: 56px; height: 56px; margin: 0 auto 4px; display: grid; place-items: center; border-radius: 16px; background: var(--bc-raised); border: 1px solid var(--bc-line); color: var(--bc-text); font-size: 27px; }
    #pair-title { margin-top: 14px !important; font-size: 21px !important; letter-spacing: -.01em !important; }
    #pair-help { margin: 8px auto 0 !important; max-width: 330px !important; color: var(--bc-secondary) !important; font-size: 13.5px !important; line-height: 1.5 !important; }
    .field-label { display: block; text-align: center; margin: 22px 0 9px; color: var(--bc-tertiary); font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: .09em; }
    #code { width: 100%; min-height: 58px; padding: 0 12px; border: 1px solid var(--bc-line-strong); border-radius: 15px; background: var(--bc-page); color: var(--bc-text); font: 650 22px ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: .12em; text-indent: .12em; text-align: center; }
    #code:focus-visible { outline: 2px solid var(--bc-text); outline-offset: 3px; }
    #pair-button { width: 100%; min-height: 52px; margin-top: 18px; border-radius: 15px; background: var(--bc-text); color: var(--bc-page); font-weight: 750; font-size: 15px; }
    #pair-button:disabled { opacity: .55; }
    .error:not(:empty) { margin-top: 11px; text-align: center; color: var(--danger); font-size: 13px; }

    /* ============================================================
       Chat card redesign — calmer, theme-aware surfaces that read in
       both light and dark. These win over the earlier heavy card
       styling (gradient boxes, clamped bodies, uppercase captions).
       ============================================================ */

    /* Assistant response: a calm glass surface, not a heavy gradient box. */
    .stream-card.output-message.structured-output,
    .stream-card.output-message:not(.structured-output) {
      padding: 15px 16px 13px !important;
      border: 1px solid var(--bc-line) !important;
      border-radius: var(--bc-radius, 18px) !important;
      background: var(--bc-panel) !important;
      box-shadow: none !important;
      -webkit-backdrop-filter: blur(16px) !important;
      backdrop-filter: blur(16px) !important;
    }
    .stream-card-head { align-items: center !important; gap: 10px !important; min-height: 32px !important; }
    .stream-card-title { gap: 10px !important; font-weight: 650 !important; font-size: 15px !important; color: var(--bc-text) !important; }
    .card-glyph { width: 30px !important; height: 30px !important; flex: 0 0 30px !important; border-radius: 9px !important; background: var(--bc-raised) !important; color: var(--bc-secondary) !important; border: 1px solid var(--bc-line) !important; font-size: 15px !important; }
    .stream-state { font-size: 11px !important; letter-spacing: .01em !important; text-transform: none !important; color: var(--bc-secondary) !important; font-weight: 600 !important; }
    .stream-state::before { content: '' !important; display: inline-block; width: 7px; height: 7px; border-radius: 50%; background: var(--good, #57d69b) !important; margin-right: 6px; vertical-align: middle; }
    .open-terminal-preview { background: transparent !important; border: 1px solid var(--bc-line-strong) !important; color: var(--bc-secondary) !important; border-radius: 10px !important; font-size: 12px !important; min-height: 30px !important; padding: 0 11px !important; }
    /* The provider name already labels the card; the "Response" caption is noise. */
    .stream-caption { display: none !important; }
    .stream-card.output-message .rich-body { margin-top: 12px !important; padding-left: 0 !important; }
    .rich-body p { font-size: 15.5px !important; line-height: 1.72 !important; margin: 0 0 13px !important; color: var(--bc-text) !important; }
    .rich-body p:last-child { margin-bottom: 0 !important; }
    .inline-code { background: var(--bc-raised) !important; border-color: var(--bc-line) !important; color: var(--bc-text) !important; }
    .rich-body .rich-code { border: 1px solid var(--bc-line) !important; border-radius: 12px !important; }

    /* Agent reasoning ("process"): a slim, dim accent above the answer. */
    .rich-thinking { margin: 0 0 14px !important; padding-left: 0 !important; border: 0 !important; border-left: 2px solid var(--bc-line-strong) !important; border-radius: 0 !important; background: transparent !important; overflow: visible !important; }
    .rich-thinking > summary { list-style: none; cursor: pointer; padding: 2px 0 2px 12px; color: var(--bc-tertiary); font-size: 12px; font-weight: 600; letter-spacing: .01em; display: flex; align-items: center; gap: 7px; min-height: 24px; }
    .rich-thinking > summary::-webkit-details-marker { display: none; }
    .rich-thinking > summary::before { content: '✳'; }
    .rich-thinking[open] > summary { margin-bottom: 6px; }
    .rich-thinking-body { padding: 0 0 0 12px; color: var(--bc-secondary); font-size: 13px; line-height: 1.55; }
    .rich-thinking-body p { margin: 0 0 8px; }
    .rich-thinking-body p:last-child { margin-bottom: 0; }

    /* User message: a compact bubble so the turn reads like a conversation. */
    .message.user-message { margin: 20px 0 16px !important; }
    .message.user-message .meta { margin-bottom: 7px !important; color: var(--bc-tertiary) !important; }
    .message.user-message .body { display: inline-block; background: var(--bc-raised); border: 1px solid var(--bc-line); border-radius: 15px; padding: 10px 14px; font-size: 15.5px; line-height: 1.55; color: var(--bc-text); }

    /* Explore row */
    .explore-row { color: var(--bc-secondary) !important; }
    .explore-row .explore-kind { color: var(--bc-text) !important; }

    /* Task-plan card: theme-aware (previously white-on-white in light mode). */
    .task-plan-card { background: var(--bc-panel) !important; border: 1px solid var(--bc-line) !important; box-shadow: none !important; }
    .task-plan-header strong, .task-plan-title { color: var(--bc-text) !important; }
    .task-plan-row { color: var(--bc-secondary) !important; }
    .task-plan-row.running .task-plan-title { color: var(--bc-text) !important; }
    .task-plan-row.completed, .task-plan-row.skipped { color: var(--bc-tertiary) !important; }
    .task-plan-status, .task-plan-progress, .task-plan-chevron { color: var(--bc-secondary) !important; }
    .task-plan-symbol { color: var(--bc-tertiary) !important; }
    .task-plan-row.completed .task-plan-symbol { color: var(--good, #57d69b) !important; }
    .task-plan-row.failed .task-plan-symbol { color: var(--danger, #ff8d85) !important; }
    .task-plan-detail { color: var(--bc-tertiary) !important; }
    .task-plan-footer { color: var(--bc-tertiary) !important; }
    .task-plan-interrupt, .task-plan-resume { border: 1px solid var(--bc-line-strong) !important; color: var(--bc-text) !important; background: var(--bc-raised) !important; }

    /* Approval / permission card: theme-aware. */
    .command-card { background: var(--bc-panel) !important; border: 1px solid var(--bc-line) !important; box-shadow: none !important; }
    .command-card .eyebrow { color: var(--bc-text) !important; }
    .command-card .approval { color: var(--bc-secondary) !important; }
    .command-card .command { background: var(--bc-page) !important; border: 1px solid var(--bc-line) !important; color: var(--bc-text) !important; }
    .approval-choice { border: 1px solid var(--bc-line) !important; background: var(--bc-raised) !important; color: var(--bc-text) !important; }
    .approval-choice.selected { border-color: var(--good, #57d69b) !important; background: color-mix(in srgb, var(--good, #57d69b) 14%, transparent) !important; }
    .approval-choice strong { color: var(--bc-text) !important; }
    .approval-choice small { color: var(--bc-secondary) !important; }
    .approval-choice .choice-number { color: var(--bc-secondary) !important; }
    .approval-footer .hint { color: var(--bc-secondary) !important; }
    .approval-footer .confirm { background: var(--bc-text) !important; color: var(--bc-page) !important; }

    /* Error card: a clear, readable failure surface for every provider. */
    .agent-error-card { margin: 12px 0 20px; padding: 13px 14px; border: 1px solid rgba(239,68,68,.35); border-radius: 14px; background: rgba(239,68,68,.06); }
    .agent-error-head { display: flex; align-items: center; gap: 8px; color: #B91C1C; font-size: 14px; font-weight: 700; }
    .agent-error-glyph { font-size: 15px; }
    .agent-error-body { margin-top: 8px; color: #7F1D1D; font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; overflow-wrap: anywhere; }
    .agent-error-hint { margin-top: 9px; color: #9A3A3A; font-size: 12px; line-height: 1.45; }
    html[data-resolved-theme="dark"] .agent-error-card { border-color: rgba(255,117,107,.32); background: rgba(255,117,107,.08); }
    html[data-resolved-theme="dark"] .agent-error-head { color: #ffb4ae; }
    html[data-resolved-theme="dark"] .agent-error-body { color: #f2dede; }
    html[data-resolved-theme="dark"] .agent-error-hint { color: #c0a3a0; }
  `;
  document.head.appendChild(browserControlDesign);

  let vampPresentation = 'chat';
  const modeSwitch = $('mode-switch');
  const modeChat = $('mode-chat');
  const modeTerminal = $('mode-terminal');
  const terminalKeybar = $('terminal-keybar');
  const setActiveDraft = (value) => {
    const draft = String(value || '');
    $('input').value = draft;
    if (active && tabs.get(active)) tabs.get(active).draft = draft;
  };
  const saveActiveDraft = () => {
    if (active && tabs.get(active)) tabs.get(active).draft = $('input').value;
  };
  // WebKit's default tap-to-focus path scrolls the nearest scroll container
  // before VisualViewport reports the keyboard. Focus explicitly from the
  // trusted pointer event with preventScroll so the keyboard can open without
  // moving the task canvas or the conversation's preserved scroll position.
  $('input').addEventListener('pointerdown', (event) => {
    if (document.activeElement === $('input')) return;
    event.preventDefault();
    $('input').focus({ preventScroll: true });
    const end = $('input').value.length;
    $('input').setSelectionRange(end, end);
  });
  $('input').addEventListener('input', saveActiveDraft);
  const updateComposerForMode = () => {
    const tab = tabs.get(active);
    const agentName = tab?.agent || tab?.title;
    const terminalMode = vampPresentation === 'terminal';
    $('input').placeholder = terminalMode
      ? 'Type terminal input…'
      : agentName && !/^Terminal(?: \\d+)?$/.test(agentName)
        ? 'Message ' + agentName + '…'
        : 'Type a shell command…';
    $('input').setAttribute('aria-label', terminalMode ? 'Terminal input' : (agentName ? 'Message ' + agentName : 'Shell command'));
    $('send').title = terminalMode ? 'Send terminal input' : 'Review command';
    $('send').setAttribute('aria-label', terminalMode ? 'Send terminal input' : 'Review command');
  };
  const setVampPresentation = (mode) => {
    vampPresentation = mode === 'terminal' ? 'terminal' : 'chat';
    document.body.classList.toggle('vamp-terminal-mode', vampPresentation === 'terminal');
    if (terminalKeybar) {
      terminalKeybar.hidden = vampPresentation !== 'terminal';
      terminalKeybar.setAttribute('aria-hidden', String(vampPresentation !== 'terminal'));
      // Safari may preserve an old layout box for a control whose display was
      // previously toggled by several responsive rules. An inline important
      // declaration makes the presentation state the sole source of truth.
      terminalKeybar.style.setProperty('display', vampPresentation === 'terminal' ? 'flex' : 'none', 'important');
      terminalKeybar.style.setProperty('visibility', vampPresentation === 'terminal' ? 'visible' : 'hidden', 'important');
    }
    modeChat?.setAttribute('aria-pressed', String(vampPresentation === 'chat'));
    modeTerminal?.setAttribute('aria-pressed', String(vampPresentation === 'terminal'));
    updateComposerForMode();
    requestAnimationFrame(() => {
      if (active) {
        vampResizeTerminal(active);
        if (vampPresentation === 'chat') vampScrollChatToLatest();
      }
    });
  };
  window.vampSetPresentation = setVampPresentation;
  modeChat?.addEventListener('click', () => setVampPresentation('chat'));
  modeTerminal?.addEventListener('click', () => setVampPresentation('terminal'));
  terminalKeybar?.querySelectorAll('[data-terminal-key]').forEach((button) => {
    button.addEventListener('click', () => {
      if (active) {
        const raw = button.dataset.terminalKey || '';
        const key = raw.replace(/\\u([0-9a-f]{4})/gi, (_, value) => String.fromCharCode(parseInt(value, 16)));
        sendInput(active, key);
      }
    });
  });
  setVampPresentation('chat');
  const originalCreateTabForPresentation = createTab;
  createTab = (startup = null, title = null, agent = null, workspace = null) => {
    if (active && tabs.get(active)) tabs.get(active).draft = $('input').value;
    const id = originalCreateTabForPresentation(startup, title, agent, workspace);
    if (id) {
      const tab = tabs.get(id);
      if (tab) {
        tab.draft = '';
        // Mount an explicit opening card immediately. A new PTY should never
        // look like a broken blank rectangle while the host is starting it.
        ensureOutputCard?.(id);
        filterTabContent?.();
      }
      setActiveDraft('');
      // Use the canonical tab identity, including the guarded launcher-title
      // recovery above. Using only this wrapper's optional argument could put
      // a known Grok/Claude/Codex tab into raw Terminal mode and bypass the
      // semantic Chat transport entirely.
      setVampPresentation(tab?.agent ? 'chat' : 'terminal');
    }
    return id;
  };

  const context = document.createElement('div');
  context.className = 'task-context';
  context.id = 'task-context';
  context.innerHTML = '<div class="workspace" id="context-workspace">Task workspace</div>' +
    '<button class="context-pill" id="context-repo" type="button" aria-label="Workspace source">▣ <span>Host</span></button>' +
    '<button class="context-icon" id="context-branch" type="button" aria-label="Session routing">⑂</button>' +
    '<button class="context-icon" id="context-more" type="button" aria-label="Terminal actions">•••</button>' +
    '<button class="context-icon" id="context-panel" type="button" aria-label="Open sessions dashboard">◧</button>';
  document.querySelector('.top')?.insertAdjacentElement('afterend', context);

  let keyboardWasOpen = false;
  let composerHasFocus = false;
  let correctingLayoutScroll = false;
  const lockLayoutViewport = () => {
    if (correctingLayoutScroll) return;
    const root = document.scrollingElement || document.documentElement;
    const displaced = window.scrollX !== 0 || window.scrollY !== 0 || root.scrollLeft !== 0 || root.scrollTop !== 0 || document.body.scrollTop !== 0;
    if (!displaced) return;
    correctingLayoutScroll = true;
    root.scrollLeft = 0;
    root.scrollTop = 0;
    document.body.scrollTop = 0;
    window.scrollTo(0, 0);
    correctingLayoutScroll = false;
  };
  const keyboardViewportUpdate = () => {
    const viewport = window.visualViewport;
    const layoutWidth = document.documentElement.clientWidth || window.innerWidth;
    const layoutHeight = document.documentElement.clientHeight || window.innerHeight;
    const visibleWidth = viewport?.width || layoutWidth;
    const visibleHeight = viewport?.height || layoutHeight;
    // iOS Safari moves the visual viewport over the layout viewport while the
    // keyboard or its browser chrome is visible. The shell is positioned at
    // this offset so absolute children behave like device-fixed UI without
    // relying on Safari's unreliable position:fixed compositor path.
    const offsetLeft = Number.isFinite(viewport?.offsetLeft) ? viewport.offsetLeft : 0;
    const offsetTop = Number.isFinite(viewport?.offsetTop) ? viewport.offsetTop : 0;
    const pageLeft = Number.isFinite(viewport?.pageLeft) ? viewport.pageLeft : window.scrollX + offsetLeft;
    const pageTop = Number.isFinite(viewport?.pageTop) ? viewport.pageTop : window.scrollY + offsetTop;
    const inset = Math.max(0, Math.round(layoutHeight - visibleHeight - Math.max(0, offsetTop)));
    // Focus is the earliest reliable keyboard signal on iOS. visualViewport
    // catches interactive dismissal and browser-chrome changes, but it can
    // lag the focus event by several frames (and sometimes never crosses a
    // fixed height threshold). Enter the compact keyboard layout immediately
    // on composer focus, then let viewport geometry decide when it is safe to
    // leave that layout.
    const viewportContracted = visibleHeight < layoutHeight - 80 || inset > 100;
    const keyboardOpen = composerHasFocus || viewportContracted;
    document.documentElement.style.setProperty('--vamp-visual-width', Math.max(280, Math.round(visibleWidth)) + 'px');
    // `vampUpdateViewportInset` is the single owner of visual height. Two
    // handlers previously wrote the same property during each WebKit keyboard
    // animation frame and triggered redundant ResizeObserver/layout passes.
    vampUpdateViewportInset();
    document.documentElement.style.setProperty('--vamp-vv-left', Math.round(pageLeft) + 'px');
    // The document is deliberately non-scrollable, but WebKit still pans the
    // visual viewport to reveal a focused input. Move the single shell canvas
    // with that viewport so its header and composer keep their screen-space
    // positions while its height contracts around the keyboard.
    document.documentElement.style.setProperty('--vamp-vv-top', Math.round(pageTop) + 'px');
    shell.classList.toggle('vamp-keyboard-open', keyboardOpen);
    document.documentElement.classList.toggle('vamp-keyboard-open', keyboardOpen);
    if (keyboardOpen) {
      const visibleModalCard = shell.querySelector('.modal:not(.hidden) .modal-card');
      if (visibleModalCard) {
        // iOS Safari may scroll the modal's own overflow container when the
        // pairing field receives focus even though the complete card already
        // fits above the keyboard. Restore its heading on every viewport
        // animation frame without moving the document or terminal content.
        visibleModalCard.scrollTop = 0;
        requestAnimationFrame(() => { visibleModalCard.scrollTop = 0; });
      }
    }
    if (keyboardOpen) document.documentElement.style.setProperty('--vamp-keyboard-height', Math.max(240, Math.round(visibleHeight)) + 'px');
    else document.documentElement.style.removeProperty('--vamp-keyboard-height');
    keyboardWasOpen = keyboardOpen;
  };
  const resetPagePosition = () => {
    document.documentElement.scrollTop = 0;
    document.body.scrollTop = 0;
    window.scrollTo(0, 0);
    content.dataset.userScrolled = 'false';
    requestAnimationFrame(() => { document.documentElement.scrollTop = 0; document.body.scrollTop = 0; window.scrollTo(0, 0); });
  };
  const isNearBottom = () => content.scrollHeight - content.scrollTop - content.clientHeight < 96;
let latestScrollFrame = 0;
   let latestScrollForce = false;
   const scrollLatest = (force = false) => {
     if (!force && !isNearBottom()) return;
     latestScrollForce = latestScrollForce || force;
     if (latestScrollFrame) return;
     latestScrollFrame = requestAnimationFrame(() => {
       latestScrollFrame = 0;
       latestScrollForce = false;
       content.dataset.vampProgrammatic = '1';
       content.scrollTop = content.scrollHeight;
       requestAnimationFrame(() => { delete content.dataset.vampProgrammatic; });
     });
   };
  content.addEventListener('scroll', () => {
    if (!content.dataset.vampProgrammatic) {
      const nearBottom = isNearBottom();
      content.dataset.userScrolled = content.scrollTop > 4 && !nearBottom ? 'true' : 'false';
      const tab = tabs.get(active);
      if (tab) tab.followOutput = nearBottom;
    }
  }, { passive: true });
  window.addEventListener('resize', keyboardViewportUpdate, { passive: true });
  window.visualViewport?.addEventListener('resize', keyboardViewportUpdate, { passive: true });
  window.addEventListener('scroll', lockLayoutViewport, { passive: true });
  window.visualViewport?.addEventListener('scroll', () => {
    lockLayoutViewport();
    keyboardViewportUpdate();
  }, { passive: true });
  window.addEventListener('orientationchange', () => { keyboardViewportUpdate(); resetPagePosition(); }, { passive: true });
  document.addEventListener('focusin', (event) => {
    if (event.target === $('input')) {
      composerHasFocus = true;
      lockLayoutViewport();
      keyboardViewportUpdate();
    }
  }, { passive: true });
  window.vampComposerDidBlur = () => {
    composerHasFocus = false;
    keyboardViewportUpdate();
  };
  document.addEventListener('focusout', (event) => {
    if (event.target !== $('input')) return;
    composerHasFocus = false;
    // visualViewport resize owns keyboard dismissal. Avoid delayed corrections
    // that can fire after the user has already resumed scrolling or typing.
    keyboardViewportUpdate();
  }, { passive: true });
  document.addEventListener('visibilitychange', keyboardViewportUpdate, { passive: true });
  keyboardViewportUpdate();

  // The page itself is a visual-viewport canvas. Only the conversation owns
  // vertical scrolling; allowing the body to rubber-band is what exposes a
  // clipped header and makes users pull the whole page down to "fit" it.
  document.addEventListener('touchmove', (event) => {
    const target = event.target instanceof Element ? event.target : null;
    if (target?.closest('.content, .tabs, .task-context, .composer, .modal')) return;
    event.preventDefault();
  }, { passive: false });

  const filterTabContent = () => {
    chat.querySelectorAll('[data-tab-id]').forEach((element) => {
      const hidden = Boolean(active) && element.dataset.tabId !== active;
      element.classList.toggle('vamp-tab-hidden', hidden);
      // Keep inactive cards out of layout and assistive technology. CSS alone
      // is not enough here because Terminal mode promotes cards to flex items.
      element.hidden = hidden;
    });
  };
  window.vampFilterTabContent = filterTabContent;

  // Inline emphasis on already-escaped text: markers (* _ [ ]) survive esc(),
  // and links/text are HTML-safe because the whole segment was escaped first.
  const inlineEmphasis = (escaped) => escaped
    .replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>')
    .replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, '$1<em>$2</em>')
    .replace(/(^|[^\w_])_([^_\n]+)_(?![\w])/g, '$1<em>$2</em>');
  const inline = (value) => {
    const source = String(value || '');
    const matcher = /`([^`\n]+)`/g;
    let result = '';
    let cursor = 0;
    let match;
    while ((match = matcher.exec(source))) {
      result += inlineEmphasis(esc(source.slice(cursor, match.index)));
      result += '<code class="inline-code">' + esc(match[1]) + '</code>';
      cursor = match.index + match[0].length;
    }
    return result + inlineEmphasis(esc(source.slice(cursor)));
  };
  const cells = (line) => {
    let value = String(line || '').trim();
    if (value.startsWith('|')) value = value.slice(1);
    if (value.endsWith('|')) value = value.slice(0, -1);
    return value.split('|').map((cell) => cell.trim());
  };
  const delimiter = (line) => {
    const values = cells(line);
    return values.length > 0 && values.every((value) => /^:?-{3,}:?$/.test(value));
  };
  const pipeRow = (line) => String(line || '').includes('|');
  const boxRow = (line) => /[┌┐└┘├┤┬┴┼│─╭╮╰╯╠╣╦╩╬]/.test(line) || /^\s*[+|-]{4,}\s*$/.test(line);
  const stepRow = (line) => /^\s*(?:✓|✔|✗|✘|⚠|!|→|›|•)\s+/.test(line);

  const renderBlocks = (raw) => {
    const lines = String(raw || '').replace(/\r/g, '').split('\n');
    const blocks = [];
    let index = 0;
    while (index < lines.length) {
      const line = lines[index];
      if (!line.trim()) { index += 1; continue; }
      const fence = line.trim().match(/^```\s*([\w.+-]*)/);
      if (fence) {
        const language = fence[1] || 'output';
        index += 1;
        const code = [];
        while (index < lines.length && !/^\s*```/.test(lines[index])) { code.push(lines[index]); index += 1; }
        if (index < lines.length) index += 1;
        blocks.push('<div class="rich-code-wrap"><button type="button" class="rich-code-copy" aria-label="Copy code">Copy</button><pre class="rich-code"><span class="code-language">' + esc(language) + '</span>' + esc(code.join('\n')) + '</pre></div>');
        continue;
      }
      if (index + 1 < lines.length && pipeRow(line) && delimiter(lines[index + 1])) {
        const header = cells(line);
        const rows = [];
        index += 2;
        while (index < lines.length && pipeRow(lines[index]) && lines[index].trim()) { rows.push(cells(lines[index])); index += 1; }
        blocks.push('<div class="rich-table-wrap"><table class="rich-table"><thead><tr>' + header.map((value) => '<th>' + inline(value) + '</th>').join('') + '</tr></thead><tbody>' + rows.map((row) => '<tr>' + header.map((_, cellIndex) => '<td>' + inline(row[cellIndex] || '') + '</td>').join('') + '</tr>').join('') + '</tbody></table></div>');
        continue;
      }
      if (boxRow(line)) {
        const box = [];
        while (index < lines.length && lines[index].trim() && boxRow(lines[index])) { box.push(lines[index]); index += 1; }
        blocks.push('<pre class="rich-box">' + esc(box.join('\n')) + '</pre>');
        continue;
      }
      const heading = line.match(/^\s*#{1,3}\s+(.+)/);
      if (heading) { blocks.push('<h3>' + inline(heading[1]) + '</h3>'); index += 1; continue; }
      if (stepRow(line)) {
        const step = line.trim().match(/^([^\s]+)\s+(.+)/);
        const mark = step?.[1] || '•';
        const body = step?.[2] || line.trim();
        const kind = /^(?:✓|✔)/.test(mark) ? 'good' : /^(?:⚠|!)/.test(mark) ? 'warn' : /^(?:✗|✘)/.test(mark) ? 'bad' : '';
        blocks.push('<div class="rich-step ' + kind + '"><span class="step-mark">' + esc(mark) + '</span><span>' + inline(body) + '</span></div>');
        index += 1;
        continue;
      }
      const paragraph = [line];
      index += 1;
      while (index < lines.length && lines[index].trim() && !/^```/.test(lines[index].trim()) && !(index + 1 < lines.length && pipeRow(lines[index]) && delimiter(lines[index + 1])) && !boxRow(lines[index]) && !stepRow(lines[index]) && !/^\s*#{1,3}\s+/.test(lines[index])) {
        paragraph.push(lines[index]);
        index += 1;
      }
      blocks.push('<p>' + inline(paragraph.join('\n')) + '</p>');
    }
    return blocks.join('');
  };

  // One delegated handler survives the innerHTML rewrites that stream output
  // into each card, so every code block's Copy button stays live.
  const chatSurface = $('chat');
  if (chatSurface && !chatSurface.dataset.copyBound) {
    chatSurface.dataset.copyBound = '1';
    chatSurface.addEventListener('click', (event) => {
      const copyButton = event.target.closest('.rich-code-copy');
      if (!copyButton) return;
      const pre = copyButton.parentElement?.querySelector('.rich-code');
      if (!pre) return;
      const clone = pre.cloneNode(true);
      clone.querySelector('.code-language')?.remove();
      const text = clone.textContent || '';
      const done = () => { copyButton.textContent = 'Copied'; setTimeout(() => { copyButton.textContent = 'Copy'; }, 1400); };
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done).catch(() => {});
      else done();
    });
  }

  const ensureOutputCard = (id) => {
    const tab = tabs.get(id);
    if (!tab) return null;
    if (!tab.outputCard || !tab.outputCard.isConnected) {
      const card = document.createElement('article');
      card.className = 'message stream-card output-message';
      card.dataset.tabId = id;
      const initialState = tab.state === 'opening'
        ? 'Opening terminal…'
        : tab.state === 'error' || tab.state === 'closed' || tab.state === 'offline'
          ? 'Terminal unavailable'
          : 'Waiting for terminal output…';
      card.innerHTML = '<div class="stream-card-head"><div class="stream-card-title"><span class="card-glyph">⌁</span><span>' + esc(tab.title) + '</span></div><div class="stream-card-actions"><span class="stream-state">' + esc(tab.opened ? 'Ready' : 'Opening') + '</span><button type="button" class="open-terminal-preview">Open Terminal</button></div></div><div class="stream-caption">Response</div><div class="rich-body" role="log" aria-live="polite"><div class="rich-empty">' + esc(initialState) + '</div></div>';
      card.querySelector('.open-terminal-preview')?.addEventListener('click', () => window.vampSetPresentation?.('terminal'));
      chat.appendChild(card);
      tab.outputCard = card;
    }
    return tab.outputCard;
  };
  window.vampEnsureTerminalPreview = (id) => ensureOutputCard(id);
  const vampResponsePresentation = (tab, terminalMode) => {
    if (terminalMode) {
      return {
        html: tab.terminal?.renderHTML() || '<div class="rich-empty">Waiting for terminal output…</div>',
        state: tab.opened ? 'Live' : 'Opening',
        caption: 'Interactive terminal'
      };
    }
    const response = String(tab.responseText || '');
    // The agent's reasoning is part of the process, not just the final answer.
    // Surface it as a dim, native <details> disclosure — open while it is the
    // only thing streaming, collapsible once the answer starts.
    const thinking = String(tab.thinkingText || '').trim();
    const thinkingHtml = thinking
      ? '<details class="rich-thinking"' + (tab.turnState === 'working' && !response.trim() ? ' open' : '') + '><summary>Thinking</summary><div class="rich-thinking-body">' + renderBlocks(thinking) + '</div></details>'
      : '';
    if (response.trim()) {
      return {
        html: thinkingHtml + renderBlocks(response),
        state: tab.turnState === 'working' ? 'Working' : 'Ready',
        caption: tab.turnState === 'working' ? 'Streaming response' : 'Response'
      };
    }
    if (tab.state === 'error' || tab.state === 'closed' || tab.state === 'offline' || tab.turnState === 'failed') {
      return { html: '<div class="rich-empty">This session is unavailable. Retry or open a new tab.</div>', state: 'Failed', caption: 'Session' };
    }
    if (!tab.opened || tab.state === 'opening') {
      return { html: '<div class="rich-empty">Opening terminal…</div>', state: 'Opening', caption: 'Starting session' };
    }
    if (tab.turnState === 'working' || tab.pendingCommand) {
      return { html: thinkingHtml + '<div class="rich-empty">' + esc(tab.agent ? tab.title + ' is working…' : 'Running command…') + '</div>', state: 'Working', caption: 'Live activity' };
    }
    const readyMessage = tab.agent
      ? tab.title + ' is ready. Send a message to begin.'
      : 'Shell ready. Type a command here or open Terminal for direct control.';
    return { html: '<div class="rich-empty ready-empty">' + esc(readyMessage) + '</div>', state: 'Ready', caption: tab.agent ? 'Agent session' : 'Shell session' };
  };
  window.vampResponsePresentation = vampResponsePresentation;
  const updateOutputCard = (id, text, replace = true) => {
    const tab = tabs.get(id);
    if (!tab) return;
    const stickToLatest = id === active && (tab.followOutput === true || isNearBottom());
    const card = ensureOutputCard(id);
    if (!card) return;
    const value = String(text || '').slice(-24000);
    const meaningful = value.trim() && value.trim() !== 'No output.' && value.trim() !== 'No output yet.';
    if (replace) tab.outputText = meaningful ? value : '';
    else tab.outputText = ((tab.outputText || '') + value).slice(-24000);
    const body = card.querySelector('.rich-body');
    if (body) {
      const rendered = renderBlocks(tab.outputText) || '<div class="rich-empty">Waiting for terminal output…</div>';
      body.innerHTML = rendered;
      // A trailing blinking caret while a response streams, so the card reads
      // as alive rather than frozen between chunks.
      if (tab.pendingCommand && tab.outputText && tab.outputText.trim()) {
        body.insertAdjacentHTML('beforeend', '<span class="rich-caret" aria-hidden="true"></span>');
      }
      card.classList.toggle('structured-output', /rich-(?:code|box|table-wrap|step)/.test(rendered));
    }
    const state = card.querySelector('.stream-state');
    if (state) state.textContent = tab.pendingCommand ? 'Streaming' : 'Live';
    filterTabContent();
    // Measure stickiness before the card grows. Checking after rendering
    // makes a long response look like the user scrolled away and breaks the
    // chat-following behavior once the card becomes taller than the viewport.
    if (stickToLatest) scrollLatest(true);
  };
  const terminalRenderQueue = new Set();
  let terminalRenderFrame = 0;
  var terminalRenderFallback = 0;
  const scheduleTerminalRender = (id) => {
    terminalRenderQueue.add(id);
    if (terminalRenderFrame) return;
    const flushTerminalRender = () => {
      if (terminalRenderFrame) cancelAnimationFrame(terminalRenderFrame);
      terminalRenderFrame = 0;
      if (terminalRenderFallback) clearTimeout(terminalRenderFallback);
      terminalRenderFallback = 0;
      terminalRenderFrame = 0;
      const pending = [...terminalRenderQueue];
      terminalRenderQueue.clear();
      pending.forEach((terminalID) => updateTerminalCard(terminalID));
    };
    terminalRenderFrame = requestAnimationFrame(flushTerminalRender);
    // Safari and Chromium can throttle requestAnimationFrame while browser
    // chrome is animating, the keyboard is settling, or the window is partly
    // occluded. Semantic Chat must still stream in those states. This bounded
    // fallback keeps rendering coalesced while guaranteeing visible progress.
    terminalRenderFallback = setTimeout(flushTerminalRender, 80);
  };
  const updateTerminalCard = (id) => {
    const tab = tabs.get(id);
    if (!tab || !tab.terminal) return;
    const stickToLatest = id === active && (tab.followOutput === true || isNearBottom());
    const card = ensureOutputCard(id);
    if (!card) return;
    const terminalMode = document.body.classList.contains('vamp-terminal-mode');
    card.classList.toggle('terminal-rendered', terminalMode);
    const body = card.querySelector('.rich-body');
    const bodyWasNearBottom = body ? body.scrollHeight - body.scrollTop - body.clientHeight < 28 : true;
    const previousBodyScrollTop = body?.scrollTop || 0;
    if (body) {
      let semanticSnapshot = tab.responseText || '';
      // Startup banners, prompts and full-screen TUI repaints are terminal
      // state, not a conversation. Chat begins only after an exact composer
      // submission establishes a semantic response boundary.
      if (!terminalMode && !tab.lastSubmittedCommand) semanticSnapshot = '';
      if (!terminalMode && !tab.agent && tab.lastSubmittedCommand) {
        const lines = semanticSnapshot.replace(/^\s*\n?/, '').split('\n');
        if (lines[0]?.includes(tab.lastSubmittedCommand)) lines.shift();
        if (lines.length > 1 && /^\s*(?:[^\n]*[%$#❯]|>)\s*$/.test(lines[lines.length - 1])) lines.pop();
        semanticSnapshot = lines.join('\n').trimEnd();
      }
      if (!terminalMode) tab.responseText = semanticSnapshot;
      const presentation = vampResponsePresentation(tab, terminalMode);
      body.innerHTML = presentation.html;
      body.scrollTop = bodyWasNearBottom ? body.scrollHeight : Math.min(previousBodyScrollTop, body.scrollHeight);
      if (!terminalMode && semanticSnapshot.trim()) window.vampInferTaskPlan?.(id, semanticSnapshot);
    }
    const presentation = vampResponsePresentation(tab, terminalMode);
    const state = card.querySelector('.stream-state');
    if (state) state.textContent = presentation.state;
    const caption = card.querySelector('.stream-caption');
    if (caption) caption.textContent = presentation.caption;
    filterTabContent();
    if (stickToLatest) scrollLatest(true);
  };
  // Provider events can arrive while Chromium throttles animation frames
  // (background window, occluded tab, or DevTools automation). Expose the
  // idempotent renderer so semantic completion can commit its final text
  // synchronously instead of leaving a stale "Waiting" card behind.
  window.vampRefreshTerminalCard = updateTerminalCard;

  const addExplore = (id, detail) => {
    const tab = tabs.get(id);
    if (!tab || !detail) return;
    const row = document.createElement('div');
    row.className = 'explore-row';
    row.dataset.tabId = id;
    row.innerHTML = '<span class="explore-icon" aria-hidden="true">⌕</span><span class="explore-kind">Explore</span><span>·</span><span class="explore-detail">' + esc(detail) + '</span>';
    chat.appendChild(row);
    filterTabContent();
    if (id === active) scrollLatest(false);
  };

  addMessage = (html, tabID = active) => {
    const stick = isNearBottom();
    const element = document.createElement('article');
    element.className = 'message';
    if (tabID) element.dataset.tabId = tabID;
    element.innerHTML = html;
    if (/terminal ready/i.test(element.textContent || '')) element.classList.add('system-message');
    chat.appendChild(element);
    filterTabContent();
    if (stick) scrollLatest(true);
    return element;
  };

  appendOutput = (id, text) => {
    const tab = tabs.get(id);
    if (!tab) return;
    tab.approvals ||= new Set();
    tab.terminal ||= new VampBrowserVT();
    if (text) tab.terminal.feed(text);
    tab.out = tab.terminal.render();
    // The VT screen is the only live-output source. It preserves spaces,
    // carriage-return rewrites, cursor movement, SGR colors, and alternate
    // screens; no per-packet regex or chat-text normalization is allowed.
    // Startup commands (tmux/screen/agents) can emit bytes before the
    // composer has recorded a command. Every PTY byte must still reach the
    // same terminal projection; gating this on commandCount made the first
    // interactive screen appear empty for launched agents.
    scheduleTerminalRender(id);
    if (tab.pendingCommand && tab.out.trim()) tab.pendingCommand = null;
    if (active !== id) { tab.unread = true; renderTabs(); }
  };

  const vampStructuredProviders = new Set(['grok', 'opencode', 'claude', 'codex', 'chatgpt', 'pi', 'commandcode', 'kimi', 'qwen', 'aider', 'gemini']);
  const sendAgentPrompt = (tabID, value) => {
    const tab = tabs.get(tabID);
    if (!tab || !tab.agent || !vampStructuredProviders.has(tab.agent)) return false;
    return send({
      type: 'agentPrompt',
      terminalID: tabID,
      provider: tab.agent,
      prompt: value,
      workingDirectory: tab.workspace?.path || null
    });
  };

  appendCommand = (value, status, tabID = active) => {
    const tab = tabs.get(tabID);
    if (tab) {
      tab.pendingCommand = value;
      tab.turnState = tab.opened ? 'working' : 'queued';
      tab.pendingOutputFrames = 0;
      tab.followOutput = true;
      tab.semanticBaseline = tab.semanticText || '';
      tab.responseSemantic = new VampSemanticStream();
      tab.responseText = '';
      tab.thinkingText = '';
      tab.lastSubmittedCommand = value;
      tab.commandCount = (tab.commandCount || 0) + 1;
    }
    const title = tab?.title || 'Terminal';
    const body = tab?.agent
      ? esc(value)
      : '<span style="color:#aaa">$ </span>' + esc(value);
    const element = addMessage('<div class="meta">You · ' + esc(title) + ' · ' + esc(status) + '</div><div class="body">' + body + '</div>', tabID);
    element.classList.add('user-message');
    addExplore(tabID, 'Running ' + value);
    // Keep one stable response card, but place it after the request it answers.
    // appendChild moves the existing node; it never duplicates terminal state.
    if (tab?.outputCard?.isConnected) chat.appendChild(tab.outputCard);
    filterTabContent();
    return element;
  };

  reviewCommand = () => {
    // Preserve the exact submitted composer value. Only use a trimmed copy
    // for the empty check; never make Chat infer or rewrite it from PTY echo.
    const value = $('input').value.replace(/\u0000/g, '');
    const tabID = active;
    const tab = tabs.get(tabID);
    if (!value.trim() || !tabID) return;
    if (document.body.classList.contains('vamp-terminal-mode')) {
      // Terminal mode is a raw PTY surface. The input is sent once as a line
      // and is never reconstructed as a Chat item from terminal echo.
      if (sendInput(tabID, value + '\r')) {
        setActiveDraft('');
        if (tab) tab.pendingCommand = null;
      }
      return;
    }
    if (!tab || !ws || ws.readyState !== WebSocket.OPEN) {
      addMessage('<div class="badge">This terminal is still opening. The command stays in the composer.</div>', tabID);
      return;
    }
    if (!tab.opened) {
      if (tab.pendingInput || tab.pendingAgentPrompt) {
        addMessage('<div class="badge">One command is already queued. It will run when this terminal is ready.</div>', tabID);
        return;
      }
      if (tab.agent && vampStructuredProviders.has(tab.agent)) tab.pendingAgentPrompt = value;
      else tab.pendingInput = value + '\r';
      setActiveDraft('');
      appendCommand(value, 'Queued · starting', tabID);
      vampScrollChatToLatest();
      return;
    }
    tab.approvals ||= new Set();
    if (tab.approvals.has(value)) {
      const sent = tab.agent && vampStructuredProviders.has(tab.agent)
        ? sendAgentPrompt(tabID, value)
        : sendInput(tabID, value + '\r');
      if (sent) { setActiveDraft(''); appendCommand(value, 'Running', tabID); }
      return;
    }
    const card = document.createElement('article');
    card.className = 'command-card';
    card.dataset.tabId = tabID;
    card.dataset.command = value;
    card.dataset.choice = 'once';
    const commandPreview = tab.agent ? esc(value) : '<span class="prompt">$ </span>' + esc(value);
    card.innerHTML = '<div class="eyebrow">⌁ Permission required</div><div class="approval">Awaiting approval · ' + esc(tab.title) + '</div><div class="command">' + commandPreview + '<br><span style="color:#888">No output.</span></div><div class="approval-actions"><button type="button" class="approval-choice selected" data-choice="once"><span class="choice-number">1.</span><span><strong>Allow</strong><small>Allow only this time</small></span></button><button type="button" class="approval-choice" data-choice="always"><span class="choice-number">2.</span><span><strong>Always allow</strong><small>Do not ask again for this command</small></span></button><button type="button" class="approval-choice" data-choice="deny"><span class="choice-number">3.</span><span><strong>Deny</strong><small>Reject it for now</small></span></button></div><div class="approval-footer"><p class="hint">Choose an action, then press Confirm.</p><button type="button" class="confirm">Confirm</button></div>';
    let choice = 'once';
    card.querySelectorAll('[data-choice]').forEach((button) => {
      button.onclick = () => {
        choice = button.dataset.choice || 'once';
        card.dataset.choice = choice;
        card.querySelectorAll('[data-choice]').forEach((candidate) => candidate.classList.toggle('selected', candidate === button));
      };
    });
    const resolveApproval = () => {
      if (card.dataset.resolved === '1') return;
      card.dataset.resolved = '1';
      choice = card.dataset.choice || choice;
      card.remove();
      const current = tabs.get(tabID);
      if (choice === 'deny') {
        setActiveDraft('');
        const deniedBody = current?.agent ? esc(value) : '<span style="color:#aaa">$ </span>' + esc(value);
        const denied = addMessage('<div class="meta">You · ' + esc(current?.title || 'Terminal') + ' · Denied</div><div class="body">' + deniedBody + '</div>', tabID);
        denied.classList.add('user-message');
        return;
      }
      if (choice === 'always' && current) { current.approvals ||= new Set(); current.approvals.add(value); }
      const sent = current?.agent && vampStructuredProviders.has(current.agent)
        ? sendAgentPrompt(tabID, value)
        : sendInput(tabID, value + '\r');
      if (sent) { setActiveDraft(''); appendCommand(value, choice === 'always' ? 'Always allowed · running' : 'Running', tabID); }
      else { if (choice === 'always' && current) current.approvals.delete(value); setActiveDraft(value); addMessage('<div class="badge">The host connection closed before the command was sent. Try again.</div>', tabID); }
    };
    card.querySelector('.confirm').onclick = resolveApproval;
    // Mobile Safari can retarget a tap while the visual viewport is settling
    // after composer blur. A delegated fallback keeps Confirm functional even
    // when the original button's direct click is lost during that reflow.
    card.addEventListener('pointerup', (event) => {
      if (event.target.closest('.confirm')) resolveApproval();
    });
    const stick = isNearBottom();
    chat.appendChild(card);
    filterTabContent();
    setActiveDraft('');
    // Permission cards are decision surfaces, not background transcript.
    // Release composer focus so iOS Safari restores the full visual viewport
    // before the card is anchored. Otherwise the keyboard can leave the card
    // title and first choice hidden beneath the fixed workspace chrome.
    $('input')?.blur();
    composerHasFocus = false;
    keyboardViewportUpdate();
    if (stick) {
      requestAnimationFrame(() => {
        content.dataset.vampProgrammatic = '1';
        // Approval tables can be taller than the available conversation
        // viewport. Align their heading, not their bottom, so the decision
        // context is never hidden beneath the mode switch.
        content.scrollTop = Math.max(0, card.offsetTop - 12);
        requestAnimationFrame(() => { delete content.dataset.vampProgrammatic; });
      });
      // Safari restores the visual viewport after blur in two phases. Reapply
      // the card's top anchor after each phase so its heading cannot be left
      // clipped by the former keyboard-sized viewport.
      [90, 220].forEach((delay) => setTimeout(() => {
        content.dataset.vampProgrammatic = '1';
        content.scrollTop = Math.max(0, card.offsetTop - 12);
        requestAnimationFrame(() => { delete content.dataset.vampProgrammatic; });
      }, delay));
    }
  };

  selectTab = (id) => {
    const tab = tabs.get(id);
    if (!tab) return;
    if (active && tabs.get(active)) tabs.get(active).draft = $('input').value;
    active = id;
    tab.unread = false;
    tab.followOutput = true;
    setActiveDraft(tab.draft || '');
    if (tab.opened) ensureStream(id);
    document.querySelectorAll('.stream').forEach((element) => element.classList.toggle('active', element.dataset.id === id));
    filterTabContent();
    renderTabs();
    updateComposerForMode();
    requestAnimationFrame(() => {
      if (tab.outputCard?.isConnected) scrollLatest(true);
      else content.scrollTop = 0;
      vampResizeTerminal(id);
    });
  };

  closeTab = (id) => {
    const tab = tabs.get(id);
    if (!tab) return;
    if (tab.opened && !window.confirm('Close ' + tab.title + '? This ends the shell unless it is inside tmux or screen.')) return;
    if (tab.opened && ws && ws.readyState === WebSocket.OPEN) send({ type: 'close', terminalID: id });
    chat.querySelectorAll('[data-tab-id="' + id + '"]').forEach((element) => element.remove());
    document.querySelector('.stream[data-id="' + id + '"]')?.remove();
    tabs.delete(id);
    order = order.filter((value) => value !== id);
    if (active === id) active = order[0] || null;
    if (!active && vampWorkspaces.length) chooseWorkspaceForLaunch(null, 'Shell');
    if (active) selectTab(active);
    renderTabs();
  };

  const originalDashboardToggle = vampToggleDashboard;
  vampToggleDashboard = (force) => {
    originalDashboardToggle(force);
    const showing = !$('dashboard').classList.contains('hidden');
    context.classList.toggle('hidden', showing);
    modeSwitch?.classList.toggle('hidden', showing);
    terminalKeybar?.classList.toggle('hidden', showing);
    shell.classList.toggle('dashboard-mode', showing);
    if (!showing) { filterTabContent(); resetPagePosition(); updateComposerForMode(); requestAnimationFrame(() => { if (active) selectTab(active); }); }
  };
  $('context-panel').onclick = () => vampToggleDashboard(true);
  $('context-more').onclick = openMoreModal;
  $('context-branch').onclick = () => addExplore(active, 'Session routing · ' + (tabs.get(active)?.title || 'Terminal'));
  $('context-repo').onclick = () => addExplore(active, 'Connected to Vamp Host');

  resetPagePosition();
  filterTabContent();
})();
</script></body></html>
"""#
}
#endif
