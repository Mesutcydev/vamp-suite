#if canImport(Network)
import Foundation
import Network
import Security
import SharedUtilities
import os

public protocol LANTransportSecurityConfigurable: AnyObject {
    func configureTransportSecurity(sessionTokenHex: String?)
}

// MARK: - LAN Session Descriptor (used as SDP payload)

/// JSON-encoded descriptor exchanged via the signaling layer in place of real SDP.
/// The host includes its data port so the client knows where to connect.
struct LANSessionDescriptor: Codable, Sendable {
    var dataPort: UInt16?
    var sessionID: String
    var channels: [String]
    /// Maps channel label → tag byte so both peers use matching tags.
    var channelTags: [String: UInt8]?

    func encoded() -> String {
        let data = try? JSONEncoder().encode(self)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func decoded(from sdp: String) -> LANSessionDescriptor? {
        guard let data = sdp.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LANSessionDescriptor.self, from: data)
    }
}

// MARK: - Provider

/// Creates `LANPeerConnection` instances for LAN peer-to-peer communication
/// using Network.framework. Set `remoteHost` before preparing a client session.
public final class LANPeerConnectionProvider: PeerConnectionProviding, LANTransportSecurityConfigurable, @unchecked Sendable {
    private let lock = NSLock()
    private var _remoteHost: String?
    private var _sessionTokenHex: String?
    /// When true, the host listener uses a fixed well-known port
    /// (RemoteDesktopConstants.defaultDataPort) instead of a random one.
    /// This makes port-forwarding feasible for remote (non-LAN) access.
    public var useFixedDataPort: Bool = false

    public init() {}

    /// Set the resolved host address (IP/hostname) for client-mode connections.
    public func setRemoteHost(_ host: String?) {
        lock.withLock { _remoteHost = host }
    }

    public var remoteHost: String? {
        lock.withLock { _remoteHost }
    }

    public func configureTransportSecurity(sessionTokenHex: String?) {
        lock.withLock { _sessionTokenHex = sessionTokenHex }
    }

    public func makePeerConnection(
        configuration: WebRTCConfiguration,
        delegate: any PeerConnectionDelegate
    ) throws -> any PeerConnectionProtocol {
        let state = lock.withLock { (_remoteHost, _sessionTokenHex) }
        return LANPeerConnection(
            remoteHost: state.0,
            fixedDataPort: useFixedDataPort ? RemoteDesktopConstants.defaultDataPort : nil,
            sessionTokenHex: state.1,
            delegate: delegate
        )
    }
}

// MARK: - Peer Connection

/// Network.framework–based peer connection for LAN streaming.
///
/// - Host mode: starts an `NWListener` on a random port. The port is
///   communicated to the client via the SDP answer.
/// - Client mode: connects to the host's data port (from the SDP answer)
///   combined with the `remoteHost` IP provided via the provider.
///
/// Data channels are multiplexed over the single TCP connection using a
/// simple frame format: `[1-byte channelTag][4-byte big-endian length][payload]`.
public final class LANPeerConnection: LANTransportSecurityConfigurable, @unchecked Sendable {
    private let lock = NSLock()
    private weak var delegate: (any PeerConnectionDelegate)?
    private let remoteHost: String?
    private let fixedDataPort: UInt16?
    private var sessionTokenHex: String?
    private let logger = Logger(subsystem: "com.remotedesktop.transport", category: "LANPeerConn")

    // Networking
    private var listener: NWListener?
    private var connection: NWConnection?
    /// An accepted socket is only promoted after its authenticated TLS-PSK
    /// handshake reaches `.ready`. This prevents an unauthenticated TCP client
    /// from evicting a healthy data session merely by connecting to the port.
    private var pendingAcceptedConnection: NWConnection?
    private var listenerPort: UInt16?
    private var pendingRemoteEndpoint: (host: String, port: UInt16)?
    private var connectAttempt: Int = 0

