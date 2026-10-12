import Foundation
import SharedModels
import SharedProtocol
import TransportWebRTC

public protocol SessionCoordinatorSignaling: SignalingServiceProtocol, WebRTCSignalingTransport {
    func startListening(port: UInt16) throws -> UInt16
    func stopListening()
    func connect(host: String, port: UInt16) async throws
    func disconnect()
    /// Cancel the current peer connection without stopping the listener or finishing
    /// the message stream.  On the host this clears the accepted server connection;
    /// on the client it clears the outgoing connection.  The listener keeps running
    /// so a new peer can connect afterwards.
    func dropCurrentConnection()
}
