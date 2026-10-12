import XCTest
@testable import Permissions
@testable import SharedModels

final class TrustedPeerStoreTests: XCTestCase {

    // Generates a distinct valid 64-char lowercase hex fingerprint from a seed byte.
    private func fp(_ n: UInt8) -> String {
        String(repeating: String(format: "%02x", n), count: 32)
    }

    private var tempDir: URL!
    private var store: PersistentTrustedPeerStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrustTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = PersistentTrustedPeerStore(directory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Basic CRUD

    func testEmptyStoreReturnsNoPeers() async throws {
        let peers = try await store.trustedPeers()
        XCTAssertTrue(peers.isEmpty)
    }

    func testTrustAndRetrievePeer() async throws {
        let peer = TrustedPeer(displayName: "iPhone 15", fingerprint: fp(1))
        try await store.trustPeer(peer)

        let peers = try await store.trustedPeers()
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers.first?.displayName, "iPhone 15")
        XCTAssertEqual(peers.first?.fingerprint, fp(1))
        XCTAssertFalse(peers.first?.isRevoked ?? true)
    }

    func testTrustMultiplePeers() async throws {
        let p1 = TrustedPeer(displayName: "Device A", fingerprint: fp(1))
        let p2 = TrustedPeer(displayName: "Device B", fingerprint: fp(2))
        try await store.trustPeer(p1)
        try await store.trustPeer(p2)

        let peers = try await store.trustedPeers()
        XCTAssertEqual(peers.count, 2)
    }

    // MARK: - Revoke

    func testRevokePeerHidesFromTrustedList() async throws {
        let peer = TrustedPeer(displayName: "iPad", fingerprint: fp(10))
        try await store.trustPeer(peer)
        try await store.revokePeer(id: peer.id)

        let trusted = try await store.trustedPeers()
        XCTAssertTrue(trusted.isEmpty)

        let all = try await store.allPeers()
        XCTAssertEqual(all.count, 1)
        XCTAssertTrue(all.first?.isRevoked ?? false)
    }

    func testRevokeNonexistentPeerIsNoOp() async throws {
        try await store.revokePeer(id: UUID())
        let peers = try await store.trustedPeers()
        XCTAssertTrue(peers.isEmpty)
    }

    // MARK: - Re-trust

    func testReTrustRevokedPeer() async throws {
        let peer = TrustedPeer(displayName: "Mac Mini", fingerprint: fp(20))
        try await store.trustPeer(peer)
        try await store.revokePeer(id: peer.id)
        try await store.trustPeer(peer)

        let trusted = try await store.trustedPeers()
        XCTAssertEqual(trusted.count, 1)
        XCTAssertFalse(trusted.first?.isRevoked ?? true)
    }

    // MARK: - Remove

    func testRemovePeerPermanently() async throws {
        let peer = TrustedPeer(displayName: "Old Device", fingerprint: fp(30))
        try await store.trustPeer(peer)
        try await store.removePeer(id: peer.id)

        let all = try await store.allPeers()
        XCTAssertTrue(all.isEmpty)
    }