    // State
    private var _connectionState: PeerConnectionState = .new
    private var _iceConnectionState: ICEConnectionState = .new
    private var _iceGatheringState: ICEGatheringState = .complete // LAN: no ICE needed
    private var _localDesc: SessionDescription?
    private var _remoteDesc: SessionDescription?

    // Channels
    private var channels: [String: LANDataChannel] = [:]
    private var channelsByTag: [UInt8: LANDataChannel] = [:]
    private var nextChannelTag: UInt8 = 0

    init(remoteHost: String?, fixedDataPort: UInt16? = nil, sessionTokenHex: String? = nil, delegate: any PeerConnectionDelegate) {
        self.remoteHost = remoteHost
        self.fixedDataPort = fixedDataPort
        self.sessionTokenHex = sessionTokenHex
        self.delegate = delegate
    }

    public func configureTransportSecurity(sessionTokenHex: String?) {
        lock.withLock { self.sessionTokenHex = sessionTokenHex }
    }

    deinit {
        listener?.cancel()
        pendingAcceptedConnection?.cancel()
        connection?.cancel()
    }

    // MARK: - Multiplexing

    private static let frameHeaderSize = 5

    fileprivate func sendFramedData(
        channelTag: UInt8,
        payload: Data,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> Bool {
        guard let conn = lock.withLock({ connection }),
              conn.state == .ready else { return false }
        var header = Data(capacity: Self.frameHeaderSize)
        header.append(channelTag)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { header.append(contentsOf: $0) }
        var frame = header
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.logger.error("Send error: \(error.localizedDescription)")
            }
            completion(error)
        })
        return true
    }

    private func startReceiving() {
        guard let conn = lock.withLock({ connection }) else { return }
        receiveFrame(on: conn)
    }

    private func receiveFrame(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: Self.frameHeaderSize, maximumLength: Self.frameHeaderSize) { [weak self] headerData, _, _, error in
            guard let self else { return }
            guard let headerData, headerData.count == Self.frameHeaderSize else {
                if let error, !self.isCancellationError(error) {
                    self.handleConnectionError(error)
                }
                return
            }
            let tag = headerData[headerData.startIndex]
            let lenBytes = headerData.subdata(in: (headerData.startIndex + 1)..<(headerData.startIndex + 5))
            var lenBE: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &lenBE) { lenBytes.copyBytes(to: $0) }
            let payloadLen = Int(UInt32(bigEndian: lenBE))

            // Guard against corrupted/malicious length fields (max 16 MB per frame).
            guard payloadLen >= 0, payloadLen <= 16_777_216 else {
                self.logger.error("Received invalid frame payload length: \(payloadLen)")
                self.handleConnectionError(nil)
                return
            }

            if payloadLen == 0 {
                self.dispatchFrame(tag: tag, payload: Data())
                self.receiveFrame(on: conn)
                return
            }

            conn.receive(minimumIncompleteLength: payloadLen, maximumLength: payloadLen) { [weak self] payloadData, _, _, error in
                guard let self else { return }
                if let payloadData {
                    self.dispatchFrame(tag: tag, payload: payloadData)
                }
                if let error, !self.isCancellationError(error) {
                    self.handleConnectionError(error)
                    return
                }
                self.receiveFrame(on: conn)
            }
        }
    }

    private func dispatchFrame(tag: UInt8, payload: Data) {
        lock.lock()
        if let channel = channelsByTag[tag] {
            lock.unlock()
            channel.receiveData(payload)
        } else {
            // Auto-discover channel from remote peer (client side)
            let label = tag == 0 ? "control" : "video"
            let channel = LANDataChannel(label: label, channelTag: tag, connection: self)
            channels[label] = channel
            channelsByTag[tag] = channel
            let del = delegate
            lock.unlock()
            channel.transitionState(.open)
            del?.peerConnection(self, didOpenDataChannel: channel)
            channel.receiveData(payload)
        }
    }

    private func handleConnectionError(_ error: Error?) {
        logger.error("Connection error: \(error?.localizedDescription ?? "unknown")")
        transitionState(.failed)
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if let nwError = error as? NWError, case .posix(let code) = nwError {
            return code == .ECANCELED
        }
        return "\(error)".lowercased().contains("cancel")
    }

    // MARK: - State

    private func transitionState(_ newState: PeerConnectionState) {
        lock.lock()
        _connectionState = newState
        let del = delegate
        lock.unlock()
        del?.peerConnection(self, didChangeConnectionState: newState)

        // Map to ICE state
        let iceState: ICEConnectionState
        switch newState {
        case .new: iceState = .new
        case .connecting: iceState = .checking
        case .connected: iceState = .connected
        case .disconnected: iceState = .disconnected
        case .failed: iceState = .failed
        case .closed: iceState = .closed
        }
        lock.lock()
        _iceConnectionState = iceState
        lock.unlock()
        del?.peerConnection(self, didChangeICEConnectionState: iceState)
    }

    // MARK: - TCP Parameters

    /// TCP parameters with kernel keepalive enabled so half-open connections
    /// (AP roam, NAT table timeout, peer power loss) surface as `.failed`
    /// within ~15 s instead of sitting in `.ready` indefinitely.
    private static let tlsPSKIdentity = Data("vamp-data-channel-v1".utf8)
    private static let tlsPSKCiphersuite = tls_ciphersuite_t(rawValue: UInt16(0x00AD))

    private static func makeTCPParameters(sessionTokenHex: String?) throws -> NWParameters {
        guard let sessionTokenHex,
              let token = tokenFromHex(sessionTokenHex),
              token.count == 32 else {
            throw WebRTCSessionError.invalidState("A valid session token is required for the encrypted data transport.")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 2
        let tls = NWProtocolTLS.Options()
        let psk = token.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = tlsPSKIdentity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, psk as __DispatchData, identity as __DispatchData)
        if let tlsPSKCiphersuite {
            sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tlsPSKCiphersuite)
        }
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        return params
    }

    private static func tokenFromHex(_ hex: String) -> Data? {
        guard hex.count == 64 else { return nil }
        var result = Data(capacity: 32)
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    // MARK: - Host: Listener

    /// A fixed-port listener can briefly remain bound after `cancel()` while
    /// Network.framework finishes tearing down its socket on the listener queue.
    /// Fast session renegotiation creates the replacement peer immediately, so
    /// retry only this transient bind failure instead of rejecting the reconnect.
    private static let fixedPortBindRetryDelays: [UInt64] = [
        100_000_000,
        200_000_000,
        400_000_000,
        800_000_000,
        1_200_000_000,
        1_500_000_000,
        2_000_000_000
    ]

    private static func isAddressAlreadyInUse(_ error: Error) -> Bool {
        guard let nwError = error as? NWError,
              case .posix(let code) = nwError else { return false }
        return code == .EADDRINUSE
    }

    private func startListener() async throws -> UInt16 {
        var retryIndex = 0

        while true {
            do {
                return try await startListenerAttempt()
            } catch {
                guard fixedDataPort != nil,
                      Self.isAddressAlreadyInUse(error),
                      retryIndex < Self.fixedPortBindRetryDelays.count else {
                    if error is NWError {
                        throw WebRTCSessionError.peerConnectionFailed(
                            "Listener bind failed: \(error.localizedDescription)"
                        )
                    }
                    throw error
                }

                let delay = Self.fixedPortBindRetryDelays[retryIndex]
                retryIndex += 1
                logger.warning(
                    "Fixed data port is still being released; retrying listener bind (attempt \(retryIndex + 1))"
                )
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func startListenerAttempt() async throws -> UInt16 {
        let params = try Self.makeTCPParameters(sessionTokenHex: lock.withLock { sessionTokenHex })
        let l: NWListener
        if let fixedPort = fixedDataPort, let nwPort = NWEndpoint.Port(rawValue: fixedPort) {
            l = try NWListener(using: params, on: nwPort)
        } else {
            l = try NWListener(using: params)
        }
        l.newConnectionHandler = { [weak self] newConn in
            guard let self else { return }
            self.acceptConnection(newConn)
        }
        // .userInitiated so the data-port accept handler keeps running while the host app is
        // backgrounded and the Mac is locked/idle (see the same fix on the signaling listener).
        let listenerQueue = DispatchQueue(label: "com.remotedesktop.data.listener", qos: .userInitiated)
        lock.withLock { listener = l }

        // Await the listener reaching .ready (port assigned) or .failed, instead of polling
        // `listenerPort` for 500ms. The old spin-wait timed out under load and — worse — reported
        // the same misleading "Listener port not assigned" when the real cause was a bind failure
        // (.failed never sets the port). Now a bind failure surfaces its real error immediately,
        // a slow-but-valid bind is awaited, and a stuck listener fails after a 10s fail-safe.
        // One-shot guard: the continuation must resume exactly once across .ready/.failed/timeout.
        let resumeState = OSAllocatedUnfairLock(initialState: false)
        let claim: @Sendable () -> Bool = {
            resumeState.withLock { alreadyResumed in
                if alreadyResumed { return false }
                alreadyResumed = true
                return true
            }
        }
        let port: UInt16
        do {
            port = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
                let timeout = DispatchWorkItem {
                    if claim() {
                        cont.resume(throwing: WebRTCSessionError.peerConnectionFailed("Listener didn't become ready within 10s"))
                    }
                }
                listenerQueue.asyncAfter(deadline: .now() + 10, execute: timeout)
                l.stateUpdateHandler = { [weak self, weak l] state in
                    switch state {
                    case .ready:
                        guard let rawPort = l?.port?.rawValue else { return }
                        if claim() {
                            timeout.cancel()
                            self?.logger.info("LAN listener ready on port \(rawPort)")
                            cont.resume(returning: rawPort)
                        }
                    case .failed(let error):
                        self?.logger.error("LAN listener failed: \(error.localizedDescription)")
                        if claim() {
                            timeout.cancel()
                            // Preserve NWError so fixed-port EADDRINUSE can be identified
                            // and retried by startListener(). Other failures still pass
                            // through unchanged to the session coordinator.
                            cont.resume(throwing: error)
                        } else {
                            // Failed after it had already come up → tear the session down.
                            self?.transitionState(.failed)
                        }
                    case .cancelled:
                        if claim() {
                            timeout.cancel()
                            cont.resume(throwing: WebRTCSessionError.peerConnectionFailed("Listener cancelled before ready"))
                        }
                    default:
                        break
                    }
                }
                l.start(queue: listenerQueue)
            }
        } catch {
            lock.withLock {
                if listener === l {
                    listener = nil
                    listenerPort = nil
                }
            }
            l.stateUpdateHandler = nil
            l.cancel()
            throw error
        }
        // Defensive validation before publishing the successfully assigned port.
        guard port > 0 else {
            l.cancel()
            throw WebRTCSessionError.peerConnectionFailed("Listener returned an invalid port")
        }
        lock.withLock { listenerPort = port }
        return port
    }

    private func acceptConnection(_ newConn: NWConnection) {
        let supersededCandidate = lock.withLock { () -> NWConnection? in
            let previous = pendingAcceptedConnection
            pendingAcceptedConnection = newConn
            return previous
        }
        supersededCandidate?.cancel()

        newConn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let previousConnection = self.lock.withLock { () -> NWConnection? in
                    guard self.pendingAcceptedConnection === newConn else { return nil }
                    self.pendingAcceptedConnection = nil
                    let previous = self.connection
                    self.connection = newConn
                    return previous
                }
                guard self.lock.withLock({ self.connection === newConn }) else {
                    newConn.cancel()
                    return
                }
                // A reconnect that completed the authenticated TLS handshake
                // may now replace a stale ready socket. Authentication happens
                // first; supersession happens second.
                previousConnection?.cancel()
                self.transitionState(.connected)
                self.onConnectionEstablished()
            case .failed(let error):
                self.logger.error("Accepted connection failed: \(error.localizedDescription)")
                let hadActiveConnection = self.lock.withLock { () -> Bool in
                    if self.pendingAcceptedConnection === newConn {
                        self.pendingAcceptedConnection = nil
                    }
                    return self.connection != nil
                }
                if !hadActiveConnection {
                    self.transitionState(.failed)
                }
            case .cancelled:
                let shouldClose = self.lock.withLock { () -> Bool in
                    if self.pendingAcceptedConnection === newConn {
                        self.pendingAcceptedConnection = nil
                        return self.connection == nil
                    }
                    return self.connection === newConn
                }
                if shouldClose {
                    self.transitionState(.closed)
                }
            default:
                break
            }
        }
        newConn.viabilityUpdateHandler = { [weak self] viable in
            self?.logger.warning("Accepted data connection viability changed: \(viable ? "viable" : "NOT viable")")
        }
        // Keep the accepted data connection responsive while backgrounded/locked (see listener above).
        let acceptedQueue = DispatchQueue(label: "com.remotedesktop.data.accepted", qos: .userInitiated)
        newConn.start(queue: acceptedQueue)
    }

    // MARK: - Client: Connect

    private func connectToHost(host: String, port: UInt16) {
        lock.lock()
        pendingRemoteEndpoint = (host, port)
        connectAttempt += 1
        let attempt = connectAttempt
        lock.unlock()

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            logger.error("Client connect skipped due to invalid port \(port)")
            transitionState(.failed)
            return
        }
        logger.info("Client data connect attempt \(attempt) to \(host):\(port)")
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: endpointPort)
        let params: NWParameters
        do {
            params = try Self.makeTCPParameters(sessionTokenHex: lock.withLock { sessionTokenHex })
        } catch {
            logger.error("Client data transport security setup failed: \(error.localizedDescription)")
            transitionState(.failed)
            return
        }
        let conn = NWConnection(to: endpoint, using: params)
        lock.lock()
        connection = conn
        lock.unlock()

        transitionState(.connecting)

        // Use a serial queue so state callbacks are serialised
        let connQueue = DispatchQueue(label: "com.remotedesktop.data.connect")
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.connectAttempt = 0
                self.lock.unlock()
                self.transitionState(.connected)
                self.onConnectionEstablished()
            case .failed(let error):
                self.logger.error("Client connect failed: \(error.localizedDescription)")
                self.transitionState(.failed)
                self.scheduleReconnectIfNeeded(failedConnection: conn)
            case .waiting(let error):
                // On LAN with peer-to-peer, .waiting is a normal transient
                // state before .ready.  Just log it — the connection will
                // either transition to .ready or .failed on its own.
                self.logger.info("Data connection waiting: \(error.localizedDescription)")
            case .cancelled:
                self.transitionState(.closed)
                self.scheduleReconnectIfNeeded(failedConnection: conn)
            default:
                break
            }
        }
        conn.viabilityUpdateHandler = { [weak self] viable in
            self?.logger.warning("Client data connection viability changed: \(viable ? "viable" : "NOT viable")")
        }
        conn.start(queue: connQueue)
    }

    private func scheduleReconnectIfNeeded(failedConnection: NWConnection) {
        let retryInfo: (host: String, port: UInt16, attempt: Int)?
        lock.lock()
        defer { lock.unlock() }
        guard connection === failedConnection else { return }
        guard let target = pendingRemoteEndpoint else { return }
        // Bumped from 3 → 6 attempts.  With exponential backoff this is a
        // ~16-second budget total, which comfortably rides through brief
        // Wi-Fi flaps without giving up on the session.
        guard connectAttempt < 6 else { return }
        retryInfo = (target.host, target.port, connectAttempt + 1)

        // Exponential backoff: 0.5s, 1s, 2s, 4s, 8s (capped).  Previous
        // fixed 0.5s missed any flap longer than half a second.
        let delays: [Double] = [0.5, 1.0, 2.0, 4.0, 8.0]
        let delay = delays[min(connectAttempt, delays.count - 1)]
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let retryInfo else { return }
            self.connectToHost(host: retryInfo.host, port: retryInfo.port)
        }
    }

    private func onConnectionEstablished() {
        // Transition existing channels to open
        lock.lock()
        let existingChannels = Array(channels.values)
        lock.unlock()
        for channel in existingChannels {
            channel.transitionState(.open)
        }
        startReceiving()
    }

    private func ensureChannelsFromRemote(_ labels: [String], tagMap: [String: UInt8]?) -> ([LANDataChannel], (any PeerConnectionDelegate)?) {
        lock.lock()
        for label in labels {
            if channels[label] == nil {
                let tag: UInt8
                if let mapped = tagMap?[label] {
                    tag = mapped
                } else {
                    tag = nextChannelTag
                    nextChannelTag += 1
                }
                let channel = LANDataChannel(label: label, channelTag: tag, connection: self)
                channels[label] = channel
                channelsByTag[tag] = channel
                // Ensure nextChannelTag stays above any mapped tag
                if tag >= nextChannelTag { nextChannelTag = tag + 1 }
            }
        }
        let snapshot = (Array(channels.values), delegate)
        lock.unlock()
        return snapshot
    }
}

