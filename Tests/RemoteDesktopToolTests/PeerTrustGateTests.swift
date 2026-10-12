import XCTest
@testable import Permissions
@testable import SharedModels

final class PeerTrustGateTests: XCTestCase {

    // Generates a distinct valid 64-char lowercase hex fingerprint from a seed byte.
    private func fp(_ n: UInt8) -> String {
        String(repeating: String(format: "%02x", n), count: 32)
    }

    private final class PromptFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func markCalled() { lock.lock(); value = true; lock.unlock() }

        var wasCalled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        func store(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.withLock {
                self.continuation = continuation
            }
        }

        func resume(returning value: Bool) {
            let continuation = lock.withLock {
                let pending = self.continuation
                self.continuation = nil
                return pending
            }
            continuation?.resume(returning: value)
        }
    }

    private var tempDir: URL!
    private var store: PersistentTrustedPeerStore!
    private var gate: PeerTrustGate!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrustGateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = PersistentTrustedPeerStore(directory: tempDir)
        gate = PeerTrustGate(store: store)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Evaluate

    func testUnknownPeerRequiresApproval() async {
        let id = UUID()
        let result = await gate.evaluate(peerID: id, displayName: "New Device", fingerprint: fp(1))
        if case .requiresApproval(let peerID, let name, let fingerprint) = result {
            XCTAssertEqual(peerID, id)
            XCTAssertEqual(name, "New Device")
            XCTAssertEqual(fingerprint, fp(1))
        } else {
            XCTFail("Expected requiresApproval, got \(result)")
        }
    }

    func testTrustedPeerEvaluatesAsTrusted() async throws {
        let peer = TrustedPeer(displayName: "Known Device", fingerprint: fp(2))
        try await store.trustPeer(peer)

        let result = await gate.evaluate(peerID: peer.id, displayName: "Known Device", fingerprint: fp(2))
        XCTAssertEqual(result, .trusted)
    }

    func testRevokedPeerEvaluatesAsRevoked() async throws {
        let peer = TrustedPeer(displayName: "Bad Device", fingerprint: fp(3))
        try await store.trustPeer(peer)
        try await store.revokePeer(id: peer.id)

        let result = await gate.evaluate(peerID: peer.id, displayName: "Bad Device", fingerprint: fp(3))
        if case .revoked(let id) = result {
            XCTAssertEqual(id, peer.id)
        } else {
            XCTFail("Expected revoked, got \(result)")
        }
    }

    func testRemovingRevokedPeerAllowsFreshApprovalPrompt() async throws {
        let peer = TrustedPeer(displayName: "Previously Rejected", fingerprint: fp(4))
        try await store.trustPeer(peer)
        try await store.revokePeer(id: peer.id)
        try await store.removePeer(id: peer.id)

        let result = await gate.evaluate(
            peerID: peer.id,
            displayName: peer.displayName,
            fingerprint: peer.fingerprint)
        if case .requiresApproval(let peerID, _, let fingerprint) = result {
            XCTAssertEqual(peerID, peer.id)
            XCTAssertEqual(fingerprint, peer.fingerprint)
        } else {
            XCTFail("Expected a fresh approval prompt after removing the stale denial, got \(result)")
        }
    }

    func testFingerprintMismatchIsHardFail() async throws {
        let peer = TrustedPeer(displayName: "Device", fingerprint: fp(10))
        try await store.trustPeer(peer)

        let result = await gate.evaluate(peerID: peer.id, displayName: "Device", fingerprint: fp(11))
        if case .fingerprintChanged(let peerID, _, let previous, let newFingerprint) = result {
            XCTAssertEqual(peerID, peer.id)
            XCTAssertEqual(previous, fp(10))
            XCTAssertEqual(newFingerprint, fp(11))
        } else {
            XCTFail("Expected fingerprintChanged for key swap, got \(result)")
        }
    }

    func testFingerprintMismatchDoesNotPromptAllow() async throws {
        let peer = TrustedPeer(displayName: "Device", fingerprint: fp(10))
        try await store.trustPeer(peer)

        let promptCalled = PromptFlag()
        await gate.setApprovalHandler { _, _, _ in
            promptCalled.markCalled()
            return true
        }

        let approved = await gate.evaluateAndPrompt(
            peerID: peer.id,
            displayName: "Device",
            fingerprint: fp(11)
        )
        XCTAssertFalse(approved)
        XCTAssertFalse(promptCalled.wasCalled)
        let reason = await gate.lastDenialReason
        XCTAssertNotNil(reason)
    }

    // MARK: - Fingerprint format validation (M-2)

    func testMalformedFingerprintTooShortIsRejected() async {
        let result = await gate.evaluate(peerID: UUID(), displayName: "Device", fingerprint: "short")
        if case .invalidIdentity = result { } else {
            XCTFail("Expected invalidIdentity for malformed fingerprint, got \(result)")
        }
    }

    func testMalformedFingerprintUppercaseIsRejected() async {
        let upper = String(repeating: "A", count: 64)
        let result = await gate.evaluate(peerID: UUID(), displayName: "Device", fingerprint: upper)
        if case .invalidIdentity = result { } else {
            XCTFail("Expected invalidIdentity for uppercase fingerprint, got \(result)")
        }
    }

    func testMalformedFingerprintTooLongIsRejected() async {
        let tooLong = String(repeating: "a", count: 65)
        let result = await gate.evaluate(peerID: UUID(), displayName: "Device", fingerprint: tooLong)
        if case .invalidIdentity = result { } else {
            XCTFail("Expected invalidIdentity for 65-char fingerprint, got \(result)")
        }
    }

    func testValidFingerprintAllowsStoreLookup() async throws {
        let peer = TrustedPeer(displayName: "Device", fingerprint: fp(20))
        try await store.trustPeer(peer)
        let result = await gate.evaluate(peerID: peer.id, displayName: "Device", fingerprint: fp(20))
        XCTAssertEqual(result, .trusted)
    }

    // MARK: - Evaluate and Prompt

    func testEvaluateAndPromptApproves() async throws {
        let id = UUID()
        await gate.setApprovalHandler { _, _, _ in true }

        let approved = await gate.evaluateAndPrompt(peerID: id, displayName: "New", fingerprint: fp(30))
        XCTAssertTrue(approved)

        let trusted = try await store.isTrusted(peerID: id)
        XCTAssertTrue(trusted)
    }

    func testEvaluateAndPromptDenies() async throws {
        let id = UUID()
        await gate.setApprovalHandler { _, _, _ in false }

        let approved = await gate.evaluateAndPrompt(peerID: id, displayName: "Denied", fingerprint: fp(31))
        XCTAssertFalse(approved)

        let trusted = try await store.isTrusted(peerID: id)
        XCTAssertFalse(trusted)
    }

    func testEvaluateAndPromptSkipsPromptForTrustedPeer() async throws {
        let peer = TrustedPeer(displayName: "Already Trusted", fingerprint: fp(40))
        try await store.trustPeer(peer)

        let promptCalled = PromptFlag()
        await gate.setApprovalHandler { _, _, _ in
            promptCalled.markCalled()
            return false
        }

        let approved = await gate.evaluateAndPrompt(peerID: peer.id, displayName: "Already Trusted", fingerprint: fp(40))
        XCTAssertTrue(approved)
        XCTAssertFalse(promptCalled.wasCalled)
    }

    func testEvaluateAndPromptDeniesRevokedWithoutPrompt() async throws {
        let peer = TrustedPeer(displayName: "Revoked", fingerprint: fp(50))
        try await store.trustPeer(peer)
        try await store.revokePeer(id: peer.id)

        let promptCalled = PromptFlag()
        await gate.setApprovalHandler { _, _, _ in
            promptCalled.markCalled()
            return true
        }

        let approved = await gate.evaluateAndPrompt(peerID: peer.id, displayName: "Revoked", fingerprint: fp(50))
        XCTAssertFalse(approved)
        XCTAssertFalse(promptCalled.wasCalled)
    }

    // MARK: - Nil approval handler (M-5)

    func testEvaluateAndPromptReturnsFalseWithNoHandler() async {
        let approved = await gate.evaluateAndPrompt(peerID: UUID(), displayName: "Device", fingerprint: fp(60))
        XCTAssertFalse(approved, "No approvalHandler must reject silently rather than hanging")
    }

    // MARK: - Concurrent prompt guard

    func testConcurrentPromptIsRejected() async {
        // First prompt blocks; a second concurrent call must be immediately rejected.
        let firstHandlerContinuation = ContinuationBox()
        await gate.setApprovalHandler { _, _, _ in
            await withCheckedContinuation { firstHandlerContinuation.store($0) }
        }

        async let first = gate.evaluateAndPrompt(peerID: UUID(), displayName: "A", fingerprint: fp(70))
        // Brief yield so the first call enters the handler before the second starts
        try? await Task.sleep(nanoseconds: 10_000_000)
        let secondResult = await gate.evaluateAndPrompt(peerID: UUID(), displayName: "B", fingerprint: fp(71))
        XCTAssertFalse(secondResult, "Second concurrent prompt must be rejected immediately")

        firstHandlerContinuation.resume(returning: false)
        _ = await first
    }

    // MARK: - Fingerprint Verification

    func testEvaluateFingerprintMatches() async throws {
        let peer = TrustedPeer(displayName: "Device", fingerprint: fp(80))
        try await store.trustPeer(peer)

        let matches = await gate.evaluateFingerprint(fp(80), for: peer.id)
        XCTAssertTrue(matches)
    }

    func testEvaluateFingerprintMismatch() async throws {
        let peer = TrustedPeer(displayName: "Device", fingerprint: fp(80))
        try await store.trustPeer(peer)

        let matches = await gate.evaluateFingerprint(fp(81), for: peer.id)
        XCTAssertFalse(matches)
    }

    func testEvaluateFingerprintUnknownPeer() async {
        let matches = await gate.evaluateFingerprint(fp(90), for: UUID())
        XCTAssertFalse(matches)
    }
}