    func testRemoveAllPeers() async throws {
        try await store.trustPeer(TrustedPeer(displayName: "A", fingerprint: fp(40)))
        try await store.trustPeer(TrustedPeer(displayName: "B", fingerprint: fp(41)))
        try await store.removeAll()

        let all = try await store.allPeers()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Fingerprint Check

    func testIsTrustedFingerprint() async throws {
        let peer = TrustedPeer(displayName: "Device", fingerprint: fp(50))
        try await store.trustPeer(peer)

        let trusted = try await store.isTrustedFingerprint(fp(50))
        XCTAssertTrue(trusted)

        let unknown = try await store.isTrustedFingerprint(fp(51))
        XCTAssertFalse(unknown)
    }

    func testRevokedFingerprintNotTrusted() async throws {
        let peer = TrustedPeer(displayName: "Device", fingerprint: fp(60))
        try await store.trustPeer(peer)
        try await store.revokePeer(id: peer.id)

        let trusted = try await store.isTrustedFingerprint(fp(60))
        XCTAssertFalse(trusted)
    }

    // MARK: - Peer ID Check

    func testIsTrustedPeerID() async throws {
        let peer = TrustedPeer(displayName: "Device", fingerprint: fp(70))
        try await store.trustPeer(peer)

        let trusted = try await store.isTrusted(peerID: peer.id)
        XCTAssertTrue(trusted)

        let unknown = try await store.isTrusted(peerID: UUID())
        XCTAssertFalse(unknown)
    }

    // MARK: - Last Seen

    func testUpdateLastSeen() async throws {
        let peer = TrustedPeer(displayName: "Device", fingerprint: fp(80))
        XCTAssertNil(peer.lastSeenAt)
        try await store.trustPeer(peer)
        try await store.updateLastSeen(peerID: peer.id)

        let all = try await store.allPeers()
        XCTAssertNotNil(all.first?.lastSeenAt)
    }

    // MARK: - Persistence Round-Trip

    func testDataPersistsAcrossInstances() async throws {
        let peer = TrustedPeer(displayName: "Persistent", fingerprint: fp(90))
        try await store.trustPeer(peer)

        let store2 = PersistentTrustedPeerStore(directory: tempDir)
        let peers = try await store2.trustedPeers()
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers.first?.displayName, "Persistent")
        XCTAssertEqual(peers.first?.fingerprint, fp(90))
    }

    // MARK: - Fingerprint format validation (M-2)

    func testTrustPeerThrowsForShortFingerprint() async {
        let peer = TrustedPeer(displayName: "Device", fingerprint: "short")
        do {
            try await store.trustPeer(peer)
            XCTFail("Expected trustPeer to throw for short fingerprint")
        } catch { }
    }

    func testTrustPeerThrowsForUppercaseHexFingerprint() async {
        let peer = TrustedPeer(displayName: "Device", fingerprint: String(repeating: "A", count: 64))
        do {
            try await store.trustPeer(peer)
            XCTFail("Expected trustPeer to throw for uppercase fingerprint")
        } catch { }
    }

    func testTrustPeerThrowsFor65CharFingerprint() async {
        let peer = TrustedPeer(displayName: "Device", fingerprint: String(repeating: "a", count: 65))
        do {
            try await store.trustPeer(peer)
            XCTFail("Expected trustPeer to throw for 65-char fingerprint")
        } catch { }
    }

    func testTrustPeerThrowsForEmptyFingerprint() async {
        let peer = TrustedPeer(displayName: "Device", fingerprint: "")
        do {
            try await store.trustPeer(peer)
            XCTFail("Expected trustPeer to throw for empty fingerprint")
        } catch { }
    }

    func testTrustPeerAcceptsValidFingerprint() async throws {
        let peer = TrustedPeer(displayName: "Device", fingerprint: fp(100))
        try await store.trustPeer(peer)
        let peers = try await store.trustedPeers()
        XCTAssertEqual(peers.count, 1)
    }

    // MARK: - Corrupt store preservation (M-8)

    func testCorruptStoreFileIsRenamedNotDeleted() async throws {
        let fileURL = tempDir.appendingPathComponent("trusted_peers.json")
        try "not valid json!!!".write(to: fileURL, atomically: true, encoding: .utf8)

        let freshStore = PersistentTrustedPeerStore(directory: tempDir)
        let peers = try await freshStore.trustedPeers()
        XCTAssertTrue(peers.isEmpty, "Corrupt store should reset to empty")

        let corruptURL = tempDir.appendingPathComponent("trusted_peers.corrupt.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: corruptURL.path),
            "Corrupt file must be preserved as trusted_peers.corrupt.json"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "Original corrupt file must be moved, not left in place"
        )
    }

    func testValidStoreDoesNotCreateCorruptFile() async throws {
        let peer = TrustedPeer(displayName: "Device", fingerprint: fp(110))
        try await store.trustPeer(peer)

        let store2 = PersistentTrustedPeerStore(directory: tempDir)
        _ = try await store2.trustedPeers()

        let corruptURL = tempDir.appendingPathComponent("trusted_peers.corrupt.json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: corruptURL.path),
            "Valid store must not produce a .corrupt.json file"
        )
    }
}
