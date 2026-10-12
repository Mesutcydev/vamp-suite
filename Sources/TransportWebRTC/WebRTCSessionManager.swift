import Foundation
import SharedModels
import SharedProtocol
import os

/// Concrete WebRTC session manager that orchestrates a peer connection, data channel,
/// ICE handling, and media attachment through app-owned protocol abstractions.
///
/// Requires a `PeerConnectionProviding` implementation to create the actual peer connection
/// (typically a thin adapter over the WebRTC SDK).
public final class WebRTCSessionManager: @unchecked Sendable {
    private let peerConnectionProvider: any PeerConnectionProviding
    private let configuration: WebRTCConfiguration
    fileprivate let maxInboundControlMessageBytes = 128 * 1024
    private var controlChannelAuthTokenHex: String?
    private var outboundControlAuthCounter: UInt64 = 0
    fileprivate let lock = NSLock()
    fileprivate let logger = Logger(subsystem: "com.remotedesktop.transport", category: "WebRTCSession")

    // MARK: - Session State

    fileprivate var _sessionID: UUID?
    fileprivate var _role: WebRTCSessionRole?
    fileprivate var _peerConnection: (any PeerConnectionProtocol)?
    fileprivate var _controlChannel: (any DataChannelProtocol)?
    fileprivate var _videoSource: (any VideoFrameSource)?
    fileprivate var _delegateAdapter: PeerConnectionDelegateAdapter?
    fileprivate var _channelDelegateAdapter: DataChannelDelegateAdapter?
    fileprivate var _videoChannel: (any DataChannelProtocol)?
    fileprivate var _videoChannelDelegateAdapter: VideoChannelDelegateAdapter?

    // MARK: - Observable State

    fileprivate var _connectionState: ConnectionState = .idle
    fileprivate var _peerConnectionState: PeerConnectionState = .new
    fileprivate var _dataChannelState: DataChannelState = .closed
    fileprivate var _streamDiagnostics: StreamDiagnostics = StreamDiagnostics()
    fileprivate var _latestVideoFrame: VideoFrameData?
    fileprivate var _latestBootstrapVideoFrame: VideoFrameData?
    fileprivate var _hasLoggedFirstVideoBytes = false
    fileprivate var _videoFragmentationEnabled = false
    fileprivate var _videoFECEnabled = false
    // Receiver-side downlink loss estimate: EMA of the gap (frames skipped) before each
    // received frame. For steady loss p this converges to p/(1-p), so permille = g/(g+1)·1000
    // recovers p·1000. Decays to 0 once frames are contiguous again.
    fileprivate var _lossGapEMA: Double = 0
    fileprivate var _lossLastSeq: UInt64?
    // Sender-side: the most recent loss the remote receiver reported (host reads this).
    fileprivate var _lastClientLossPermille: Int = 0
    fileprivate let videoFrameReassembler = VideoFrameReassembler()
    private let maxVideoPacketBytes = 256 * 1024

    // MARK: - Async Stream Continuations

