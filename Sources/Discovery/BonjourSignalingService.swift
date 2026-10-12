#if canImport(Network)
import Foundation
import Network
import Permissions
import SharedModels
import SharedProtocol
import SharedUtilities
import TransportWebRTC
import os

private final class OneShotResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func tryOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return false }
        hasResumed = true
        return true
    }
}

/// Concrete signaling service that uses Network.framework TCP connections
/// for exchanging signaling messages between the host and client.
///
/// - **Host mode**: Listens for incoming TCP connections on the Bonjour-advertised port.
///   When a client connects, messages are exchanged over the TCP stream.
/// - **Client mode**: Connects to the host's resolved Bonjour endpoint for signaling.
///
/// Messages are length-prefixed JSON: `[4-byte big-endian length][JSON payload]`.
public final class BonjourSignalingService: @unchecked Sendable {
    private let lock = NSLock()
    private let coder = JSONSignalingMessageCoder()
    private let logger = Logger(subsystem: "com.remotedesktop.discovery", category: "Signaling")

    // Host-side
    private var listener: NWListener?
    private var tlsListener: NWListener?
    private var serverConnection: NWConnection?

    // Client-side
    private var clientConnection: NWConnection?

    // Shared
    private var messageContinuation: AsyncThrowingStream<VersionedSignalingMessage, Error>.Continuation?
    /// Messages received before a consumer subscribes (fast-LAN / reconnect window) are buffered here
    /// under `lock` instead of being dropped, then drained when receiveMessages() is called.
    private var pendingMessages: [VersionedSignalingMessage] = []
    private var _isListening = false
    private var _isConnected = false
    private var _tlsListeningPort: UInt16?

    // Identity
    /// The local peer identity to use in signaling envelopes.
    /// Set this before connecting so outgoing messages carry a stable, recognizable identity.
    public var localPeer: SignalingPeer?

    // Security
    /// Set to true to require TLS on all connections.
    public var requireTLS: Bool = false
    /// The connection PIN used to derive the TLS pre-shared key.
    public var connectionPIN: String?
    /// Rate limiter for incoming connections.
    ///
    /// The budget must accommodate a legitimate client reconnect sweep: `reconnectLast` retries up
    /// to three times, each sweep can try several candidate endpoints (LAN + Tailscale), and a
    /// TLS-capable host may see a TLS socket and a plaintext one per attempt. A tighter limit let a
    /// client's own failed attempts exhaust the window, after which every reconnect is refused at
    /// TCP accept — before the client can send anything that would identify it as trusted. That is
    /// an unrecoverable lockout, not rate limiting.
    public let rateLimiter = ConnectionSecurity.ConnectionRateLimiter(maxAttempts: 30, windowSeconds: 60)
    /// Local identity key used to sign outgoing signaling messages.
    public var identityService: CryptoIdentityService?
    /// Reject unsigned signaling messages by default.
    public var enforceSignedMessages: Bool = true

    /// Fingerprints of peers this host has *approved* through the trust gate.
    ///
    /// A verified signature only proves the sender owns the key it signed with — anyone can
    /// generate a keypair. Clearing a peer's connection budget on signature verification alone
    /// would let an unauthenticated peer erase its own flood budget indefinitely and defeat the
    /// rate limiter. The budget is therefore only cleared for a fingerprint the user has actually
    /// trusted, which is what a reconnecting client is.
    private var trustedPeerFingerprints: Set<String> = []
    private let maxTrustedFingerprints = 256

    /// Record a peer the trust gate has approved, so its later reconnects are not blocked by the
    /// sockets its own failed attempts consumed.
    public func noteTrustedPeer(fingerprint: String) {
        let normalized = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !trustedPeerFingerprints.contains(normalized) else { return }
        if trustedPeerFingerprints.count >= maxTrustedFingerprints {
            trustedPeerFingerprints.removeAll()
        }
        trustedPeerFingerprints.insert(normalized)
    }

    /// Internal (not private) so the trust-gated budget clearing is unit-testable, matching
    /// `shouldAcceptMessage` above.
    func isTrustedPeer(_ fingerprint: String?) -> Bool {
        guard let fingerprint else { return false }
        let normalized = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return lock.withLock { trustedPeerFingerprints.contains(normalized) }
    }

