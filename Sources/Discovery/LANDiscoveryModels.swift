import Foundation
import SharedModels

public enum LANDiscoveryConstants {
    public static let serviceType = "_screenharbor._tcp."
    public static let defaultDomain = "local."
}

public enum HostAvailabilityState: String, Codable, Hashable, Sendable {
    case available
    case busy
    case unavailable
}

public struct ResolvedHostEndpoint: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID { metadata.hostID }
    public var hostname: String
    public var port: UInt16
    public var metadata: HostAdvertisementMetadata
    public var resolvedAt: Date
    /// Bonjour service instance name observed at resolve time (e.g. the host's display name).
    /// Needed to trigger Sleep Proxy wake-on-demand by re-resolving the offloaded service while
    /// the host is asleep. Not part of the TXT record — captured from the Bonjour browser.
    public var bonjourServiceName: String?

    public init(
        hostname: String,
        port: UInt16,
        metadata: HostAdvertisementMetadata,
        resolvedAt: Date = Date(),
        bonjourServiceName: String? = nil
    ) {
        self.hostname = hostname
        self.port = port
        self.metadata = metadata
        self.resolvedAt = resolvedAt
        self.bonjourServiceName = bonjourServiceName
    }
}

public struct HostAdvertisementMetadata: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var hostID: UUID
    public var displayName: String
    public var appVersion: String
    public var signalingPort: UInt16
    public var capabilities: HostCapabilityFlags
    public var supportedCodecs: [String]
    public var availability: HostAvailabilityState
    /// SHA-256 fingerprint of the host's public key used for signaling signatures.
    /// Clients can pin this value to detect host impersonation.
    public var publicKeyFingerprint: String?
    /// When present, the host is also listening on this port with TLS-PSK using the
    /// `publicKeyFingerprint` as the pre-shared key.  Clients that support TLS should
    /// prefer this port; older clients that don't see this key fall back to plain TCP.
    public var secureTLSPort: UInt16?
    /// MAC address of the primary network interface, advertised for Wake-on-LAN.
    /// Format: colon-separated hex octets, e.g. "a1:b2:c3:d4:e5:f6".
    public var macAddress: String?
    /// Whether the host has "Wake for network access" (pmset `womp`) enabled, so clients can warn
    /// when a wake attempt won't work. `nil` = unknown (host couldn't determine it, e.g. sandboxed).
    public var wakeSupported: Bool?
    /// Whether a Wake-on-LAN *magic packet* can actually wake this Mac. `false` for Apple-Silicon
    /// Macs on Wi-Fi: their radio won't process the packet while asleep and only a LAN Sleep Proxy
    /// can wake them — so the client can steer the user to "Keep Mac Awake", Ethernet, or a Sleep
    /// Proxy instead of a doomed wake. `nil` = unknown. Independent of `wakeSupported` (pmset womp).
    public var magicWakeCapable: Bool?
    /// MagicDNS hostname (e.g. "mac.tailnet-xxxx.ts.net") when the host is on a Tailscale tailnet.
    /// Lets clients reach the host from outside the LAN without typing the address by hand.
    public var tailscaleHostname: String?
    /// 100.x.y.z Tailscale IP (CGNAT range) when the host is on a tailnet. Used as a fallback
    /// when MagicDNS isn't resolvable.
    public var tailscaleIP: String?
    /// x963 P-256 public half of the key-agreement key deterministically
    /// derived from the host's identity signing key. Clients that hold this
    /// can ECIES-seal the offer's session token so a passive observer on the
    /// plaintext signaling port cannot read it. `nil` for hosts without an
    /// identity (legacy) — clients then fall back to the plaintext token.
    public var keyAgreementPublicKey: Data?

    public init(
        protocolVersion: Int,
        hostID: UUID,
        displayName: String,
        appVersion: String,
        signalingPort: UInt16,
        capabilities: HostCapabilityFlags,
        supportedCodecs: [String] = ["h264"],
        availability: HostAvailabilityState = .available,
        publicKeyFingerprint: String? = nil,
        secureTLSPort: UInt16? = nil,
        macAddress: String? = nil,
        wakeSupported: Bool? = nil,
        magicWakeCapable: Bool? = nil,
        tailscaleHostname: String? = nil,
        tailscaleIP: String? = nil,
        keyAgreementPublicKey: Data? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.hostID = hostID
        self.displayName = displayName
        self.appVersion = appVersion
        self.signalingPort = signalingPort
        self.capabilities = capabilities
        self.supportedCodecs = supportedCodecs
        self.availability = availability
        self.publicKeyFingerprint = publicKeyFingerprint
        self.secureTLSPort = secureTLSPort
        self.macAddress = macAddress
        self.wakeSupported = wakeSupported
        self.magicWakeCapable = magicWakeCapable
        self.tailscaleHostname = tailscaleHostname
        self.tailscaleIP = tailscaleIP
        self.keyAgreementPublicKey = keyAgreementPublicKey
    }
}

