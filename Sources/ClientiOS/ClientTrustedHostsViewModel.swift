import Foundation
import SharedModels
import Permissions

/// View model for the client's trusted hosts management.
/// Shows hosts the client has previously connected to and trusts.
@MainActor
final class ClientTrustedHostsViewModel: ObservableObject {

    @Published private(set) var trustedHosts: [TrustedPeer] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var preferredHostID: UUID?

    private let peerStore: any TrustedPeerStoreProtocol

    init(peerStore: any TrustedPeerStoreProtocol) {
        self.peerStore = peerStore
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let peers = try await peerStore.trustedPeers()
            trustedHosts = peers
                .sorted { ($0.lastSeenAt ?? $0.trustedAt) > ($1.lastSeenAt ?? $1.trustedAt) }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Mark a host as the preferred reconnect target.
    func setPreferred(_ host: TrustedPeer) {
        preferredHostID = host.id
    }

    /// Forget a host (remove trust).
    func forget(_ host: TrustedPeer) async {
        do {
            try await peerStore.revokePeer(id: host.id)
            await refresh()
        } catch {
            errorMessage = "Failed to forget: \(error.localizedDescription)"
        }
    }

    /// Re-trust a host that was previously forgotten.
    func reTrust(_ host: TrustedPeer) async {
        do {
            try await peerStore.trustPeer(host)
            await refresh()
        } catch {
            errorMessage = "Failed to re-trust: \(error.localizedDescription)"
        }
    }

    /// Whether the preferred host is in the trusted list.
    var preferredHost: TrustedPeer? {
        trustedHosts.first { $0.id == preferredHostID }
    }
}