    /// The TLS listener is deliberately exposed as state rather than inferred from
    /// the host fingerprint. A fingerprint can exist while the TLS socket failed to
    /// bind (for example while another host product owns the port).
    public var tlsListeningPort: UInt16? {
        lock.withLock { _tlsListeningPort }
    }
    /// Recently seen signaling envelope IDs for replay protection.
    private var seenEnvelopeIDs: [UUID: Date] = [:]
    private let maxSignalingMessageBytes = 16 * 1024
    private let replayWindowSeconds: TimeInterval = 30
    private let clockSkewAllowanceSeconds: TimeInterval = 30

    public init() {}

    deinit {
        listener?.cancel()
        tlsListener?.cancel()
        serverConnection?.cancel()
        clientConnection?.cancel()
        messageContinuation?.finish()
    }

    // MARK: - Host: Listen

    /// Start listening for signaling connections on the given port.
    /// Pass port 0 to let the OS assign a port.
    public func startListening(port: UInt16 = 0) throws -> UInt16 {
        let params: NWParameters
        if requireTLS, let pin = connectionPIN {
            let psk = ConnectionSecurity.deriveKey(from: pin)
            params = ConnectionSecurity.tlsTCPParameters(psk: psk)
        } else {
            if requireTLS {
                throw SignalingError.tlsConfigurationInvalid
            }
            params = ConnectionSecurity.keepaliveTCPParameters()
        }
        let requestedPort: NWEndpoint.Port
        if port == 0 {
            requestedPort = .any
        } else if let validPort = NWEndpoint.Port(rawValue: port) {
            requestedPort = validPort
        } else {
            throw SignalingError.listenerFailed
        }
        let l = try NWListener(using: params, on: requestedPort)

        var assignedPort: UInt16?
        let semaphore = DispatchSemaphore(value: 0)

        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                assignedPort = l.port?.rawValue
                semaphore.signal()
            case .failed(let error):
                self?.logger.error("Signaling listener failed: \(error.localizedDescription)")
                semaphore.signal()
            default:
                break
            }
        }

        l.newConnectionHandler = { [weak self] conn in
            self?.handleIncomingConnection(conn)
        }

        // .userInitiated keeps this accept queue serviced even when the host app is backgrounded
        // and the Mac is locked/idle. A default-QoS queue gets demoted in that state, so the
        // kernel completes the TCP handshake on the signaling port but newConnectionHandler never
        // runs in time — the host looks "online but unreachable" until the app is foregrounded
        // (an inbound SSH/Codex hit lands on a separate daemon and never raises the app's QoS).
        let listenerQueue = DispatchQueue(label: "com.remotedesktop.signaling.listener", qos: .userInitiated)
        l.start(queue: listenerQueue)

        _ = semaphore.wait(timeout: .now() + 5)

        guard let port = assignedPort else {
            l.cancel()
            throw SignalingError.listenerFailed
        }

        lock.lock()
        listener = l
        _isListening = true
        lock.unlock()

        logger.info("Signaling listener started on port \(port)")
        return port
    }

    /// Start a TLS-PSK listener on `port` alongside the plain listener.
    /// `pin` is the host's public-key fingerprint; it is used to derive the PSK so
    /// only clients that already know the fingerprint can complete the TLS handshake.
    /// Returns the port actually bound.  Throws if the listener cannot start.
    public func startTLSListening(pin: String, port: UInt16 = 0) throws -> UInt16 {
        let psk = ConnectionSecurity.deriveKey(from: pin)
        let params = ConnectionSecurity.tlsTCPParameters(psk: psk)

        let requestedPort: NWEndpoint.Port
        if port == 0 {
            requestedPort = .any
        } else if let validPort = NWEndpoint.Port(rawValue: port) {
            requestedPort = validPort
        } else {
            throw SignalingError.listenerFailed
        }

        let l = try NWListener(using: params, on: requestedPort)

        var assignedPort: UInt16?
        let semaphore = DispatchSemaphore(value: 0)

        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                assignedPort = l.port?.rawValue
                semaphore.signal()
            case .failed(let error):
                self?.logger.error("TLS signaling listener failed: \(error.localizedDescription)")
                semaphore.signal()
            default:
                break
            }
        }

        l.newConnectionHandler = { [weak self] conn in
            self?.handleIncomingConnection(conn)
        }

        // Same reason as the plain listener: stay serviced while backgrounded/locked.
        let tlsQueue = DispatchQueue(label: "com.remotedesktop.signaling.tls-listener", qos: .userInitiated)
        l.start(queue: tlsQueue)

        _ = semaphore.wait(timeout: .now() + 5)

        guard let p = assignedPort else {
            l.cancel()
            throw SignalingError.listenerFailed
        }

        lock.lock()
        tlsListener = l
        _tlsListeningPort = p
        _isListening = true
        lock.unlock()

        logger.info("TLS signaling listener started on port \(p)")
        return p
    }

    private func handleIncomingConnection(_ conn: NWConnection) {
        // Rate-limit by remote IP
        let remoteIP: String
        switch conn.endpoint {
        case .hostPort(let host, _):
            remoteIP = "\(host)"
        default:
            remoteIP = "unknown"
        }
        guard rateLimiter.shouldAllow(ip: remoteIP) else {
            logger.warning("Rate-limited signaling connection from \(remoteIP)")
            conn.cancel()
            return
        }

        lock.lock()
        if let existing = serverConnection {
            // Replace the previous connection so fast reconnect attempts are accepted,
            // even if the old socket still appears ready for a short period.
            existing.cancel()
            serverConnection = nil
        }
        serverConnection = conn
        _isConnected = true
        lock.unlock()

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.info("Signaling client connected")
                self.startReceiving(on: conn, remoteIP: remoteIP)
            case .failed(let error):
                self.logger.error("Signaling connection failed: \(error.localizedDescription)")
                // Don't finish the message continuation here — the listener
                // stays alive and may accept a new client connection.  The
                // receive loop on this connection will stop on its own.
                self.lock.lock()
                if self.serverConnection === conn {
                    self.serverConnection = nil
                    self._isConnected = false
                }
                self.lock.unlock()
            case .cancelled:
                self.lock.lock()
                if self.serverConnection === conn {
                    self.serverConnection = nil
                    self._isConnected = false
                }
                self.lock.unlock()
            default:
                break
            }
        }
        // Keep the offer/answer exchange responsive while backgrounded/locked (see listener above).
        let serverQueue = DispatchQueue(label: "com.remotedesktop.signaling.server", qos: .userInitiated)
        conn.start(queue: serverQueue)
    }

    // MARK: - Client: Connect

    /// Connect to a host's signaling endpoint.
    public func connect(host: String, port: UInt16) async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw SignalingError.connectionFailed
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: endpointPort
        )
        let params: NWParameters
        if requireTLS, let pin = connectionPIN {
            let psk = ConnectionSecurity.deriveKey(from: pin)
            params = ConnectionSecurity.tlsTCPParameters(psk: psk)
        } else {
            if requireTLS {
                throw SignalingError.tlsConfigurationInvalid
            }
            params = ConnectionSecurity.keepaliveTCPParameters()
        }
        let conn = NWConnection(to: endpoint, using: params)

        storeClientConnection(conn)

        // Use a dedicated serial queue so state callbacks are serialised
        let connQueue = DispatchQueue(label: "com.remotedesktop.signaling.connect")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeGate = OneShotResumeGate()
                conn.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard resumeGate.tryOpen() else { return }
                        self.setConnected(true)
                        self.logger.info("Signaling connected")
                        self.startReceiving(on: conn)
                        continuation.resume()
                    case .failed(let error):
                        guard resumeGate.tryOpen() else { return }
                        self.logger.error("Signaling connect failed: \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    case .waiting(let error):
                        // On LAN with peer-to-peer, .waiting is a normal transient
                        // state before .ready.  Log it and let the outer timeout handle
                        // truly unreachable hosts.
                        self.logger.info("Signaling connect waiting: \(error.localizedDescription)")
                    case .cancelled:
                        guard resumeGate.tryOpen() else { return }
                        continuation.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                conn.start(queue: connQueue)
            }
        } onCancel: {
            conn.cancel()
        }
    }

    // MARK: - Receive

    private func startReceiving(on conn: NWConnection, remoteIP: String? = nil) {
        readLengthPrefixedMessage(on: conn, remoteIP: remoteIP)
    }

    private func storeClientConnection(_ connection: NWConnection) {
        lock.lock()
        clientConnection = connection
        lock.unlock()
    }

    private func setConnected(_ isConnected: Bool) {
        lock.lock()
        _isConnected = isConnected
        lock.unlock()
    }

    private func readLengthPrefixedMessage(on conn: NWConnection, remoteIP: String? = nil) {
        // Read 4-byte length header
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, data.count == 4 else {
                // Connection dropped — stop the receive loop for THIS connection.
                // On the client side (outgoing connection) finish the message stream so
                // the consumer can detect the drop immediately rather than waiting for a
                // negotiation timeout.  On the host side the listener stays alive across
                // individual client disconnections, so we must NOT finish the stream.
                let isClientConn = self.lock.withLock { conn === self.clientConnection }
                if isClientConn {
                    let streamError: Error = error ?? SignalingError.notConnected
                    if let error { self.logger.warning("Signaling receive ended: \(error.localizedDescription)") }
                    else { self.logger.info("Signaling connection closed by peer") }
                    self.messageContinuation?.finish(throwing: streamError)
                } else {
                    if let error { self.logger.warning("Signaling receive ended: \(error.localizedDescription)") }
                    else { self.logger.info("Signaling connection closed by peer") }
                }
                return
            }
            var lenBE: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &lenBE) { data.copyBytes(to: $0) }
            let payloadLen = Int(UInt32(bigEndian: lenBE))

            guard payloadLen > 0, payloadLen <= self.maxSignalingMessageBytes else {
                self.logger.error("Invalid signaling message length: \(payloadLen)")
                self.readLengthPrefixedMessage(on: conn, remoteIP: remoteIP)
                return
            }

            // Read payload
            conn.receive(minimumIncompleteLength: payloadLen, maximumLength: payloadLen) { [weak self] payload, _, _, error in
                guard let self else { return }
                if let payload {
                    do {
                        let decodedMessage = try self.coder.decode(payload)
                        var normalizedMessage = decodedMessage
                        if self.enforceSignedMessages, let senderPublicKey = decodedMessage.senderPublicKey {
                            let derivedFingerprint = CryptoIdentityService.fingerprint(of: senderPublicKey)
                            if let claimed = decodedMessage.envelope.sender.publicKeyFingerprint,
                               !claimed.isEmpty,
                               claimed != derivedFingerprint {
                                self.logger.warning("Incoming signaling fingerprint mismatch; normalizing to key-derived fingerprint")
                            }
                            normalizedMessage.envelope.sender.publicKeyFingerprint = derivedFingerprint
                        }
                        // Enforce minimum protocol version
                        if decodedMessage.minimumProtocolVersion > RemoteDesktopConstants.protocolVersion {
                            self.logger.warning("Rejected message requiring protocol v\(decodedMessage.minimumProtocolVersion), we support v\(RemoteDesktopConstants.protocolVersion)")
                        } else if !self.verifySignalingMessage(normalizedMessage) {
                            self.logger.warning("Rejected signaling message due to signature verification failure")
                        } else if !self.shouldAcceptMessage(normalizedMessage) {
                            self.logger.warning("Rejected signaling message due to replay/timestamp validation")
                        } else {
                            // Clear this peer's connection budget only once the host has
                            // actually trusted it. A healthy client's reconnect attempts must
                            // not be permanently blocked by the sockets its own earlier
                            // failed attempts consumed — but a merely *self-signed* peer must
                            // not be able to erase its flood budget (see noteTrustedPeer).
                            if let remoteIP, self.isTrustedPeer(normalizedMessage.envelope.sender.publicKeyFingerprint) {
                                self.rateLimiter.reset(ip: remoteIP)
                            }
                            self.lock.lock()
                            if let continuation = self.messageContinuation {
                                self.lock.unlock()
                                continuation.yield(normalizedMessage)
                            } else {
                                // No consumer yet — buffer (don't drop) so an offer/answer that beats
                                // the subscriber isn't lost. Capped so a flood can't grow unbounded.
                                self.pendingMessages.append(normalizedMessage)
                                if self.pendingMessages.count > 32 { self.pendingMessages.removeFirst() }
                                self.lock.unlock()
                            }
                        }
                    } catch {
                        self.logger.error("Failed to decode signaling message: \(error.localizedDescription)")
                    }
                }
                if let error {
                    self.logger.warning("Signaling payload receive error: \(error.localizedDescription)")
                    // A transient framing/receive error on a still-live connection must NOT silently
                    // abandon the stream (offers/answers/ICE would stop arriving). Keep reading while
                    // the connection is viable; if it's actually down, stop and let the state handler
                    // drive reconnection (avoids a tight error loop on a cancelled/failed connection).
                    if conn.state == .ready {
                        self.readLengthPrefixedMessage(on: conn, remoteIP: remoteIP)
                    }
                    return
                }
                self.readLengthPrefixedMessage(on: conn, remoteIP: remoteIP)
            }
        }
    }

    // MARK: - Send

    private var activeConnection: NWConnection? {
        lock.withLock { clientConnection ?? serverConnection }
    }

    private func sendRaw(_ data: Data) async throws {
        guard let conn = activeConnection, conn.state == .ready else {
            throw SignalingError.notConnected
        }
        // Length-prefix the data
        var header = Data(capacity: 4)
        var lenBE = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &lenBE) { header.append(contentsOf: $0) }
        var frame = header
        frame.append(data)

        return try await withCheckedThrowingContinuation { continuation in
            conn.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Stop

    public func stopListening() {
        lock.lock()
        let l = listener
        let tls = tlsListener
        let sc = serverConnection
        listener = nil
        tlsListener = nil
        _tlsListeningPort = nil
        serverConnection = nil
        _isListening = false
        _isConnected = false
        lock.unlock()
        sc?.cancel()
        l?.cancel()
        tls?.cancel()
        messageContinuation?.finish()
    }

    public func disconnect() {
        lock.lock()
        let cc = clientConnection
        let cont = messageContinuation
        clientConnection = nil
        _isConnected = false
        lock.unlock()
        cc?.cancel()
        // Finish the message stream so the client-side signalingListenTask exits
        // immediately without having to wait for cooperative task cancellation.
        // On the host side, stopListening() is always called before disconnect(),
        // so this finish() is a safe no-op there (the continuation is already nil).
        cont?.finish()
    }

    /// Cancel the current accepted (server) or outgoing (client) connection without
    /// stopping the listener or finishing the message stream.  Use this on the host
    /// side when a negotiation fails and the host wants to go back to awaitingClient
    /// while keeping the listener active.
    public func dropCurrentConnection() {
        lock.lock()
        let sc = serverConnection
        let cc = clientConnection
        serverConnection = nil
        clientConnection = nil
        _isConnected = false
        lock.unlock()
        sc?.cancel()
        cc?.cancel()
    }

    public var isConnected: Bool {
        lock.withLock { _isConnected }
    }

    /// Internal (not private) so the replay-window behavior is unit-testable.
    func shouldAcceptMessage(_ message: VersionedSignalingMessage) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        // Retain seen IDs for window + skew: an envelope stamped up to
        // `clockSkewAllowanceSeconds` in the future is still accepted for that
        // long after its ID would otherwise have been pruned, so pruning at
        // `replayWindowSeconds` alone left a replay gap for future-dated IDs.
        let oldestAllowed = now.addingTimeInterval(-(replayWindowSeconds + clockSkewAllowanceSeconds))
        seenEnvelopeIDs = seenEnvelopeIDs.filter { $0.value >= oldestAllowed }
        if seenEnvelopeIDs.count > 500 {
            let overflow = seenEnvelopeIDs.count - 500
            let oldest = seenEnvelopeIDs.sorted { $0.value < $1.value }.prefix(overflow)
            for entry in oldest { seenEnvelopeIDs.removeValue(forKey: entry.key) }
        }

        let envelope = message.envelope
        if seenEnvelopeIDs[envelope.id] != nil {
            return false
        }
        let age = now.timeIntervalSince(envelope.sentAt)
        if age > replayWindowSeconds || age < -clockSkewAllowanceSeconds {
            return false
        }

        seenEnvelopeIDs[envelope.id] = now
        return true
    }

    private func signMessageIfNeeded(_ message: VersionedSignalingMessage) throws -> VersionedSignalingMessage {
        guard enforceSignedMessages else { return message }
        guard let identityService else {
            throw SignalingError.missingSigningIdentity
        }
        var signed = message
        // Ensure the claimed sender fingerprint always matches the key
        // actually used for signing, even if callers pass stale identity data.
        signed.envelope.sender.publicKeyFingerprint = identityService.fingerprint
        signed.senderPublicKey = identityService.publicKeyData
        signed.signature = try identityService.sign(try signed.unsignedPayloadData())
        return signed
    }

    func verifySignalingMessage(_ message: VersionedSignalingMessage) -> Bool {
        guard enforceSignedMessages else { return true }
        guard let senderPublicKey = message.senderPublicKey,
              let signature = message.signature else {
            return false
        }
        if let claimedFingerprint = message.envelope.sender.publicKeyFingerprint,
           !claimedFingerprint.isEmpty {
            let derivedFingerprint = CryptoIdentityService.fingerprint(of: senderPublicKey)
            guard claimedFingerprint == derivedFingerprint else {
                return false
            }
        }
        guard let unsigned = try? message.unsignedPayloadData() else {
            return false
        }
        return CryptoIdentityService.verify(signature: signature, data: unsigned, publicKeyData: senderPublicKey)
    }

    // MARK: - Error

    public enum SignalingError: Error, LocalizedError {
        case listenerFailed
        case connectionFailed
        case notConnected
        case encodingFailed
        case tlsConfigurationInvalid
        case missingSigningIdentity

        public var errorDescription: String? {
            switch self {
            case .listenerFailed: return "Signaling listener failed to start."
            case .connectionFailed: return "Signaling connection failed."
            case .notConnected: return "Signaling not connected."
            case .encodingFailed: return "Failed to encode signaling message."
            case .tlsConfigurationInvalid: return "TLS is required but no valid PIN was configured."
            case .missingSigningIdentity: return "Signed signaling is enabled but no identity key is configured."
            }
        }
    }
}

