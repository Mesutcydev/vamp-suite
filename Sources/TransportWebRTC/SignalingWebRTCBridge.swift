import Foundation
import SharedModels
import SharedProtocol
import os

// MARK: - WebRTC Signaling Transport

/// Minimal signaling interface needed by the WebRTC bridge.
/// App-layer code adapts the full `SignalingServiceProtocol` to this.
public protocol WebRTCSignalingTransport: AnyObject, Sendable {
    func sendSignalingMessage(_ message: VersionedSignalingMessage) async throws
    func incomingSignalingMessages() -> AsyncThrowingStream<VersionedSignalingMessage, Error>
}

// MARK: - Bridge Events

/// Events emitted by the signaling bridge for the app layer to observe.
public enum SignalingBridgeEvent: Sendable {
    case offerReceived(SessionOfferMessage)
    case answerSent(SessionAnswerMessage)
    case offerSent(SessionOfferMessage)
    case answerReceived(SessionAnswerMessage)
    case iceCandidateExchanged
    case sessionReady(SessionReadyMessage)
    case error(String)
}

// MARK: - Signaling WebRTC Bridge

/// Bridges the signaling layer to the WebRTC session manager.
/// Routes offer/answer/ICE messages between signaling and the peer connection.
/// Emits local ICE candidates from the session manager to the signaling channel.
public final class SignalingWebRTCBridge: @unchecked Sendable {
    private let sessionManager: any WebRTCSessionManaging
    private let signalingTransport: any WebRTCSignalingTransport
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.remotedesktop.transport", category: "SignalingBridge")

    private var activeTasks: [Task<Void, Never>] = []
    private var _sessionID: UUID?
    private var _role: WebRTCSessionRole?
    private var _localPeer: SignalingPeer?
    private var _remotePeer: SignalingPeer?

    // Bridge event continuations
    private var eventContinuations: [UUID: AsyncStream<SignalingBridgeEvent>.Continuation] = [:]

    public init(
        sessionManager: any WebRTCSessionManaging,
        signalingTransport: any WebRTCSignalingTransport
    ) {
        self.sessionManager = sessionManager
        self.signalingTransport = signalingTransport
    }

    deinit {
        stopAll()
    }

    // MARK: - Start / Stop

