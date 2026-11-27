import XCTest
import SharedModels
@testable import HostApp
@testable import SharedProtocol

final class HostClientAttachmentIdentityTests: XCTestCase {
    private let fingerprint = String(repeating: "ab", count: 32)

    func testRevocationMatchesFingerprintAfterPeerIDChanges() {
        let peer = TrustedPeer(id: UUID(), displayName: "Test", fingerprint: fingerprint)
        XCTAssertTrue(HostClientAttachmentIdentity.matchesRevokedPeer(
            activeClientID: UUID(), activeClientFingerprint: fingerprint.uppercased(), peer: peer))
        XCTAssertFalse(HostClientAttachmentIdentity.matchesRevokedPeer(
            activeClientID: UUID(), activeClientFingerprint: String(repeating: "cd", count: 32), peer: peer))
    }

    func testSamePeerIDCanReplaceItsTransport() {
        let peerID = UUID()
        let candidate = SignalingPeer(id: peerID, role: .client, publicKeyFingerprint: fingerprint)

        XCTAssertTrue(HostClientAttachmentIdentity.matches(
            activeClientID: peerID,
            activeClientFingerprint: fingerprint,
            candidate: candidate
        ))
        // Legacy unsigned peers carry no key, so the ID is all there is to match on.
        XCTAssertTrue(HostClientAttachmentIdentity.matches(
            activeClientID: peerID,
            activeClientFingerprint: nil,
            candidate: SignalingPeer(id: peerID, role: .client, publicKeyFingerprint: nil)
        ))
    }

    /// A device ID is self-declared. Reusing the active client's ID under a different key must
    /// not count as that client, or an untrusted peer skips the host-busy check.
    func testSamePeerIDWithDifferentKeyIsNotTheActiveClient() {
        let peerID = UUID()
        let candidate = SignalingPeer(
            id: peerID,
            role: .client,
            publicKeyFingerprint: String(repeating: "cd", count: 32)
        )

        XCTAssertFalse(HostClientAttachmentIdentity.matches(
            activeClientID: peerID,
            activeClientFingerprint: fingerprint,
            candidate: candidate
        ))
    }

    func testSameValidFingerprintCanReplaceLegacyRandomPeerID() {
        let candidate = SignalingPeer(
            id: UUID(),
            role: .client,
            publicKeyFingerprint: fingerprint.uppercased()
        )

        XCTAssertTrue(HostClientAttachmentIdentity.matches(
            activeClientID: UUID(),
            activeClientFingerprint: "  \(fingerprint)\n",
            candidate: candidate
        ))
    }

    func testDifferentFingerprintCannotEvictActiveClient() {
        let candidate = SignalingPeer(
            id: UUID(),
            role: .client,
            publicKeyFingerprint: String(repeating: "cd", count: 32)
        )

        XCTAssertFalse(HostClientAttachmentIdentity.matches(
            activeClientID: UUID(),
            activeClientFingerprint: fingerprint,
            candidate: candidate
        ))
    }

    func testMalformedFingerprintCannotUseReplacementPath() {
        let candidate = SignalingPeer(
            id: UUID(),
            role: .client,
            publicKeyFingerprint: "not-a-fingerprint"
        )

        XCTAssertFalse(HostClientAttachmentIdentity.matches(
            activeClientID: UUID(),
            activeClientFingerprint: "not-a-fingerprint",
            candidate: candidate
        ))
    }

    func testSessionSlotIsReleasedOnlyWhenItsDeviceIsGone() {
        let now = Date()
        func held(claimed: TimeInterval?, connected: Bool, activity: TimeInterval?) -> Bool {
            HostSessionSlotPolicy.isHeld(
                claimedAt: claimed.map { now.addingTimeInterval(-$0) },
                transportConnected: connected,
                lastActivity: activity.map { now.addingTimeInterval(-$0) },
                now: now, negotiationWindow: 30, livenessTimeout: 30)
        }
        // A just-approved session keeps the slot while it negotiates.
        XCTAssertTrue(held(claimed: 5, connected: false, activity: nil))
        // A device that vanished mid-setup no longer blocks others.
        XCTAssertFalse(held(claimed: 120, connected: false, activity: nil))
        // A live, chatty session keeps the slot.
        XCTAssertTrue(held(claimed: 600, connected: true, activity: 2))
        // A half-open transport with a silent device is released.
        XCTAssertFalse(held(claimed: 600, connected: true, activity: 90))
        // Connected but never heard from: measured from the claim.
        XCTAssertFalse(held(claimed: 600, connected: true, activity: nil))
        XCTAssertTrue(held(claimed: 20, connected: true, activity: nil))
    }
}
