import Foundation
import SharedModels
import os

/// Result of a trust evaluation for an incoming connection.
public enum TrustEvaluation: Sendable, Hashable {
    /// Peer is trusted — proceed with session.
    case trusted
    /// Peer is unknown — host must approve.
    case requiresApproval(peerID: UUID, displayName: String, fingerprint: String)
    /// Peer has been explicitly revoked.
    case revoked(peerID: UUID)
    /// A known peer ID presented a different key. Treat as possible MITM —
    /// do not offer a casual Allow prompt.
    case fingerprintChanged(peerID: UUID, displayName: String, previousFingerprint: String, newFingerprint: String)
    /// Fingerprint is missing or not a 64-character SHA-256 hex digest.
    case invalidIdentity
}

/// Manages the trust decision flow for incoming connections.
/// Sits between the signaling layer and session setup.
///
/// Future certificate pinning: when TLS certificates are added,
/// call `evaluateFingerprint(_:for:)` with the peer's certificate
/// SHA-256 fingerprint to verify it matches the stored value.
public actor PeerTrustGate {

    private let store: PersistentTrustedPeerStore
    private let logger = Logger(subsystem: "com.remotedesktop.permissions", category: "TrustGate")

    /// Tracks whether a prompt is currently pending, to prevent concurrent evaluations
    /// from racing (TOCTOU mitigation).
    private var pendingPromptPeerID: UUID?

    /// Callback invoked on MainActor when approval is needed.
    /// The host UI presents a prompt and returns true to approve, false to deny.
    public var approvalHandler: (@MainActor @Sendable (UUID, String, String) async -> Bool)?

    /// Last deny reason for the UI/event log. Consumed by the session coordinator.
    public private(set) var lastDenialReason: String?

    public init(store: PersistentTrustedPeerStore) {
        self.store = store
    }

    /// Set the approval handler callback.
    public func setApprovalHandler(_ handler: (@MainActor @Sendable (UUID, String, String) async -> Bool)?) {
        self.approvalHandler = handler
    }

    /// Evaluate trust for a connecting peer.
    public func evaluate(peerID: UUID, displayName: String, fingerprint: String) async -> TrustEvaluation {
        guard PublicKeyFingerprint.isValid(fingerprint) else {
            logger.warning("evaluate: malformed fingerprint from peer \(peerID.uuidString, privacy: .public) — rejected")
            lastDenialReason = "Rejected \(displayName): identity fingerprint is not a valid SHA-256 digest"
            return .invalidIdentity
        }
        do {
            let allPeers = try await store.allPeers()
            if let existing = allPeers.first(where: { $0.id == peerID }) {
                if existing.isRevoked {
                    return .revoked(peerID: peerID)
                }
                // Trusted — verify fingerprint matches (certificate pinning hook)
                if existing.fingerprint == fingerprint {
                    try await store.updateLastSeen(peerID: peerID)
                    return .trusted
                }
                logger.error("Fingerprint change for peer \(peerID.uuidString, privacy: .public) — refusing automatic re-pair")
                lastDenialReason = "Rejected \(displayName): identity key changed. Forget the old device in Paired Devices, then approve a new pairing after verifying the fingerprint."
                return .fingerprintChanged(
                    peerID: peerID,
                    displayName: displayName,
                    previousFingerprint: existing.fingerprint,
                    newFingerprint: fingerprint
                )
            }
            if let existing = allPeers.first(where: { $0.fingerprint == fingerprint }) {
                if existing.isRevoked {
                    return .revoked(peerID: existing.id)
                }
                // Same key, different peerID/name — auto-trusted because the
                // fingerprint is cryptographically bound to the key. Surface it so a
                // silent identifier/name rebind is at least auditable.
                logger.notice("Trusted peer rebind: fingerprint matches existing peer \(existing.id.uuidString, privacy: .public) under new id \(peerID.uuidString, privacy: .public) name=\(displayName, privacy: .public)")
                try await store.trustPeer(
                    TrustedPeer(
                        id: peerID,
                        displayName: displayName,
                        fingerprint: fingerprint,
                        trustedAt: existing.trustedAt,
                        lastSeenAt: Date(),
                        isRevoked: false
                    )
                )
                return .trusted
            }
            return .requiresApproval(peerID: peerID, displayName: displayName, fingerprint: fingerprint)
        } catch {
            return .requiresApproval(peerID: peerID, displayName: displayName, fingerprint: fingerprint)
        }
    }

    /// Full evaluate-and-prompt flow: evaluates trust, prompts if needed, persists decision.
    /// Returns true if the peer is now trusted and the session should proceed.
    ///
    /// Only one approval prompt can be active at a time. If another peer tries to connect
    /// while a prompt is pending, it is rejected immediately.
    public func evaluateAndPrompt(peerID: UUID, displayName: String, fingerprint: String) async -> Bool {
        let result = await evaluate(peerID: peerID, displayName: displayName, fingerprint: fingerprint)
        switch result {
        case .trusted:
            return true
        case .revoked:
            lastDenialReason = "Rejected \(displayName): this device was previously revoked"
            return false
        case .invalidIdentity, .fingerprintChanged:
            return false
        case .requiresApproval(let id, let name, let fp):
            // Prevent concurrent prompts (TOCTOU guard)
            guard pendingPromptPeerID == nil else {
                return false
            }
            pendingPromptPeerID = id
            defer { pendingPromptPeerID = nil }

            guard let handler = approvalHandler else {
                logger.warning("evaluateAndPrompt: approvalHandler is nil — peer \(id.uuidString, privacy: .public) rejected silently")
                return false
            }
            let approved = await handler(id, name, fp)
            if approved {
                let peer = TrustedPeer(id: id, displayName: name, fingerprint: fp)
                do {
                    try await store.trustPeer(peer)
                } catch {
                    // Never swallow this: a failed persist means the user approves but the device
                    // is re-prompted on every reconnect (brutal over Tailscale). Surface it.
                    logger.error("Failed to persist approved peer \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            return approved
        }
    }

    /// Cancel any pending approval prompt, clearing `pendingPromptPeerID` so
    /// future connections aren't silently rejected.
    public func cancelPendingPrompt() {
        pendingPromptPeerID = nil
    }

    /// Verify that a fingerprint matches a previously stored trusted peer.
    /// Use this when certificate pinning is implemented.
    public func evaluateFingerprint(_ fingerprint: String, for peerID: UUID) async -> Bool {
        do {
            let allPeers = try await store.allPeers()
            guard let peer = allPeers.first(where: { $0.id == peerID && !$0.isRevoked }) else {
                return false
            }
            return peer.fingerprint == fingerprint
        } catch {
            return false
        }
    }
}