    /// Start the bridge for a given session.
    /// - Parameters:
    ///   - sessionID: The session ID for message routing.
    ///   - role: Whether this side is host or client.
    ///   - localPeer: The local peer identity for outgoing envelope headers.
    ///   - remotePeer: The remote peer identity (if known).
    public func start(
        sessionID: UUID,
        role: WebRTCSessionRole,
        localPeer: SignalingPeer,
        remotePeer: SignalingPeer? = nil
    ) {
        lock.lock()
        _sessionID = sessionID
        _role = role
        _localPeer = localPeer
        _remotePeer = remotePeer
        lock.unlock()

        // Listen for incoming signaling messages
        let incomingTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in signalingTransport.incomingSignalingMessages() {
                    await self.handleIncomingSignalingMessage(message)
                }
            } catch {
                if !Task.isCancelled {
                    self.logger.error("Signaling receive error: \(error.localizedDescription)")
                    self.emitEvent(.error(error.localizedDescription))
                }
            }
        }

        // Forward local ICE candidates to signaling
        let iceTask = Task { [weak self] in
            guard let self else { return }
            for await candidate in sessionManager.localICECandidates() {
                do {
                    let envelope = self.makeEnvelope(event: .iceCandidate(candidate))
                    try await signalingTransport.sendSignalingMessage(envelope)
                } catch {
                    if !Task.isCancelled {
                        self.logger.error("Failed to send ICE candidate: \(error.localizedDescription)")
                    }
                }
            }
        }

        lock.lock()
        activeTasks.append(contentsOf: [incomingTask, iceTask])
        lock.unlock()

        logger.info("Signaling bridge started for session \(sessionID.uuidString), role: \(role.rawValue)")
    }

    /// Stop all bridge activity.
    public func stop() {
        stopAll()
        logger.info("Signaling bridge stopped")
    }

    /// Observe bridge events.
    public func events() -> AsyncStream<SignalingBridgeEvent> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let id = UUID()
            lock.lock()
            eventContinuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.eventContinuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    // MARK: - Incoming Message Handling

    private func handleIncomingSignalingMessage(_ message: VersionedSignalingMessage) async {
        let event = message.envelope.event

        // Track remote peer from incoming messages
        setRemotePeerIfNeeded(message.envelope.sender)

        switch event {
        case .offer(let offer):
            await handleRemoteOffer(offer)

        case .answer(let answer):
            await handleRemoteAnswer(answer)

        case .iceCandidate(let candidate):
            await handleRemoteICECandidate(candidate)

        case .sessionReady(let ready):
            emitEvent(.sessionReady(ready))

        case .permissionBlocked, .hostBusy, .reconnecting, .displayLayoutChanged, .streamRestartRequired:
            // These are informational; the app layer handles them directly
            break
        }
    }

    private func handleRemoteOffer(_ offer: SessionOfferMessage) async {
        let role = lock.withLock { _role }
        guard role == .host else {
            logger.warning("Client received an offer — ignoring")
            return
        }

        do {
            emitEvent(.offerReceived(offer))
            let answer = try await sessionManager.applyRemoteOffer(offer)

            let envelope = makeEnvelope(event: .answer(answer))
            try await signalingTransport.sendSignalingMessage(envelope)
            emitEvent(.answerSent(answer))
        } catch {
            logger.error("Failed to handle remote offer: \(error.localizedDescription)")
            emitEvent(.error(error.localizedDescription))
        }
    }

    private func handleRemoteAnswer(_ answer: SessionAnswerMessage) async {
        let role = lock.withLock { _role }
        guard role == .client else {
            logger.warning("Host received an answer — ignoring")
            return
        }

        do {
            try await sessionManager.applyRemoteAnswer(answer)
            emitEvent(.answerReceived(answer))
        } catch {
            logger.error("Failed to apply remote answer: \(error.localizedDescription)")
            emitEvent(.error(error.localizedDescription))
        }
    }

    private func handleRemoteICECandidate(_ candidate: ICECandidateMessage) async {
        do {
            try await sessionManager.addRemoteCandidate(candidate)
            emitEvent(.iceCandidateExchanged)
        } catch {
            logger.error("Failed to add remote ICE candidate: \(error.localizedDescription)")
        }
    }

    // MARK: - Client-side: Send Offer

    /// Client convenience: create and send an offer through signaling.
    public func sendOffer(
        sessionID: UUID,
        qualityPreset: StreamQualityPreset,
        displayID: String?
    ) async throws {
        let offer = try await sessionManager.createOffer(
            sessionID: sessionID,
            qualityPreset: qualityPreset,
            displayID: displayID
        )
        let envelope = makeEnvelope(event: .offer(offer))
        try await signalingTransport.sendSignalingMessage(envelope)
        emitEvent(.offerSent(offer))
    }

    // MARK: - Envelope Helpers

    private func makeEnvelope(event: SignalingEvent) -> VersionedSignalingMessage {
        let info = lock.withLock { (_sessionID, _localPeer, _remotePeer) }
        let envelope = SignalingEnvelope(
            protocolVersion: 1,
            sessionID: info.0,
            sender: info.1 ?? SignalingPeer(id: UUID(), role: .host),
            recipient: info.2,
            event: event
        )
        return VersionedSignalingMessage(envelope: envelope)
    }

    private func emitEvent(_ event: SignalingBridgeEvent) {
        lock.lock()
        let continuations = Array(eventContinuations.values)
        lock.unlock()
        for c in continuations { c.yield(event) }
    }

    private func setRemotePeerIfNeeded(_ peer: SignalingPeer) {
        lock.lock()
        if _remotePeer == nil {
            _remotePeer = peer
        }
        lock.unlock()
    }

    private func stopAll() {
        lock.lock()
        let tasks = activeTasks
        activeTasks.removeAll()
        eventContinuations.values.forEach { $0.finish() }
        eventContinuations.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }
}

// MARK: - NSLock convenience

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