    fileprivate var iceContinuations: [UUID: AsyncStream<ICECandidateMessage>.Continuation] = [:]
    fileprivate var dataContinuations: [UUID: AsyncStream<DataChannelEnvelope>.Continuation] = [:]
    fileprivate var stateContinuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    fileprivate var dataStateContinuations: [UUID: AsyncStream<DataChannelState>.Continuation] = [:]
    fileprivate var videoChannelStateContinuations: [UUID: AsyncStream<DataChannelState>.Continuation] = [:]
    fileprivate var videoFrameContinuations: [UUID: AsyncStream<VideoFrameData>.Continuation] = [:]
    fileprivate var _videoForwardingTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        peerConnectionProvider: any PeerConnectionProviding,
        configuration: WebRTCConfiguration = .lanDefault
    ) {
        self.peerConnectionProvider = peerConnectionProvider
        self.configuration = configuration
    }

    deinit {
        lock.lock()
        let iceSnapshot = Array(iceContinuations.values)
        let dataSnapshot = Array(dataContinuations.values)
        let stateSnapshot = Array(stateContinuations.values)
        let dataStateSnapshot = Array(dataStateContinuations.values)
        let videoChannelStateSnapshot = Array(videoChannelStateContinuations.values)
        let videoSnapshot = Array(videoFrameContinuations.values)
        iceContinuations.removeAll()
        dataContinuations.removeAll()
        stateContinuations.removeAll()
        dataStateContinuations.removeAll()
        videoChannelStateContinuations.removeAll()
        videoFrameContinuations.removeAll()
        let fwdTask = _videoForwardingTask
        _videoForwardingTask = nil
        lock.unlock()
        iceSnapshot.forEach { $0.finish() }
        dataSnapshot.forEach { $0.finish() }
        stateSnapshot.forEach { $0.finish() }
        dataStateSnapshot.forEach { $0.finish() }
        videoChannelStateSnapshot.forEach { $0.finish() }
        videoSnapshot.forEach { $0.finish() }
        fwdTask?.cancel()
    }

    // MARK: - Helpers

    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    fileprivate func updateConnectionState(_ newState: ConnectionState) {
        lock.lock()
        _connectionState = newState
        let continuations = Array(stateContinuations.values)
        lock.unlock()
        for c in continuations { c.yield(newState) }
    }

    fileprivate func updateDataChannelState(_ newState: DataChannelState) {
        lock.lock()
        _dataChannelState = newState
        let continuations = Array(dataStateContinuations.values)
        lock.unlock()
        for c in continuations { c.yield(newState) }
    }

    fileprivate func updateVideoChannelState(_ newState: DataChannelState) {
        lock.lock()
        let continuations = Array(videoChannelStateContinuations.values)
        lock.unlock()
        for c in continuations { c.yield(newState) }
    }

    fileprivate func mapPeerStateToConnectionState(_ state: PeerConnectionState) -> ConnectionState {
        switch state {
        case .new:          return .connecting
        case .connecting:   return .connecting
        case .connected:    return .connected
        case .disconnected: return .disconnected
        case .failed:       return .failed
        case .closed:       return .disconnected
        }
    }

    private func ensurePrepared() throws -> any PeerConnectionProtocol {
        lock.lock()
        let pc = _peerConnection
        lock.unlock()
        guard let pc else { throw WebRTCSessionError.notPrepared }
        return pc
    }

    private func storePreparedState(
        id: UUID,
        role: WebRTCSessionRole,
        peerConnection: any PeerConnectionProtocol,
        controlChannel: (any DataChannelProtocol)?,
        delegateAdapter: PeerConnectionDelegateAdapter,
        channelDelegate: DataChannelDelegateAdapter?,
        videoChannel: (any DataChannelProtocol)?,
        videoChannelDelegate: VideoChannelDelegateAdapter?
    ) {
        lock.lock()
        _sessionID = id
        _role = role
        _peerConnection = peerConnection
        _controlChannel = controlChannel
        _delegateAdapter = delegateAdapter
        _channelDelegateAdapter = channelDelegate
        _videoChannel = videoChannel
        _videoChannelDelegateAdapter = videoChannelDelegate
        _peerConnectionState = .new
        _dataChannelState = controlChannel?.readyState ?? .closed
        _streamDiagnostics = StreamDiagnostics()
        _latestVideoFrame = nil
        _latestBootstrapVideoFrame = nil
        _hasLoggedFirstVideoBytes = false
        _videoFragmentationEnabled = false
        _videoFECEnabled = false
        _lossGapEMA = 0
        _lossLastSeq = nil
        _lastClientLossPermille = 0
        lock.unlock()
    }

    private func storeAcceptedSessionID(_ sessionID: UUID) {
        lock.lock()
        _sessionID = sessionID
        lock.unlock()
    }

    private func snapshotAndResetSession() -> (
        peerConnection: (any PeerConnectionProtocol)?,
        controlChannel: (any DataChannelProtocol)?,
        videoChannel: (any DataChannelProtocol)?,
        sessionID: UUID?,
        forwardingTask: Task<Void, Never>?
    ) {
        lock.lock()
        let snapshot = (
            peerConnection: _peerConnection,
            controlChannel: _controlChannel,
            videoChannel: _videoChannel,
            sessionID: _sessionID,
            forwardingTask: _videoForwardingTask
        )
        _peerConnection = nil
        _controlChannel = nil
        _videoChannel = nil
        _sessionID = nil
        _role = nil
        _videoSource = nil
        _delegateAdapter = nil
        _channelDelegateAdapter = nil
        _videoChannelDelegateAdapter = nil
        _videoForwardingTask = nil
        _peerConnectionState = .closed
        _dataChannelState = .closed
        controlChannelAuthTokenHex = nil
        outboundControlAuthCounter = 0
        _latestVideoFrame = nil
        _latestBootstrapVideoFrame = nil
        _hasLoggedFirstVideoBytes = false
        _videoFragmentationEnabled = false
        _videoFECEnabled = false
        _lossGapEMA = 0
        _lossLastSeq = nil
        _lastClientLossPermille = 0
        lock.unlock()
        return snapshot
    }

    private func replaceVideoSource(_ source: (any VideoFrameSource)?) -> Task<Void, Never>? {
        lock.lock()
        let existingTask = _videoForwardingTask
        _videoForwardingTask = nil
        _videoSource = source
        lock.unlock()
        return existingTask
    }

    private func storeVideoForwardingTask(_ task: Task<Void, Never>) {
        lock.lock()
        _videoForwardingTask = task
        lock.unlock()
    }

    fileprivate func isCurrentPeerConnection(_ pc: any PeerConnectionProtocol) -> Bool {
        withLock {
            guard let current = _peerConnection else { return false }
            return ObjectIdentifier(current) == ObjectIdentifier(pc)
        }
    }

    fileprivate func isCurrentControlChannel(_ channel: any DataChannelProtocol) -> Bool {
        withLock {
            guard let current = _controlChannel else { return false }
            return ObjectIdentifier(current) == ObjectIdentifier(channel)
        }
    }

    fileprivate func isCurrentVideoChannel(_ channel: any DataChannelProtocol) -> Bool {
        withLock {
            guard let current = _videoChannel else { return false }
            return ObjectIdentifier(current) == ObjectIdentifier(channel)
        }
    }

    private func recordSentVideoFrame(byteCount: Int) {
        lock.lock()
        let isFirst = _streamDiagnostics.framesSent == 0
        _streamDiagnostics.framesSent += 1
        _streamDiagnostics.bytesSent += UInt64(byteCount)
        _streamDiagnostics.lastFrameSentAt = Date()
        lock.unlock()
        if isFirst {
            logger.info("First video frame sent over TCP: \(byteCount) bytes")
        }
    }
}