// MARK: - PeerConnectionProtocol

extension LANPeerConnection: PeerConnectionProtocol {
    public var localDescription: SessionDescription? {
        lock.withLock { _localDesc }
    }

    public var remoteDescription: SessionDescription? {
        lock.withLock { _remoteDesc }
    }

    public var connectionState: PeerConnectionState {
        lock.withLock { _connectionState }
    }

    public var iceConnectionState: ICEConnectionState {
        lock.withLock { _iceConnectionState }
    }

    public var iceGatheringState: ICEGatheringState {
        lock.withLock { _iceGatheringState }
    }

    public func createOffer(constraints: MediaConstraints?) async throws -> SessionDescription {
        let (channelLabels, tagMap) = lock.withLock {
            (Array(channels.keys), Dictionary(uniqueKeysWithValues: channels.map { ($0.key, $0.value.channelTag) }))
        }
        let desc = LANSessionDescriptor(
            dataPort: nil,
            sessionID: UUID().uuidString,
            channels: channelLabels,
            channelTags: tagMap
        )
        let sdp = SessionDescription(type: .offer, sdp: desc.encoded())
        return sdp
    }

    public func createAnswer(constraints: MediaConstraints?) async throws -> SessionDescription {
        let port = try await startListener()
        let (channelLabels, tagMap) = lock.withLock {
            (Array(channels.keys), Dictionary(uniqueKeysWithValues: channels.map { ($0.key, $0.value.channelTag) }))
        }
        let desc = LANSessionDescriptor(
            dataPort: port,
            sessionID: UUID().uuidString,
            channels: channelLabels,
            channelTags: tagMap
        )
        let sdp = SessionDescription(type: .answer, sdp: desc.encoded())
        return sdp
    }

