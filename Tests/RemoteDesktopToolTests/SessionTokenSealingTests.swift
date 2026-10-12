import CryptoKit
import XCTest
@testable import TransportWebRTC

final class SessionTokenSealingTests: XCTestCase {
    private func makeIdentity() -> P256.Signing.PrivateKey {
        P256.Signing.PrivateKey()
    }

    func testSealOpenRoundTrip() throws {
        let identity = makeIdentity()
        let recipient = SessionTokenSealing.deriveKeyAgreementKey(from: identity)
        let plaintext = Data("deadbeefdeadbeefdeadbeefdeadbeef".utf8)

        let sealed = try SessionTokenSealing.seal(plaintext, to: recipient.publicKey)
        let opened = SessionTokenSealing.open(sealed, with: recipient)

        XCTAssertEqual(opened, plaintext)
    }

    func testWrongKeyCannotOpen() throws {
        let first = makeIdentity()
        let second = makeIdentity()
        let recipient = SessionTokenSealing.deriveKeyAgreementKey(from: first)
        let wrong = SessionTokenSealing.deriveKeyAgreementKey(from: second)
        let plaintext = Data("0102030405060708090a0b0c0d0e0f10".utf8)

        let sealed = try SessionTokenSealing.seal(plaintext, to: recipient.publicKey)
        XCTAssertNil(SessionTokenSealing.open(sealed, with: wrong))
    }

    func testTamperedCiphertextIsRejected() throws {
        let identity = makeIdentity()
        let recipient = SessionTokenSealing.deriveKeyAgreementKey(from: identity)
        let plaintext = Data("feedfacefeedfacefeedfacefeedface".utf8)

        var sealed = try SessionTokenSealing.seal(plaintext, to: recipient.publicKey)
        // Flip a bit in the ciphertext region (after the header + ephemeral key).
        let flipIndex = sealed.count - 10
        sealed[flipIndex] ^= 0x01
        XCTAssertNil(SessionTokenSealing.open(sealed, with: recipient))
    }

    func testDerivedKeyIsDeterministicAndPublishesStableKey() {
        let identity = makeIdentity()
        let first = SessionTokenSealing.deriveKeyAgreementKey(from: identity)
        let second = SessionTokenSealing.deriveKeyAgreementKey(from: identity)
        XCTAssertEqual(
            first.publicKey.x963Representation,
            second.publicKey.x963Representation,
            "The derived key-agreement public key must be stable across calls"
        )
    }

    func testDifferentIdentitiesDeriveDifferentKeys() {
        let first = SessionTokenSealing.deriveKeyAgreementKey(from: makeIdentity())
        let second = SessionTokenSealing.deriveKeyAgreementKey(from: makeIdentity())
        XCTAssertNotEqual(
            first.publicKey.x963Representation,
            second.publicKey.x963Representation
        )
    }

    func testGarbageAndTruncatedInputsAreRejected() {
        let identity = makeIdentity()
        let recipient = SessionTokenSealing.deriveKeyAgreementKey(from: identity)
        XCTAssertNil(SessionTokenSealing.open(Data([0x01, 0x02, 0x03]), with: recipient))
        XCTAssertNil(SessionTokenSealing.open(Data(), with: recipient))
        // Wrong version byte.
        let plaintext = Data("abcdef0123456789abcdef0123456789".utf8)
        var sealed = try! SessionTokenSealing.seal(plaintext, to: recipient.publicKey)
        sealed[0] = 0x7f
        XCTAssertNil(SessionTokenSealing.open(sealed, with: recipient))
    }
}