// MARK: - WebRTCSessionManaging

extension WebRTCSessionManager: WebRTCSessionManaging {

    // MARK: State Properties

    public var connectionState: ConnectionState {
        withLock { _connectionState }
    }

    public var peerConnectionState: PeerConnectionState {
        withLock { _peerConnectionState }
    }

    public var dataChannelState: DataChannelState {
        withLock { _dataChannelState }
    }

    public var mediaChannelReadiness: MediaChannelReadiness {
        withLock {
            MediaChannelReadiness(
                dataChannelState: _dataChannelState,
                videoTrackAttached: _videoSource != nil,
                audioTrackAttached: false
            )
        }
    }

    // MARK: Session Lifecycle

    public func prepareSession(id: UUID, role: WebRTCSessionRole) async throws {
        // A caller configures the freshly generated session token before preparing
        // the replacement peer. Closing an older peer resets per-session state,
        // including that token, so preserve and restore it across the teardown.
        // Without this, reconnects (and a second attempt after pairing approval)
        // create a tokenless TLS data listener and fail before SDP negotiation.
        let configuredSessionToken = withLock { controlChannelAuthTokenHex }
        let existing = withLock { _peerConnection }
        if existing != nil {
            await closeSession()
            configureControlChannelAuth(sessionTokenHex: configuredSessionToken)
        }

        let delegateAdapter = PeerConnectionDelegateAdapter(manager: self)
        let peerConnection: any PeerConnectionProtocol
        do {
            peerConnection = try peerConnectionProvider.makePeerConnection(
                configuration: configuration,
                delegate: delegateAdapter
            )
        } catch {
            throw WebRTCSessionError.peerConnectionFailed(error.localizedDescription)
        }

        // Host creates the data channels; client receives them via delegate
        var controlChannel: (any DataChannelProtocol)?
        var channelDelegate: DataChannelDelegateAdapter?
        var videoChannel: (any DataChannelProtocol)?
        var videoChanDelegate: VideoChannelDelegateAdapter?
        if role == .host {
            controlChannel = peerConnection.createDataChannel(.controlChannel)
            if let controlChannel {
                channelDelegate = DataChannelDelegateAdapter(manager: self)
                if let channelDelegate {
                    controlChannel.setDelegate(channelDelegate)
                }
            }
            videoChannel = peerConnection.createDataChannel(.videoChannel)
            if let videoChannel {
                videoChanDelegate = VideoChannelDelegateAdapter(manager: self)
                if let videoChanDelegate {
                    videoChannel.setDelegate(videoChanDelegate)
                }
            }
        }

        storePreparedState(
            id: id,
            role: role,
            peerConnection: peerConnection,
            controlChannel: controlChannel,
            delegateAdapter: delegateAdapter,
            channelDelegate: channelDelegate,
            videoChannel: videoChannel,
            videoChannelDelegate: videoChanDelegate
        )

        updateConnectionState(.connecting)
        logger.info("Session prepared: \(id.uuidString), role: \(role.rawValue)")
    }

