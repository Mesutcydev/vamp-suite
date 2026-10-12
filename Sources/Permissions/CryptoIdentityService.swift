import Foundation
import CryptoKit

/// Manages a persistent P-256 key pair for this device.
///
/// - On first launch, generates a new private key and stores it in the Keychain.
/// - The public key fingerprint (SHA-256 of the raw X9.63 representation) is
///   used as the peer identity in the trust model.
/// - The private key is used to produce a self-signed TLS identity for
///   `Network.framework` connections.
public final class CryptoIdentityService: @unchecked Sendable {

    private let keychainTag: String
    private let lock = NSLock()
    private var cachedPrivateKey: P256.Signing.PrivateKey?

    public init(tag: String = "com.remotedesktop.identity.p256") {
        self.keychainTag = tag
    }

    private var keychainTagData: Data {
        let normalized = keychainTag.isEmpty ? "com.remotedesktop.identity.p256" : keychainTag
        return Data(normalized.utf8)
    }

    // MARK: - Public API

    /// The SHA-256 fingerprint of this device's public key.
    /// Format: hex-encoded, 64 characters.
    public var fingerprint: String {
        let pubKey = publicKey
        let raw = pubKey.x963Representation
        let hash = SHA256.hash(data: raw)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// The raw P-256 public key (X9.63 format, 65 bytes).
    public var publicKeyData: Data {
        Data(publicKey.x963Representation)
    }

    /// The P-256 private key (loaded from Keychain or freshly generated).
    public var privateKey: P256.Signing.PrivateKey {
        lock.lock()
        if let cachedPrivateKey {
            lock.unlock()
            return cachedPrivateKey
        }
        lock.unlock()

        if let existing = loadPersistedKey() {
            lock.lock()
            cachedPrivateKey = existing
            lock.unlock()
            return existing
        }

        let newKey = P256.Signing.PrivateKey()
        savePersistedKey(newKey)
        lock.lock()
        cachedPrivateKey = newKey
        lock.unlock()
        return newKey
    }

    /// Load the persisted key. On iOS the data-protection Keychain is the right, secure store. On
    /// macOS we use a 0600 file in Application Support instead: a Developer-ID (non-App-Store) app
    /// can't reliably use the data-protection Keychain (it's designed for provisioned/App-Store
    /// apps), so re-signed builds couldn't read the prior key and the device
    /// identity churned — each launch looked like a brand-new device to the host. A file is the
    /// stable, no-prompt approach Developer-ID tools use for a device keypair (FileVault encrypts it
    /// at rest). First run migrates any existing Keychain key so the identity does NOT change again.
    private func loadPersistedKey() -> P256.Signing.PrivateKey? {
        #if os(macOS)
        if let fileKey = loadFromFile() { return fileKey }
        if let keychainKey = loadFromKeychain() {
            saveToFile(keychainKey) // migrate, preserving the current identity
            return keychainKey
        }
        return nil
        #else
        return loadFromKeychain()
        #endif
    }

    private func savePersistedKey(_ key: P256.Signing.PrivateKey) {
        #if os(macOS)
        saveToFile(key)
        #else
        saveToKeychain(key)
        #endif
    }

    /// The P-256 public key derived from the private key.
    public var publicKey: P256.Signing.PublicKey {
        privateKey.publicKey
    }

    /// Sign data with the device private key.
    public func sign(_ data: Data) throws -> Data {
        let signature = try privateKey.signature(for: data)
        return signature.derRepresentation
    }

    /// Verify a signature against a known public key.
    public static func verify(signature: Data, data: Data, publicKeyData: Data) -> Bool {
        guard let pubKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData) else {
            return false
        }
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }
        return pubKey.isValidSignature(sig, for: data)
    }

    /// Compute the fingerprint for a given public key (same algorithm as `fingerprint`).
    public static func fingerprint(of publicKeyData: Data) -> String {
        let hash = SHA256.hash(data: publicKeyData)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Delete the stored key pair (for testing or key rotation).
    public func deleteKeyPair() {
        lock.lock()
        cachedPrivateKey = nil
        lock.unlock()
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keychainTagData,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
        #if os(macOS)
        try? FileManager.default.removeItem(at: keyFileURL)
        #endif
    }

    // MARK: - Keychain

    private func loadFromKeychain() -> P256.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keychainTagData,
            kSecReturnData as String: true,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? P256.Signing.PrivateKey(x963Representation: data)
    }

    private func saveToKeychain(_ key: P256.Signing.PrivateKey) {
        let keyData = key.x963Representation
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keychainTagData,
            kSecValueData as String: Data(keyData),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keychainTagData,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        // Try add first; if the item already exists, update it in-place.
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateAttrs: [String: Any] = [kSecValueData as String: Data(keyData)]
            SecItemUpdate(lookupQuery as CFDictionary, updateAttrs as CFDictionary)
        }
    }

    #if os(macOS)
    // MARK: - macOS file store (stable across re-signed Developer-ID builds)

    private var keyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let tag = keychainTag.isEmpty ? "com.remotedesktop.identity.p256" : keychainTag
        return base.appendingPathComponent("RemoteDesktopTool", isDirectory: true)
            .appendingPathComponent("\(tag).key")
    }

    private func loadFromFile() -> P256.Signing.PrivateKey? {
        guard let data = try? Data(contentsOf: keyFileURL) else { return nil }
        return try? P256.Signing.PrivateKey(x963Representation: data)
    }

    private func saveToFile(_ key: P256.Signing.PrivateKey) {
        let url = keyFileURL
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = Data(key.x963Representation)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                try data.write(to: url, options: [.atomic])
            } else if !FileManager.default.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Last-resort fallback so we don't lose the identity entirely.
            saveToKeychain(key)
        }
    }
    #endif
}
