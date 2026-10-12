import Foundation

// MARK: - Peer Connection Factory

/// Factory protocol for creating peer connections.
/// A concrete adapter wrapping the real WebRTC SDK conforms to this.
public protocol PeerConnectionProviding: Sendable {
    func makePeerConnection(
        configuration: WebRTCConfiguration,
        delegate: any PeerConnectionDelegate
    ) throws -> any PeerConnectionProtocol
}

// MARK: - Peer Connection

/// App-owned abstraction over a WebRTC peer connection.
/// Isolates all raw WebRTC types behind this interface.
public protocol PeerConnectionProtocol: AnyObject {
    var localDescription: SessionDescription? { get }
    var remoteDescription: SessionDescription? { get }
    var connectionState: PeerConnectionState { get }
    var iceConnectionState: ICEConnectionState { get }
    var iceGatheringState: ICEGatheringState { get }

    func createOffer(constraints: MediaConstraints?) async throws -> SessionDescription
    func createAnswer(constraints: MediaConstraints?) async throws -> SessionDescription
    func setLocalDescription(_ sdp: SessionDescription) async throws
    func setRemoteDescription(_ sdp: SessionDescription) async throws
    func addICECandidate(_ candidate: ICECandidate) async throws

    func createDataChannel(_ config: DataChannelConfiguration) -> (any DataChannelProtocol)?
    func addVideoTrack(_ track: any VideoTrackProtocol)
    func removeVideoTrack(_ track: any VideoTrackProtocol)

    func close()
}

// MARK: - Peer Connection Delegate

/// Receives state change callbacks from the peer connection.
public protocol PeerConnectionDelegate: AnyObject, Sendable {
    func peerConnection(_ pc: any PeerConnectionProtocol, didChangeConnectionState state: PeerConnectionState)
    func peerConnection(_ pc: any PeerConnectionProtocol, didChangeICEConnectionState state: ICEConnectionState)
    func peerConnection(_ pc: any PeerConnectionProtocol, didChangeICEGatheringState state: ICEGatheringState)
    func peerConnection(_ pc: any PeerConnectionProtocol, didGenerateICECandidate candidate: ICECandidate)
    func peerConnection(_ pc: any PeerConnectionProtocol, didOpenDataChannel channel: any DataChannelProtocol)
}

// MARK: - Data Channel

/// App-owned abstraction over a WebRTC data channel.
public protocol DataChannelProtocol: AnyObject {
    var label: String { get }
    var readyState: DataChannelState { get }
    /// Bytes accepted by the channel but not yet completed by the underlying
    /// transport. This is the sender-side backpressure signal.
    var bufferedAmount: UInt64 { get }

    func send(_ data: Data) -> Bool
    func close()
    func setDelegate(_ delegate: any DataChannelDelegate)
}

public extension DataChannelProtocol {
    var bufferedAmount: UInt64 { 0 }
}

/// Receives data and state changes from a data channel.
public protocol DataChannelDelegate: AnyObject, Sendable {
    func dataChannel(_ channel: any DataChannelProtocol, didReceiveData data: Data)
    func dataChannel(_ channel: any DataChannelProtocol, didChangeState state: DataChannelState)
}

// MARK: - Video Track

/// App-owned abstraction over a WebRTC video track.
/// Concrete implementation wraps the SDK's video track/source.
public protocol VideoTrackProtocol: AnyObject {
    var trackID: String { get }
    var isEnabled: Bool { get set }
}