    public func createOffer(
        sessionID: UUID,
        qualityPreset: StreamQualityPreset,
        displayID: String?
    ) async throws -> SessionOfferMessage {
        let pc = try ensurePrepared()

        let sdp = try await pc.createOffer(constraints: .defaultOffer)
        try await pc.setLocalDescription(sdp)

        logger.info("Offer created for session \(sessionID.uuidString)")
        return SessionOfferMessage(
            sessionID: sessionID,
            sdp: sdp.sdp,
            requestedDisplayID: displayID,
            qualityPreset: qualityPreset
        )
    }

    public func applyRemoteOffer(_ message: SessionOfferMessage) async throws -> SessionAnswerMessage {
        let pc = try ensurePrepared()

        let remoteSDP = SessionDescription(type: .offer, sdp: message.sdp)
        try await pc.setRemoteDescription(remoteSDP)

        let answerSDP = try await pc.createAnswer(constraints: .defaultAnswer)
        try await pc.setLocalDescription(answerSDP)

        storeAcceptedSessionID(message.sessionID)

        logger.info("Remote offer applied, answer created for session \(message.sessionID.uuidString)")
        return SessionAnswerMessage(
            sessionID: message.sessionID,
            sdp: answerSDP.sdp,
            acceptedDisplayID: message.requestedDisplayID
        )
    }

    public func applyRemoteAnswer(_ message: SessionAnswerMessage) async throws {
        let pc = try ensurePrepared()

        let remoteSDP = SessionDescription(type: .answer, sdp: message.sdp)
        try await pc.setRemoteDescription(remoteSDP)

        logger.info("Remote answer applied for session \(message.sessionID.uuidString)")
    }

    public func addRemoteCandidate(_ message: ICECandidateMessage) async throws {
        let pc = try ensurePrepared()

        let candidate = ICECandidate(
            sdpMid: message.sdpMid,
            sdpMLineIndex: message.sdpMLineIndex,
            candidate: message.candidate
        )
        try await pc.addICECandidate(candidate)
    }

