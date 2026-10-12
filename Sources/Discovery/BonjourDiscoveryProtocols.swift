import Foundation
import SharedModels

public enum BonjourDiscoveryEvent: Hashable, Sendable {
    case found(ResolvedHostEndpoint)
    case updated(ResolvedHostEndpoint)
    case removed(UUID)
    case failed(String)
}

public protocol BonjourDiscoveryBrowsing {
    func startBrowsing(serviceType: String, domain: String) async throws
    func stopBrowsing() async
    func resolvedHosts() async -> [ResolvedHostEndpoint]
    func events() -> AsyncStream<BonjourDiscoveryEvent>
}

public protocol BonjourHostAdvertising {
    func startAdvertising(
        serviceType: String,
        domain: String,
        metadata: HostAdvertisementMetadata
    ) async throws

    func stopAdvertising() async
}

public extension BonjourDiscoveryBrowsing {
    func startBrowsing(serviceType: String) async throws {
        try await startBrowsing(serviceType: serviceType, domain: "local.")
    }
}

public extension BonjourHostAdvertising {
    func startAdvertising(serviceType: String, metadata: HostAdvertisementMetadata) async throws {
        try await startAdvertising(serviceType: serviceType, domain: "local.", metadata: metadata)
    }
}
