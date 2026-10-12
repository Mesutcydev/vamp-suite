import Foundation
import SharedModels
import SharedProtocol

/// Pure-logic heartbeat service that sends pings and monitors pongs
/// over the data channel to detect stale sessions.
///
/// The service is protocol-based: callers provide a `HeartbeatTransport`
/// to actually send/receive envelopes. This keeps it testable without
/// real WebRTC dependencies.
public actor HeartbeatService {

    // MARK: - Configuration

    public struct Configuration: Sendable, Hashable {
        public var pingInterval: TimeInterval
        public var pongTimeout: TimeInterval
        public var maxMissedPongs: Int

        public init(
            pingInterval: TimeInterval = 3.0,
            pongTimeout: TimeInterval = 5.0,
            maxMissedPongs: Int = 3
        ) {
            self.pingInterval = pingInterval
            self.pongTimeout = pongTimeout
            self.maxMissedPongs = maxMissedPongs
        }
    }

    // MARK: - State

    public enum HeartbeatState: String, Sendable, Hashable {
        case idle
        case running
        case stale
        case stopped
    }

    // MARK: - Transport Protocol

    public protocol HeartbeatTransport: Sendable {
        func sendPing(_ message: PingMessage) async throws
        func sendPong(_ message: PongMessage) async throws
    }

    // MARK: - Properties

    private let configuration: Configuration
    private let transport: any HeartbeatTransport

    private var state: HeartbeatState = .idle
    private var pingTask: Task<Void, Never>?
    private var lastPongReceivedAt: Date?
    private var missedPongCount: Int = 0
    private var totalPingsSent: UInt64 = 0
    private var totalPongsReceived: UInt64 = 0
    private var stateStreamContinuation: AsyncStream<HeartbeatState>.Continuation?

    public init(configuration: Configuration = Configuration(), transport: any HeartbeatTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    // MARK: - Lifecycle

    public func start() {
        guard state == .idle || state == .stopped else { return }
        state = .running
        missedPongCount = 0
        lastPongReceivedAt = Date()
        stateStreamContinuation?.yield(.running)

        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendPingAndCheck()
                try? await Task.sleep(nanoseconds: UInt64(self.configuration.pingInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        pingTask?.cancel()
        pingTask = nil
        state = .stopped
        stateStreamContinuation?.yield(.stopped)
    }

    /// Call when a pong is received from the remote peer.
    public func receivedPong(_ pong: PongMessage) {
        lastPongReceivedAt = Date()
        missedPongCount = 0
        totalPongsReceived += 1
        if state == .stale {
            state = .running
            stateStreamContinuation?.yield(.running)
        }
    }

    /// Call when a ping is received from the remote peer — reply with a pong.
    public func receivedPing(_ ping: PingMessage) async {
        let pong = PongMessage(id: ping.id, sentAt: ping.sentAt)
        try? await transport.sendPong(pong)
    }

    // MARK: - Observation

    public func stateUpdates() -> AsyncStream<HeartbeatState> {
        AsyncStream { continuation in
            self.stateStreamContinuation = continuation
            continuation.yield(self.state)
            continuation.onTermination = { _ in
                Task { await self.clearContinuation() }
            }
        }
    }

    private func clearContinuation() {
        stateStreamContinuation = nil
    }

    // MARK: - Diagnostics

    public var currentState: HeartbeatState { state }
    public var pingsSent: UInt64 { totalPingsSent }
    public var pongsReceived: UInt64 { totalPongsReceived }
    public var currentMissedPongs: Int { missedPongCount }

    // MARK: - Internal

    private func sendPingAndCheck() {
        let ping = PingMessage()
        Task {
            do {
                try await transport.sendPing(ping)
                totalPingsSent += 1
            } catch {
                // Transport failure — will be caught by missed pong logic
            }
        }

        // Check staleness
        if let lastPong = lastPongReceivedAt {
            let elapsed = Date().timeIntervalSince(lastPong)
            if elapsed > configuration.pongTimeout {
                missedPongCount += 1
                if missedPongCount >= configuration.maxMissedPongs && state != .stale {
                    state = .stale
                    stateStreamContinuation?.yield(.stale)
                }
            }
        }
    }
}