    public func closeSession() async {
        let snapshot = snapshotAndResetSession()

        snapshot.forwardingTask?.cancel()
        snapshot.controlChannel?.close()
        snapshot.videoChannel?.close()
        snapshot.peerConnection?.close()
        updateConnectionState(.idle)
        updateDataChannelState(.closed)

        if let sessionID = snapshot.sessionID {
            logger.info("Session closed: \(sessionID.uuidString)")
        }
    }

    // MARK: Data Channel

    public func sendInputCommand(_ message: InputCommandMessage) async throws {
        let envelope = try DataChannelEnvelope.inputCommand(message)
        try sendDataMessage(envelope)
    }

    public func sendDataMessage(_ message: DataChannelEnvelope) throws {
        let dc = withLock { _controlChannel }
        guard let dc, dc.readyState == .open else {
            throw WebRTCSessionError.dataChannelUnavailable
        }
        var outbound = message
        if let token = withLock({ controlChannelAuthTokenHex }),
           message.kind.requiresControlChannelAuthentication {
            let counter = withLock { () -> UInt64 in
                outboundControlAuthCounter += 1
                return outboundControlAuthCounter
            }
            guard let authenticated = outbound.authenticated(using: token, counter: counter) else {
                throw WebRTCSessionError.invalidState("Failed to authenticate control envelope")
            }
            outbound = authenticated
        }
        let data = try outbound.wireEncode()
        let sent = dc.send(data)
        if !sent {
            throw WebRTCSessionError.dataChannelUnavailable
        }
    }

    public func configureControlChannelAuth(sessionTokenHex: String?) {
        withLock {
            controlChannelAuthTokenHex = sessionTokenHex
            outboundControlAuthCounter = 0
        }
        (peerConnectionProvider as? LANTransportSecurityConfigurable)?
            .configureTransportSecurity(sessionTokenHex: sessionTokenHex)
        (withLock { _peerConnection } as? LANTransportSecurityConfigurable)?
            .configureTransportSecurity(sessionTokenHex: sessionTokenHex)
    }

    public func receiveDataMessages() -> AsyncStream<DataChannelEnvelope> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let id = UUID()
            lock.lock()
            dataContinuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.dataContinuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    // MARK: ICE Candidate Output

    public func localICECandidates() -> AsyncStream<ICECandidateMessage> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let id = UUID()
            lock.lock()
            iceContinuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.iceContinuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    // MARK: Media

    public func attachVideoSource(_ source: (any VideoFrameSource)?) {
        let oldTask = replaceVideoSource(source)

        oldTask?.cancel()

        if let producer = source as? any VideoFrameProducer {
            let task = Task { [weak self] in
                for await frame in producer.videoFrames() {
                    guard !Task.isCancelled else { break }
                    guard let self else { break }
                    try? self.sendVideoFrame(frame)
                }
            }
            storeVideoForwardingTask(task)
        }

        if let source {
            logger.info("Video source attached: \(source.sourceID)")
        } else {
            logger.info("Video source detached")
        }
    }

    // MARK: Video Frame Transport

    public func sendVideoFrame(_ frame: VideoFrameData) throws {
        let (vc, fragmentationEnabled, fecEnabled) = withLock {
            (_videoChannel, _videoFragmentationEnabled, _videoFECEnabled)
        }
        guard let vc, vc.readyState == .open else {
            throw WebRTCSessionError.dataChannelUnavailable
        }
        if !frame.isKeyframe, vc.bufferedAmount > 8 * 1024 * 1024 {
            throw WebRTCSessionError.invalidState("Video channel backpressure limit reached")
        }
        let packets = fragmentationEnabled
            ? frame.wirePackets(maxPacketBytes: maxVideoPacketBytes, fec: fecEnabled)
            : [frame.wireEncode()]
        guard !packets.isEmpty else {
            throw WebRTCSessionError.invalidState("Video frame exceeds fragmentation limits")
        }
        var bytesSent = 0
        for packet in packets {
            guard vc.send(packet) else {
                throw WebRTCSessionError.dataChannelUnavailable
            }
            bytesSent += packet.count
        }
        recordSentVideoFrame(byteCount: bytesSent)
    }