    public func setLocalDescription(_ sdp: SessionDescription) async throws {
        lock.withLock { _localDesc = sdp }
    }

    public func setRemoteDescription(_ sdp: SessionDescription) async throws {
        lock.withLock { _remoteDesc = sdp }

        // Client: when receiving the answer, connect to the host's data port
        if sdp.type == .answer, let desc = LANSessionDescriptor.decoded(from: sdp.sdp) {
            if let port = desc.dataPort, let host = remoteHost {
                logger.info("Applying remote answer for data endpoint \(host):\(port)")
                // Pre-create channels from the answer's channel list, using matching tags
                let channelSnapshot = ensureChannelsFromRemote(desc.channels, tagMap: desc.channelTags)
                // Report channels to delegate
                for channel in channelSnapshot.0 {
                    channelSnapshot.1?.peerConnection(self, didOpenDataChannel: channel)
                }
                connectToHost(host: host, port: port)
            } else {
                logger.error("Remote answer missing connect target. host=\(self.remoteHost ?? "nil"), dataPort=\(desc.dataPort?.description ?? "nil")")
            }
        }
    }

    public func addICECandidate(_ candidate: ICECandidate) async throws {
        // No-op for LAN connections — no ICE needed
    }

    public func createDataChannel(_ config: DataChannelConfiguration) -> (any DataChannelProtocol)? {
        lock.lock()
        let tag = nextChannelTag
        nextChannelTag += 1
        let channel = LANDataChannel(label: config.label, channelTag: tag, connection: self)
        channels[config.label] = channel
        channelsByTag[tag] = channel
        lock.unlock()
        return channel
    }