// MARK: - SignalingServiceProtocol

extension BonjourSignalingService: SessionCoordinatorSignaling {
    public func startAdvertising(host: HostIdentity) async throws {
        // Advertising is handled by BonjourHostDiscoveryAdvertiser.
        // This method is a no-op here — the signaling listener is started separately.
    }

    public func stopAdvertising() async {
        stopListening()
    }

    public func send(_ message: VersionedSignalingMessage) async throws {
        let signed = try signMessageIfNeeded(message)
        let data = try coder.encode(signed)
        try await sendRaw(data)
    }

    public func receiveMessages() -> AsyncThrowingStream<VersionedSignalingMessage, Error> {
        AsyncThrowingStream { continuation in
            self.lock.lock()
            self.messageContinuation = continuation
            let buffered = self.pendingMessages
            self.pendingMessages = []
            self.lock.unlock()
            // Deliver anything that arrived before this consumer subscribed (the pre-subscription
            // window), so a fast peer's offer/answer isn't lost.
            for message in buffered {
                continuation.yield(message)
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.messageContinuation = nil
                self?.lock.unlock()
            }
        }
    }

    public func sendSignalingMessage(_ message: VersionedSignalingMessage) async throws {
        try await send(message)
    }

    public func incomingSignalingMessages() -> AsyncThrowingStream<VersionedSignalingMessage, Error> {
        receiveMessages()
    }