public enum HostAdvertisementMetadataError: Error, Equatable {
    case missingKey(String)
    case invalidValue(String)
}

public extension HostAdvertisementMetadata {
    enum TXTKey {
        public static let protocolVersion = "pv"
        public static let hostID = "hostID"
        public static let displayName = "name"
        public static let appVersion = "app"
        public static let signalingPort = "port"
        public static let capabilities = "caps"
        public static let supportedCodecs = "codecs"
        public static let availability = "availability"
        public static let publicKeyFingerprint = "fp"
        public static let secureTLSPort = "stlsp"
        public static let macAddress = "mac"
        public static let wakeSupported = "wake"
        public static let magicWakeCapable = "mwc"
        public static let tailscaleHostname = "tsName"
        public static let tailscaleIP = "tsIP"
        public static let keyAgreementPublicKey = "kapk"
    }

    init(txtRecord: [String: Data]) throws {
        let protocolVersion = try Self.intValue(for: TXTKey.protocolVersion, in: txtRecord)
        let hostIDString = try Self.stringValue(for: TXTKey.hostID, in: txtRecord)
        let displayName = try Self.stringValue(for: TXTKey.displayName, in: txtRecord)
        let appVersion = try Self.stringValue(for: TXTKey.appVersion, in: txtRecord)
        let signalingPort = try Self.uint16Value(for: TXTKey.signalingPort, in: txtRecord)
        let capabilityNames = try Self.stringValue(for: TXTKey.capabilities, in: txtRecord)
            .split(separator: ",")
            .map { String($0) }
        let supportedCodecs = try Self.optionalStringValue(for: TXTKey.supportedCodecs, in: txtRecord)?
            .split(separator: ",")
            .map { String($0) } ?? ["h264"]
        let availabilityValue = try Self.optionalStringValue(for: TXTKey.availability, in: txtRecord) ?? HostAvailabilityState.available.rawValue
        let publicKeyFingerprint = try Self.optionalStringValue(for: TXTKey.publicKeyFingerprint, in: txtRecord)
        let secureTLSPort = try Self.optionalUint16Value(for: TXTKey.secureTLSPort, in: txtRecord)
        let macAddress = try Self.optionalStringValue(for: TXTKey.macAddress, in: txtRecord)
        let wakeSupported = try Self.optionalStringValue(for: TXTKey.wakeSupported, in: txtRecord)
            .map { $0 == "1" || $0.lowercased() == "true" }
        let magicWakeCapable = try Self.optionalStringValue(for: TXTKey.magicWakeCapable, in: txtRecord)
            .map { $0 == "1" || $0.lowercased() == "true" }
        let tailscaleHostname = try Self.optionalStringValue(for: TXTKey.tailscaleHostname, in: txtRecord)
        let tailscaleIP = try Self.optionalStringValue(for: TXTKey.tailscaleIP, in: txtRecord)
        let keyAgreementPublicKey = try Self.optionalStringValue(for: TXTKey.keyAgreementPublicKey, in: txtRecord)
            .flatMap { Data(base64Encoded: $0) }

        guard let hostID = UUID(uuidString: hostIDString) else {
            throw HostAdvertisementMetadataError.invalidValue(TXTKey.hostID)
        }
        guard let availability = HostAvailabilityState(rawValue: availabilityValue) else {
            throw HostAdvertisementMetadataError.invalidValue(TXTKey.availability)
        }

        self.init(
            protocolVersion: protocolVersion,
            hostID: hostID,
            displayName: displayName,
            appVersion: appVersion,
            signalingPort: signalingPort,
            capabilities: HostCapabilityFlags(stableNames: capabilityNames),
            supportedCodecs: supportedCodecs,
            availability: availability,
            publicKeyFingerprint: publicKeyFingerprint,
            secureTLSPort: secureTLSPort,
            macAddress: macAddress,
            wakeSupported: wakeSupported,
            magicWakeCapable: magicWakeCapable,
            tailscaleHostname: tailscaleHostname,
            tailscaleIP: tailscaleIP,
            keyAgreementPublicKey: keyAgreementPublicKey
        )
    }