    public func addVideoTrack(_ track: any VideoTrackProtocol) {
        // Video is sent via the data channel, not a media track
    }

    public func removeVideoTrack(_ track: any VideoTrackProtocol) {
        // No-op
    }

    public func close() {
        lock.lock()
        let conn = connection
        let l = listener
        connection = nil
        listener = nil
        pendingRemoteEndpoint = nil
        connectAttempt = 0
        let chs = Array(channels.values)
        channels.removeAll()
        channelsByTag.removeAll()
        lock.unlock()

        for ch in chs { ch.transitionState(.closed) }
        conn?.cancel()
        l?.cancel()
        transitionState(.closed)
    }
}

// MARK: - Data Channel

/// Logical data channel multiplexed over a `LANPeerConnection`'s TCP connection.
public final class LANDataChannel: @unchecked Sendable {
    public let label: String
    let channelTag: UInt8
    private weak var connection: LANPeerConnection?
    private let lock = NSLock()
    private var _readyState: DataChannelState = .connecting
    private var _bufferedAmount: UInt64 = 0
    private weak var _delegate: (any DataChannelDelegate)?

    init(label: String, channelTag: UInt8, connection: LANPeerConnection) {
        self.label = label
        self.channelTag = channelTag
        self.connection = connection
    }

    func transitionState(_ newState: DataChannelState) {
        lock.lock()
        _readyState = newState
        let del = _delegate
        lock.unlock()
        del?.dataChannel(self, didChangeState: newState)
    }

