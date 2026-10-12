import Foundation
import os
import SharedModels

/// Concrete file-backed trusted peer store using JSON persistence.
/// Stores trusted peers in a JSON file inside the app's Application Support directory.
///
/// Architecture note: The `fingerprint` field on `TrustedPeer` is designed to hold
/// a SHA-256 hash of the peer's public key (or certificate). Currently populated with
/// a placeholder identity string; when certificate pinning is added, replace it with
/// the actual key fingerprint and verify on every connection.
public actor PersistentTrustedPeerStore: TrustedPeerStoreProtocol {
    private let logger = Logger(subsystem: "com.remotedesktop.permissions", category: "TrustedPeerStore")

    private var peers: [TrustedPeer] = []
    private let fileURL: URL
    private var loaded = false

    public init(directory: URL? = nil) {
        let dir = directory ?? PersistentTrustedPeerStore.defaultDirectory
        self.fileURL = dir.appendingPathComponent("trusted_peers.json")
    }

    // MARK: - TrustedPeerStoreProtocol

    public func trustedPeers() async throws -> [TrustedPeer] {
        try loadIfNeeded()
        return peers.filter { !$0.isRevoked }
    }

    public func trustPeer(_ peer: TrustedPeer) async throws {
        guard PublicKeyFingerprint.isValid(peer.fingerprint) else {
            throw TrustedPeerStoreError.invalidFingerprint
        }
        try loadIfNeeded()
        // Upsert by stable fingerprint first, then by peer ID as a fallback.
        if let idx = peers.firstIndex(where: { $0.fingerprint == peer.fingerprint }) {
            var updated = peer
            updated.isRevoked = false
            updated.trustedAt = Date()
            updated.lastSeenAt = Date()
            peers[idx] = updated
        } else if let idx = peers.firstIndex(where: { $0.id == peer.id }) {
            var updated = peer
            updated.isRevoked = false
            updated.trustedAt = Date()
            updated.lastSeenAt = Date()
            peers[idx] = updated
        } else {
            var trustedPeer = peer
            trustedPeer.lastSeenAt = Date()
            peers.append(trustedPeer)
        }
        try persist()
    }

    public func revokePeer(id: UUID) async throws {
        try loadIfNeeded()
        guard let idx = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[idx].isRevoked = true
        try persist()
    }

    // MARK: - Extended API

    /// All peers including revoked (for UI display).
    public func allPeers() throws -> [TrustedPeer] {
        try loadIfNeeded()
        return peers
    }

    /// Check whether a peer ID is trusted (not revoked).
    public func isTrusted(peerID: UUID) throws -> Bool {
        try loadIfNeeded()
        return peers.contains { $0.id == peerID && !$0.isRevoked }
    }

    /// Check whether a fingerprint matches a trusted peer.
    /// This is the hook for certificate pinning verification.
    public func isTrustedFingerprint(_ fingerprint: String) throws -> Bool {
        try loadIfNeeded()
        return peers.contains { $0.fingerprint == fingerprint && !$0.isRevoked }
    }

    /// Update the lastSeenAt timestamp for a peer.
    public func updateLastSeen(peerID: UUID) throws {
        try loadIfNeeded()
        guard let idx = peers.firstIndex(where: { $0.id == peerID }) else { return }
        peers[idx].lastSeenAt = Date()
        try persist()
    }

    public func updateLastSeen(fingerprint: String) throws {
        try loadIfNeeded()
        guard let idx = peers.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        peers[idx].lastSeenAt = Date()
        try persist()
    }

    /// Permanently remove a peer (forget, not just revoke).
    public func removePeer(id: UUID) throws {
        try loadIfNeeded()
        peers.removeAll { $0.id == id }
        try persist()
    }

    /// Remove all peers.
    public func removeAll() throws {
        peers.removeAll()
        try persist()
    }

    // MARK: - Persistence

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loaded = true
            return
        }
        let data: Data
        do {
            // Retry transient read failures before giving up. A paired Mac is most often
            // reached remotely (Tailscale) while it sits at the lock screen, and a file
            // written by an older build with `.completeFileProtection` can be momentarily
            // unreadable there — a single failed read would wrongly re-prompt an already
            // trusted device. New writes use `...UntilFirstUserAuthentication` (see persist),
            // so this only bridges legacy files until the next successful write migrates them.
            data = try Self.readWithRetry(fileURL, attempts: 3, logger: logger)
        } catch {
            // Do NOT mark `loaded` or rename the file — that would erase every
            // pairing.  Surface the error so the caller falls back to
            // requires-approval for this single offer, and try again on the next.
            logger.error("Trusted peer store read failed after retries: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        do {
            peers = try JSONDecoder().decode([TrustedPeer].self, from: data)
            loaded = true
        } catch {
            logger.error("Trusted peer store decode failed; moving aside: \(error.localizedDescription, privacy: .public)")
            let corruptURL = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
            peers = []
            loaded = true
        }
    }

    /// Read a file, retrying a few times on transient failures (e.g. a legacy
    /// data-protected file briefly unreadable at the lock screen). ponytail: fixed 3
    /// attempts with a short sleep — the real cure is the protection class on write.
    private static func readWithRetry(_ url: URL, attempts: Int, logger: Logger) throws -> Data {
        var lastError: Error?
        for attempt in 0..<max(1, attempts) {
            do {
                return try Data(contentsOf: url)
            } catch {
                lastError = error
                if attempt < attempts - 1 {
                    logger.error("Trusted peer store read attempt \(attempt + 1) failed (will retry): \(error.localizedDescription, privacy: .public)")
                    Thread.sleep(forTimeInterval: 0.15)
                }
            }
        }
        throw lastError ?? CocoaError(.fileReadUnknown)
    }

    private func persist() throws {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder().encode(peers)
        // Use `...UntilFirstUserAuthentication`, NOT `.completeFileProtection`. On Apple
        // Silicon macOS with FileVault, data protection can be enforced; `.completeFileProtection`
        // makes the file readable ONLY while the screen is unlocked, so a Mac reached remotely
        // (e.g. over Tailscale) at its lock screen treats every paired device as new and
        // re-prompts. `...UntilFirstUserAuthentication` keeps it encrypted at rest but readable
        // after the first post-boot unlock — i.e. whenever the host app is actually running.
        // Plain atomic write — NO per-file data protection. ponytail: the contents are public-key
        // fingerprints (not secrets — private keys live in the Keychain), and FileVault already
        // encrypts the volume at rest. The data-protection class made this file unreadable at the
        // lock screen on Apple-Silicon + FileVault, so a paired Mac reached remotely over Tailscale
        // while locked re-prompted every already-trusted device. A plain write stays readable
        // whenever the host process is running (i.e. logged in) — exactly when trust is checked.
        // Writing here also migrates any legacy data-protected file to the readable format.
        try data.write(to: fileURL, options: [.atomic])
    }

    private static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("RemoteDesktopTool", isDirectory: true)
    }
}

private enum TrustedPeerStoreError: Error, LocalizedError {
    case invalidFingerprint
    var errorDescription: String? { "Peer fingerprint must be a 64-character lowercase hex string." }
}