    var txtRecord: [String: Data] {
        var record: [String: Data] = [
            TXTKey.protocolVersion: Data(String(protocolVersion).utf8),
            TXTKey.hostID: Data(hostID.uuidString.utf8),
            TXTKey.displayName: Data(displayName.utf8),
            TXTKey.appVersion: Data(appVersion.utf8),
            TXTKey.signalingPort: Data(String(signalingPort).utf8),
            TXTKey.capabilities: Data(capabilities.stableNames.joined(separator: ",").utf8),
            TXTKey.supportedCodecs: Data(supportedCodecs.joined(separator: ",").utf8),
            TXTKey.availability: Data(availability.rawValue.utf8)
        ]
        if let fingerprint = publicKeyFingerprint, !fingerprint.isEmpty {
            record[TXTKey.publicKeyFingerprint] = Data(fingerprint.utf8)
        }
        if let tlsPort = secureTLSPort {
            record[TXTKey.secureTLSPort] = Data(String(tlsPort).utf8)
        }
        if let mac = macAddress {
            record[TXTKey.macAddress] = Data(mac.utf8)
        }
        if let wakeSupported {
            record[TXTKey.wakeSupported] = Data((wakeSupported ? "1" : "0").utf8)
        }
        if let magicWakeCapable {
            record[TXTKey.magicWakeCapable] = Data((magicWakeCapable ? "1" : "0").utf8)
        }
        if let tsName = tailscaleHostname, !tsName.isEmpty {
            record[TXTKey.tailscaleHostname] = Data(tsName.utf8)
        }
        if let tsIP = tailscaleIP, !tsIP.isEmpty {
            record[TXTKey.tailscaleIP] = Data(tsIP.utf8)
        }
        if let kapk = keyAgreementPublicKey, !kapk.isEmpty {
            record[TXTKey.keyAgreementPublicKey] = Data(kapk.base64EncodedString().utf8)
        }
        return record
    }

    private static func stringValue(for key: String, in txtRecord: [String: Data]) throws -> String {
        guard let data = txtRecord[key] else {
            throw HostAdvertisementMetadataError.missingKey(key)
        }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw HostAdvertisementMetadataError.invalidValue(key)
        }
        return value
    }

    private static func optionalStringValue(for key: String, in txtRecord: [String: Data]) throws -> String? {
        guard let data = txtRecord[key] else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw HostAdvertisementMetadataError.invalidValue(key)
        }
        return value
    }

    private static func intValue(for key: String, in txtRecord: [String: Data]) throws -> Int {
        let string = try stringValue(for: key, in: txtRecord)
        guard let value = Int(string) else {
            throw HostAdvertisementMetadataError.invalidValue(key)
        }
        return value
    }

    private static func uint16Value(for key: String, in txtRecord: [String: Data]) throws -> UInt16 {
        let string = try stringValue(for: key, in: txtRecord)
        guard let value = UInt16(string) else {
            throw HostAdvertisementMetadataError.invalidValue(key)
        }
        return value
    }

    private static func optionalUint16Value(for key: String, in txtRecord: [String: Data]) throws -> UInt16? {
        guard let string = try optionalStringValue(for: key, in: txtRecord) else { return nil }
        guard let value = UInt16(string) else {
            throw HostAdvertisementMetadataError.invalidValue(key)
        }
        return value
    }
}
