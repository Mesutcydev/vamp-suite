import Foundation
import SharedModels
import SharedProtocol

public protocol DiscoveryServiceProtocol {
    func startBrowsing() async throws
    func stopBrowsing() async
    func discoveredHosts() async -> [HostIdentity]
    func resolvedHostEndpoints() async -> [ResolvedHostEndpoint]
}

public extension DiscoveryServiceProtocol {
    func resolvedHostEndpoints() async -> [ResolvedHostEndpoint] {
        []
    }
}

public protocol SignalingServiceProtocol {
    func startAdvertising(host: HostIdentity) async throws
    func stopAdvertising() async
    func send(_ message: VersionedSignalingMessage) async throws
    func receiveMessages() -> AsyncThrowingStream<VersionedSignalingMessage, Error>
    func sendHello(_ message: HelloMessage, to host: HostIdentity) async throws
    func sendOffer(_ message: SessionOfferMessage, to host: HostIdentity) async throws
    func sendAnswer(_ message: SessionAnswerMessage, to client: ClientIdentity) async throws
    func sendCandidate(_ message: ICECandidateMessage) async throws
}

public extension SignalingServiceProtocol {
    func send(_ message: VersionedSignalingMessage) async throws {}

    func receiveMessages() -> AsyncThrowingStream<VersionedSignalingMessage, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