    public func receivedVideoFrames() -> AsyncStream<VideoFrameData> {
        // The video channel is unordered + unreliable, so the network already drops
        // frames in transit. The decode consumer here only *dispatches* each frame to
        // a background decode queue (it doesn't block), so this stream does not back
        // up in practice. Use an unbounded buffer so we never additionally drop a
        // frame — especially a reassembled keyframe — at this layer.
        AsyncStream(VideoFrameData.self, bufferingPolicy: .unbounded) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let id = UUID()
            let cachedFrames: [VideoFrameData]
            lock.lock()
            videoFrameContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.videoFrameContinuations[id] = nil
                let remaining = self.videoFrameContinuations.count
                self.lock.unlock()
                self.logger.info("receivedVideoFrames: subscriber removed (remaining=\(remaining))")
            }
            var snapshots: [VideoFrameData] = []
            if let bootstrap = _latestBootstrapVideoFrame {
                snapshots.append(bootstrap)
            }
            if let latest = _latestVideoFrame,
               latest.sequenceNumber != snapshots.last?.sequenceNumber {
                snapshots.append(latest)
            }
            cachedFrames = snapshots
            let subscriberCount = videoFrameContinuations.count
            lock.unlock()
            logger.info("receivedVideoFrames: subscriber registered (total=\(subscriberCount), replaying \(cachedFrames.count) cached frame(s))")
            for frame in cachedFrames {
                continuation.yield(frame)
            }
        }
    }

    public var streamDiagnostics: StreamDiagnostics {
        withLock { _streamDiagnostics }
    }

    public var videoBufferedAmount: UInt64 {
        withLock { _videoChannel?.bufferedAmount ?? 0 }
    }

    public func configureVideoTransport(fragmentationEnabled: Bool, fecEnabled: Bool) {
        withLock {
            _videoFragmentationEnabled = fragmentationEnabled
            // FEC needs fragmentation (parity covers multi-fragment frames).
            _videoFECEnabled = fragmentationEnabled && fecEnabled
        }
    }

    /// Receiver-side: this client's current downlink video loss estimate (0–1000‰).
    /// Idempotent read — safe to sample from any/many ping paths.
    public var recentVideoLossPermille: Int {
        withLock {
            let g = _lossGapEMA
            return max(0, min(1000, Int((g / (g + 1) * 1000).rounded())))
        }
    }

    /// Sender-side: record the loss the remote receiver just reported (host's adaptive
    /// bitrate reads `lastReportedClientLossPermille`).
    public func recordClientLossReport(_ permille: Int) {
        withLock { _lastClientLossPermille = max(0, min(1000, permille)) }
    }

    public var lastReportedClientLossPermille: Int {
        withLock { _lastClientLossPermille }
    }

    public var videoFrameSubscriberCount: Int {
        withLock { videoFrameContinuations.count }
    }

    // MARK: Observation

    public func connectionStateUpdates() -> AsyncStream<ConnectionState> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let id = UUID()
            lock.lock()
            stateContinuations[id] = continuation
            let current = _connectionState
            lock.unlock()
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.stateContinuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    public func dataChannelStateUpdates() -> AsyncStream<DataChannelState> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let id = UUID()
            lock.lock()
            dataStateContinuations[id] = continuation
            let current = _dataChannelState
            lock.unlock()
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.dataStateContinuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    public func videoChannelStateUpdates() -> AsyncStream<DataChannelState> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let id = UUID()
            lock.lock()
            videoChannelStateContinuations[id] = continuation
            let currentVC = _videoChannel
            lock.unlock()
            // Replay current state so the observer doesn't miss a channel that
            // already opened before the subscription was registered.
            if let vc = currentVC {
                continuation.yield(vc.readyState)
            } else {
                continuation.yield(.closed)
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.videoChannelStateContinuations[id] = nil
                self?.lock.unlock()
            }
        }
    }
}

// MARK: - Peer Connection Delegate Adapter

/// Routes PeerConnectionDelegate callbacks into the session manager's state.
private final class PeerConnectionDelegateAdapter: PeerConnectionDelegate, @unchecked Sendable {
    private weak var manager: WebRTCSessionManager?

