import Foundation

public enum PublicKeyFingerprint {
    public static func isValid(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        let validCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        return value.unicodeScalars.allSatisfy { validCharacters.contains($0) }
    }
}

public struct HostIdentity: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var modelName: String
    public var osVersion: String
    public var appVersion: String
    public var publicKeyFingerprint: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        modelName: String,
        osVersion: String,
        appVersion: String,
        publicKeyFingerprint: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.modelName = modelName
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.publicKeyFingerprint = publicKeyFingerprint
        self.createdAt = createdAt
    }
}

/// Derive a deterministic UUID from a peer's public-key fingerprint, so an identity's
/// id is stable across launches (no random UUID that breaks id-based trust matching).
func stableUUID(fromFingerprint publicKeyFingerprint: String) -> UUID? {
    let normalized = publicKeyFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.count == 64 else { return nil }

    var bytes: [UInt8] = []
    bytes.reserveCapacity(16)
    var index = normalized.startIndex
    for _ in 0..<16 {
        let next = normalized.index(index, offsetBy: 2)
        guard next <= normalized.endIndex,
              let byte = UInt8(normalized[index..<next], radix: 16) else {
            return nil
        }
        bytes.append(byte)
        index = next
    }

    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

public extension HostIdentity {
    static func stableID(publicKeyFingerprint: String) -> UUID? {
        stableUUID(fromFingerprint: publicKeyFingerprint)
    }
}

public extension ClientIdentity {
    /// Stable, fingerprint-derived id so the host's id-keyed trust lookup keeps matching
    /// this client across cold launches (the fingerprint comes from the persistent Keychain key).
    static func stableID(publicKeyFingerprint: String) -> UUID? {
        stableUUID(fromFingerprint: publicKeyFingerprint)
    }
}

public struct ClientIdentity: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var deviceModel: String
    public var osVersion: String
    public var appVersion: String
    public var publicKeyFingerprint: String

    public init(
        id: UUID = UUID(),
        displayName: String,
        deviceModel: String,
        osVersion: String,
        appVersion: String,
        publicKeyFingerprint: String
    ) {
        self.id = id
        self.displayName = displayName
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.publicKeyFingerprint = publicKeyFingerprint
    }
}

public struct TrustedPeer: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var fingerprint: String
    public var trustedAt: Date
    public var lastSeenAt: Date?
    public var isRevoked: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        fingerprint: String,
        trustedAt: Date = Date(),
        lastSeenAt: Date? = nil,
        isRevoked: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.fingerprint = fingerprint
        self.trustedAt = trustedAt
        self.lastSeenAt = lastSeenAt
        self.isRevoked = isRevoked
    }
}