    public func sendHello(_ message: HelloMessage, to host: HostIdentity) async throws {
        let envelope = SignalingEnvelope(
            protocolVersion: 1,
            sessionID: nil,
            sender: SignalingPeer(id: UUID(), role: .client),
            event: .offer(SessionOfferMessage(sessionID: UUID(), sdp: "", qualityPreset: .balanced))
        )
        // Hello is not a standard signaling event — encode as a raw message
        // For now, we skip the hello and go straight to offer/answer
        _ = envelope
        logger.info("Hello to host (no-op in LAN signaling)")
    }

    public func sendOffer(_ message: SessionOfferMessage, to host: HostIdentity) async throws {
        let envelope = SignalingEnvelope(
            protocolVersion: 1,
            sessionID: message.sessionID,
            sender: localPeer ?? SignalingPeer(id: UUID(), role: .client),
            event: .offer(message)
        )
        try await send(VersionedSignalingMessage(envelope: envelope))
    }

    public func sendAnswer(_ message: SessionAnswerMessage, to client: ClientIdentity) async throws {
        let envelope = SignalingEnvelope(
            protocolVersion: 1,
            sessionID: message.sessionID,
            sender: localPeer ?? SignalingPeer(id: UUID(), role: .host),
            event: .answer(message)
        )
        try await send(VersionedSignalingMessage(envelope: envelope))
    }

    public func sendCandidate(_ message: ICECandidateMessage) async throws {
        let envelope = SignalingEnvelope(
            protocolVersion: 1,
            sessionID: message.sessionID,
            sender: localPeer ?? SignalingPeer(id: UUID(), role: .host),
            event: .iceCandidate(message)
        )
        try await send(VersionedSignalingMessage(envelope: envelope))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
#endif
