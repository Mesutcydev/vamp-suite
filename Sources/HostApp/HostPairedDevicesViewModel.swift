import Foundation
import SharedModels
import Permissions

/// View model for the host's Paired Devices screen.
/// Shows trusted clients, last connected time, revoke action, and active session.
@MainActor
final class HostPairedDevicesViewModel: ObservableObject {

    @Published private(set) var trustedPeers: [TrustedPeer] = []
    @Published private(set) var revokedPeers: [TrustedPeer] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    /// The currently active session's client ID (if any).
    @Published var activeClientID: UUID?

    private let peerStore: any TrustedPeerStoreProtocol

    init(peerStore: any TrustedPeerStoreProtocol) {
        self.peerStore = peerStore
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if let persistent = peerStore as? PersistentTrustedPeerStore {
                let all = try await persistent.allPeers()
                trustedPeers = all.filter { !$0.isRevoked }
                    .sorted { ($0.lastSeenAt ?? $0.trustedAt) > ($1.lastSeenAt ?? $1.trustedAt) }
                revokedPeers = all.filter { $0.isRevoked }
                    .sorted { $0.trustedAt > $1.trustedAt }
            } else {
                let peers = try await peerStore.trustedPeers()
                trustedPeers = peers.sorted { ($0.lastSeenAt ?? $0.trustedAt) > ($1.lastSeenAt ?? $1.trustedAt) }
                revokedPeers = []
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revoke(_ peer: TrustedPeer) async {
        do {
            try await peerStore.revokePeer(id: peer.id)
            await refresh()
        } catch {
            errorMessage = "Failed to revoke: \(error.localizedDescription)"
        }
    }

    func reTrust(_ peer: TrustedPeer) async {
        do {
            try await peerStore.trustPeer(peer)
            await refresh()
        } catch {
            errorMessage = "Failed to re-trust: \(error.localizedDescription)"
        }
    }

    func remove(_ peer: TrustedPeer) async {
        if let persistent = peerStore as? PersistentTrustedPeerStore {
            do {
                try await persistent.removePeer(id: peer.id)
                await refresh()
            } catch {
                errorMessage = "Failed to remove: \(error.localizedDescription)"
            }
        }
    }

    func clearAllPaired() async {
        do {
            if let persistent = peerStore as? PersistentTrustedPeerStore {
                try await persistent.removeAll()
            } else {
                for peer in trustedPeers {
                    try await peerStore.revokePeer(id: peer.id)
                }
            }
            await refresh()
        } catch {
            errorMessage = "Failed to clear paired devices: \(error.localizedDescription)"
        }
    }

    func isActive(_ peer: TrustedPeer) -> Bool {
        peer.id == activeClientID
    }
}
