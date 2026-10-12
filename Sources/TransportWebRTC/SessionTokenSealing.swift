import CryptoKit
import Foundation
import Security

/// ECIES-style sealing for the session token carried inside the signaling offer.
///
/// The offer's session token authenticates the control channel and keys the
/// TLS-PSK data channel, but the offer crosses the plaintext signaling port
/// (9471) for legacy clients. A passive observer on that path could read the
/// token. When the client knows the host's public key, it seals the token to
/// that key instead, so only the host's identity key can recover it.
///
/// The host's identity is a P-256 *signing* key. To keep a single key pair,
/// we deterministically derive a sibling key-agreement key from the signing
/// private scalar via HKDF and advertise its public half alongside the
/// fingerprint. Possession of the identity key is what matters: an attacker
/// who steals the identity private key has already won.
public enum SessionTokenSealing {
    public static let version: UInt8 = 1
    /// Info string binds the derivation to this specific use, so the derived
    /// key can never be confused with another key derived from the same IKM.
    private static let derivationInfo = Data("vamp-session-token-sealing-v1".utf8)
    private static let hkdfSalt = Data("vamp-hkdf-salt-v1".utf8)
    private static let nonceSize = 12
    private static let p256FieldSize = 32
    private static let ephemeralPublicKeySize = 65 // uncompressed x963 P-256
    private static let tagSize = 16

    /// Derive the sibling key-agreement private key from the identity signing
    /// key. Deterministic, so the same identity always produces the same KEM
    /// key (and thus the same advertised public half).
    public static func deriveKeyAgreementKey(
        from signingKey: P256.Signing.PrivateKey
    ) -> P256.KeyAgreement.PrivateKey {
        let ikm = signingKey.x963Representation
        // Rejection-sample HKDF output onto the curve. P-256's order n is very
        // close to 2^256, so this almost never needs more than one attempt;
        // the info counter keeps each attempt distinct.
        for attempt in 0...8 {
            let derived = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: ikm),
                salt: hkdfSalt,
                info: derivationInfo + Data("attempt-\(attempt)".utf8),
                outputByteCount: p256FieldSize
            )
            let raw = derived.withUnsafeBytes { Data($0) }
            if let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) {
                return key
            }
        }
        // Unreachable in practice: 256 bits of CSPRNG output falls under the
        // curve order (2^256 − ~2^224) with overwhelming probability, and nine
        // attempts cover any pathological corner. A fallback that fatally
        // fails is better than silently weakening the key.
        fatalError("Unable to derive a valid P-256 key-agreement key")
    }

    /// Seal `plaintext` to `recipient`. Output layout:
    /// `[1 byte version][65-byte ephemeral P-256 x963 public key][12-byte
    /// nonce][ciphertext][16-byte tag]`.
    public static func seal(_ plaintext: Data, to recipient: P256.KeyAgreement.PublicKey) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let symmetricKey = deriveAESKey(from: shared)
        let box = try AES.GCM.seal(plaintext, using: symmetricKey) // random nonce
        let nonceBytes = box.nonce.withUnsafeBytes { Data($0) }
        var output = Data([version])
        output.append(ephemeral.publicKey.x963Representation)
        output.append(nonceBytes)
        output.append(box.ciphertext)
        output.append(box.tag)
        return output
    }

    /// Open a blob produced by `seal(_:to:)` with the recipient's derived key.
    public static func open(_ sealed: Data, with key: P256.KeyAgreement.PrivateKey) -> Data? {
        let minimumLength = 1 + ephemeralPublicKeySize + nonceSize + tagSize
        guard sealed.count >= minimumLength, sealed[0] == version else { return nil }
        var offset = 1
        guard let ephemeralPub = try? P256.KeyAgreement.PublicKey(
            x963Representation: sealed[offset..<(offset + ephemeralPublicKeySize)]
        ) else { return nil }
        offset += ephemeralPublicKeySize
        guard let nonce = try? AES.GCM.Nonce(data: sealed[offset..<(offset + nonceSize)]) else { return nil }
        offset += nonceSize
        let tagStart = sealed.count - tagSize
        let ciphertext = sealed[offset..<tagStart]
        let tag = sealed[tagStart...]
        guard let shared = try? key.sharedSecretFromKeyAgreement(with: ephemeralPub) else { return nil }
        let symmetricKey = deriveAESKey(from: shared)
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag) else {
            return nil
        }
        return try? AES.GCM.open(box, using: symmetricKey)
    }

    private static func deriveAESKey(from shared: SharedSecret) -> SymmetricKey {
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedBytes),
            salt: hkdfSalt,
            info: derivationInfo,
            outputByteCount: p256FieldSize
        )
    }
}