    init(manager: WebRTCSessionManager) {
        self.manager = manager
    }

    func peerConnection(_ pc: any PeerConnectionProtocol, didChangeConnectionState state: PeerConnectionState) {
        guard let manager else { return }
        guard manager.isCurrentPeerConnection(pc) else {
            manager.logger.debug("Ignoring stale peer-connection state: \(state.rawValue)")
            return
        }
        manager.lock.lock()
        manager._peerConnectionState = state
        manager.lock.unlock()
        let mapped = manager.mapPeerStateToConnectionState(state)
        manager.updateConnectionState(mapped)
    }

    func peerConnection(_ pc: any PeerConnectionProtocol, didChangeICEConnectionState state: ICEConnectionState) {
        guard let manager, manager.isCurrentPeerConnection(pc) else { return }
        // ICE state is informational; peer connection state drives the primary state
        manager.logger.debug("ICE connection state: \(state.rawValue)")
    }

    func peerConnection(_ pc: any PeerConnectionProtocol, didChangeICEGatheringState state: ICEGatheringState) {
        guard let manager, manager.isCurrentPeerConnection(pc) else { return }
        manager.logger.debug("ICE gathering state: \(state.rawValue)")
    }

    func peerConnection(_ pc: any PeerConnectionProtocol, didGenerateICECandidate candidate: ICECandidate) {
        guard let manager else { return }
        guard manager.isCurrentPeerConnection(pc) else { return }
        let sessionID = manager.withLock { manager._sessionID } ?? UUID()
        let message = ICECandidateMessage(
            sessionID: sessionID,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
            candidate: candidate.candidate
        )
        manager.lock.lock()
        let continuations = Array(manager.iceContinuations.values)
        manager.lock.unlock()
        for c in continuations { c.yield(message) }
    }

    func peerConnection(_ pc: any PeerConnectionProtocol, didOpenDataChannel channel: any DataChannelProtocol) {
        guard let manager else { return }
        guard manager.isCurrentPeerConnection(pc) else { return }

        if channel.label == "video" {
            let videoDelegate = VideoChannelDelegateAdapter(manager: manager)
            channel.setDelegate(videoDelegate)
            manager.lock.lock()
            manager._videoChannel = channel
            manager._videoChannelDelegateAdapter = videoDelegate
            manager.lock.unlock()
            manager.logger.info("Remote video data channel opened")
            manager.updateVideoChannelState(.open)
        } else {
            let channelDelegate = DataChannelDelegateAdapter(manager: manager)
            channel.setDelegate(channelDelegate)
            manager.lock.lock()
            manager._controlChannel = channel
            manager._channelDelegateAdapter = channelDelegate
            manager.lock.unlock()
            manager.updateDataChannelState(channel.readyState)
            manager.logger.info("Remote data channel opened: \(channel.label)")
        }
    }
}

// MARK: - Data Channel Delegate Adapter

/// Routes DataChannelDelegate callbacks into the session manager's state.
private final class DataChannelDelegateAdapter: DataChannelDelegate, @unchecked Sendable {
    private weak var manager: WebRTCSessionManager?

    init(manager: WebRTCSessionManager) {
        self.manager = manager
    }

    func dataChannel(_ channel: any DataChannelProtocol, didReceiveData data: Data) {
        guard let manager else { return }
        guard manager.isCurrentControlChannel(channel) else { return }
        if data.count > manager.maxInboundControlMessageBytes {
            manager.logger.warning("Dropped oversized data-channel message: \(data.count) bytes")
            return
        }
        do {
            let envelope = try DataChannelEnvelope.wireDecode(data)
            manager.lock.lock()
            let continuations = Array(manager.dataContinuations.values)
            manager.lock.unlock()
            for c in continuations { c.yield(envelope) }
        } catch {
            manager.logger.error("Failed to decode data channel message: \(error.localizedDescription)")
        }
    }

