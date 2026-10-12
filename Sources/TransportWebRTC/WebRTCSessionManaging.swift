import Foundation
import SharedModels
import SharedProtocol

public enum WebRTCSessionRole: String, Codable, Hashable, Sendable {
    case host
    case client
}

public enum WebRTCSessionError: Error, LocalizedError, Sendable {
    case notPrepared
    case alreadyActive
    case peerConnectionFailed(String)
    case dataChannelUnavailable
    case sdpCreationFailed(String)
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .notPrepared: return "Session not prepared."
        case .alreadyActive: return "A session is already active."
        case .peerConnectionFailed(let r): return "Peer connection failed: \(r)"
        case .dataChannelUnavailable: return "Data channel not available."
        case .sdpCreationFailed(let r): return "SDP creation failed: \(r)"
        case .invalidState(let r): return "Invalid state: \(r)"
        }
    }
}

// MARK: - WebRTC Session Managing Protocol

public protocol WebRTCSessionManaging: AnyObject {
    // MARK: State

    /// High-level connection state (maps to the app's ConnectionState).
    var connectionState: ConnectionState { get }

    /// Detailed peer connection state.
    var peerConnectionState: PeerConnectionState { get }

    /// Current data channel readiness.
    var dataChannelState: DataChannelState { get }

    /// Combined media/data channel readiness.
    var mediaChannelReadiness: MediaChannelReadiness { get }

    // MARK: Session Lifecycle

    /// Prepare a new session: creates the peer connection and data channel.
    func prepareSession(id: UUID, role: WebRTCSessionRole) async throws

    /// Client-side: generate an SDP offer from the prepared peer connection.
    func createOffer(
        sessionID: UUID,
        qualityPreset: StreamQualityPreset,
        displayID: String?
    ) async throws -> SessionOfferMessage

    /// Host-side: apply a remote offer and produce an SDP answer.
    func applyRemoteOffer(_ message: SessionOfferMessage) async throws -> SessionAnswerMessage

    /// Client-side: apply the host's SDP answer.
    func applyRemoteAnswer(_ message: SessionAnswerMessage) async throws

    /// Add a remote ICE candidate to the peer connection.
    func addRemoteCandidate(_ message: ICECandidateMessage) async throws

    /// Tear down the session and peer connection.
    func closeSession() async

    // MARK: Data Channel

    /// Send an input command over the data channel.
    func sendInputCommand(_ message: InputCommandMessage) async throws

    /// Send a typed data channel message.
    func sendDataMessage(_ message: DataChannelEnvelope) throws

    /// Configure per-envelope authentication for outbound control-channel messages.
    /// Pass nil to disable and clear authentication state.
    func configureControlChannelAuth(sessionTokenHex: String?)

    /// Async stream of incoming data channel messages.
    func receiveDataMessages() -> AsyncStream<DataChannelEnvelope>

    // MARK: ICE Candidate Output

    /// Async stream of locally-generated ICE candidates (to be sent via signaling).
    func localICECandidates() -> AsyncStream<ICECandidateMessage>

    // MARK: Media

    /// Attach or detach a video frame source for the media stream.
    /// If the source conforms to `VideoFrameProducer`, frames are auto-forwarded
    /// over the video data channel.
    func attachVideoSource(_ source: (any VideoFrameSource)?)

    // MARK: Video Frame Transport

    /// Send an encoded video frame over the video data channel.
    func sendVideoFrame(_ frame: VideoFrameData) throws

    /// Async stream of video frames received from the remote peer.
    func receivedVideoFrames() -> AsyncStream<VideoFrameData>

    /// Current stream diagnostics (frame counts, receiving state, stall detection).
    var streamDiagnostics: StreamDiagnostics { get }

    /// Bytes queued on the outbound video channel and not yet completed by the
    /// underlying transport.
    var videoBufferedAmount: UInt64 { get }

    /// Enables the fragmented video packet format and, when the client negotiated it,
    /// XOR FEC parity packets — after peer capability negotiation. Older peers continue
    /// receiving whole-frame packets with no parity.
    func configureVideoTransport(fragmentationEnabled: Bool, fecEnabled: Bool)

    /// Receiver-side downlink video loss estimate (0–1000‰), reported to the host so its
    /// adaptive bitrate can respond to real loss, not just send-queue pressure.
    var recentVideoLossPermille: Int { get }

    /// Sender-side: record/read the loss the remote receiver reported.
    func recordClientLossReport(_ permille: Int)
    var lastReportedClientLossPermille: Int { get }

    /// Number of active video frame subscribers (continuations registered via `receivedVideoFrames()`).
    /// Used for diagnostics — zero means no view is consuming the video stream.
    var videoFrameSubscriberCount: Int { get }

    // MARK: Observation

    /// Async stream of connection state updates.
    func connectionStateUpdates() -> AsyncStream<ConnectionState>

    /// Async stream of control data-channel state updates.
    func dataChannelStateUpdates() -> AsyncStream<DataChannelState>

    /// Async stream of video data-channel state updates.
    /// Yields the current state immediately on subscription, then on every change.
    /// The host uses this to detect when the video channel opens so it can force
    /// an immediate keyframe — preventing the silent-drop race where a keyframe
    /// is encoded before the channel is ready.
    func videoChannelStateUpdates() -> AsyncStream<DataChannelState>
}

public extension WebRTCSessionManaging {
    var videoBufferedAmount: UInt64 { 0 }
    func configureVideoTransport(fragmentationEnabled: Bool, fecEnabled: Bool) {}
    var recentVideoLossPermille: Int { 0 }
    func recordClientLossReport(_ permille: Int) {}
    var lastReportedClientLossPermille: Int { 0 }
}