    func receiveData(_ data: Data) {
        let del = lock.withLock { _delegate }
        del?.dataChannel(self, didReceiveData: data)
    }
}

extension LANDataChannel: DataChannelProtocol {
    public var readyState: DataChannelState {
        lock.withLock { _readyState }
    }

    public var bufferedAmount: UInt64 {
        lock.withLock { _bufferedAmount }
    }

    public func send(_ data: Data) -> Bool {
        let framedByteCount = UInt64(data.count + 5)
        lock.withLock { _bufferedAmount &+= framedByteCount }
        guard let connection,
              connection.sendFramedData(
                channelTag: channelTag,
                payload: data,
                completion: { [weak self] _ in
                    guard let self else { return }
                    self.lock.withLock {
                        self._bufferedAmount = self._bufferedAmount >= framedByteCount
                            ? self._bufferedAmount - framedByteCount
                            : 0
                    }
                }
              ) else {
            lock.withLock {
                _bufferedAmount = _bufferedAmount >= framedByteCount
                    ? _bufferedAmount - framedByteCount
                    : 0
            }
            return false
        }
        return true
    }

    public func close() {
        transitionState(.closed)
    }

    public func setDelegate(_ delegate: any DataChannelDelegate) {
        lock.withLock { _delegate = delegate }
    }
}
#endif