    func dataChannel(_ channel: any DataChannelProtocol, didChangeState state: DataChannelState) {
        guard let manager else { return }
        guard manager.isCurrentControlChannel(channel) else { return }
        manager.updateDataChannelState(state)
        manager.logger.info("Data channel state: \(state.rawValue)")
    }
}

// MARK: - Video Channel Delegate Adapter

/// Routes video data channel callbacks into the session manager's video frame stream.
private final class VideoChannelDelegateAdapter: DataChannelDelegate, @unchecked Sendable {
    private weak var manager: WebRTCSessionManager?

    init(manager: WebRTCSessionManager) {
        self.manager = manager
    }

    func dataChannel(_ channel: any DataChannelProtocol, didReceiveData data: Data) {
        guard let manager else { return }
        guard manager.isCurrentVideoChannel(channel) else { return }
        do {
            guard let frame = try manager.videoFrameReassembler.ingest(data) else {
                return
            }
            // Untrusted timestamp: a non-finite (NaN/inf) presentationTimestamp can stall or crash
            // the decoder/renderer pacing. Drop such frames rather than feeding them downstream.
            guard frame.presentationTimestamp.isFinite else {
                manager.logger.warning("Dropped video frame with non-finite presentationTimestamp")
                return
            }
            manager.lock.lock()
            if !manager._hasLoggedFirstVideoBytes {
                manager._hasLoggedFirstVideoBytes = true
                manager.logger.info(
                    "First video bytes received: \(data.count) bytes, codec=\(frame.codec.rawValue), seq=\(frame.sequenceNumber)"
                )
            }
            manager._streamDiagnostics.framesReceived += 1
            manager._streamDiagnostics.bytesReceived += UInt64(data.count)
            // Update downlink loss EMA from sequence-number gaps. Only count forward jumps;
            // an out-of-order/duplicate frame (seq <= last) isn't a loss.
            if let last = manager._lossLastSeq {
                if frame.sequenceNumber > last {
                    let gap = Double(frame.sequenceNumber - last - 1)
                    manager._lossGapEMA = manager._lossGapEMA * 0.9 + gap * 0.1
                    manager._lossLastSeq = frame.sequenceNumber
                }
            } else {
                manager._lossLastSeq = frame.sequenceNumber
            }
            if manager._streamDiagnostics.firstFrameReceivedAt == nil {
                manager._streamDiagnostics.firstFrameReceivedAt = Date()
            }
            manager._streamDiagnostics.lastFrameReceivedAt = Date()
            manager._streamDiagnostics.receivingState = .receiving
            manager._latestVideoFrame = frame
            if frame.isKeyframe, frame.parameterSets != nil {
                manager._streamDiagnostics.keyframesReceived += 1
                manager._latestBootstrapVideoFrame = frame
            }
            let continuations = Array(manager.videoFrameContinuations.values)
            let totalReceived = manager._streamDiagnostics.framesReceived
            manager.lock.unlock()
            // Log at frame 1, 5, 30 so the first few seconds of an empty-subscriber
            // state are visible in production logs without spamming on every frame.
            if continuations.isEmpty && (totalReceived == 1 || totalReceived == 5 || totalReceived == 30) {
                manager.logger.warning(
                    "Video frame arrived but videoFrameContinuations is EMPTY (framesReceived=\(totalReceived)) — view subscribers not yet registered or were cancelled"
                )
            }
            for c in continuations { c.yield(frame) }
        } catch {
            manager.logger.error("Failed to decode video frame: \(error.localizedDescription)")
        }
    }

    func dataChannel(_ channel: any DataChannelProtocol, didChangeState state: DataChannelState) {
        guard let manager else { return }
        guard manager.isCurrentVideoChannel(channel) else { return }
        if state == .open {
            manager.lock.lock()
            if manager._streamDiagnostics.receivingState == .idle {
                manager._streamDiagnostics.receivingState = .waitingForFirstFrame
            }
            manager.lock.unlock()
        }
        manager.logger.info("Video data channel state: \(state.rawValue)")
        manager.updateVideoChannelState(state)
    }
}
