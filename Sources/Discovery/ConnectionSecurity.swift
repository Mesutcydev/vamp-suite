#if canImport(Network)
import Foundation
import Network
import CryptoKit
import os

/// Provides TLS-enabled `NWParameters` using a pre-shared key (PSK) model.
///
/// Rather than full PKI certificates, we use a connection PIN / session token:
/// - Host generates a 12-digit connection PIN displayed to the user.
/// - Client enters the PIN to derive a shared symmetric key.
/// - TLS is established using the derived key for encryption.
///
/// Additionally, a session token (random 32 bytes) is generated during signaling
/// and must be presented on the data channel to bind it to the authenticated session.
public enum ConnectionSecurity {
    private static let tlsPSKIdentity = Data("remotedesktop".utf8)
    private static let tlsPSKCiphersuite = tls_ciphersuite_t(rawValue: UInt16(0x00AD))

    // MARK: - TLS Parameters

    /// Create TCP parameters with TLS enabled.
    /// Uses `.default` TLS with peer-to-peer support.
    public static func tlsTCPParameters(psk: SymmetricKey? = nil) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()

        if let psk {
            // Set pre-shared key for the TLS handshake
            let pskData = psk.withUnsafeBytes { Data($0) }
            let dispatchData = pskData.withUnsafeBytes {
                DispatchData(bytes: $0)
            }
            sec_protocol_options_add_pre_shared_key(
                tlsOptions.securityProtocolOptions,
                dispatchData as __DispatchData,
                // PSK identity
                tlsPSKIdentity.withUnsafeBytes {
                    DispatchData(bytes: $0) as __DispatchData
                }
            )
            if let tlsPSKCiphersuite {
                sec_protocol_options_append_tls_ciphersuite(
                    tlsOptions.securityProtocolOptions,
                    tlsPSKCiphersuite
                )
            }
        }

        // Allow self-signed certs for peer-to-peer
        sec_protocol_options_set_peer_authentication_required(
            tlsOptions.securityProtocolOptions,
            psk != nil  // require auth only when PSK is set
        )

        let params = NWParameters(tls: tlsOptions, tcp: keepaliveTCPOptions())
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        return params
    }

    /// TCP options with kernel keepalive so half-open signaling connections
    /// (NAT timeout, peer power loss) fail within ~15 s instead of hanging.
    public static func keepaliveTCPOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 2
        return tcp
    }

    /// Plain-TCP parameters with keepalive enabled (peer-to-peer allowed).
    public static func keepaliveTCPParameters() -> NWParameters {
        let params = NWParameters(tls: nil, tcp: keepaliveTCPOptions())
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        return params
    }

    /// Derive a symmetric key from a 12-digit PIN.
    /// Uses HKDF with a fixed salt so both sides derive the same key from the same PIN.
    public static func deriveKey(from pin: String) -> SymmetricKey {
        let pinData = Data(pin.utf8)
        let salt = Data("com.remotedesktop.psk.salt.v1".utf8)
        let info = Data("connection-encryption".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pinData),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    // MARK: - Connection PIN

    /// Generate a random 12-digit pairing code.
    ///
    /// 12 decimal digits provide ~39.8 bits of entropy, significantly better than
    /// legacy 6-digit codes (~19.8 bits), while remaining easy to type.
    public static func generateConnectionPIN() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let pin = value % 1_000_000_000_000
        return String(format: "%012llu", pin)
    }

    // MARK: - Session Token

    /// Generate a random 32-byte session token for binding signaling to data channel.
    public static func generateSessionToken() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// Encode a session token as a hex string (for embedding in SDP).
    public static func tokenToHex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// Decode a hex-encoded session token.
    public static func tokenFromHex(_ hex: String) -> Data? {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex)
            guard let boundIndex = nextIndex,
                  let byte = UInt8(hex[index..<boundIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = boundIndex
        }
        return data
    }

    // MARK: - Rate Limiting

    /// Simple per-IP connection rate limiter.
    /// Tracks connection attempts and rejects if too many arrive too fast.
    public final class ConnectionRateLimiter: @unchecked Sendable {
        private var attempts: [String: [Date]] = [:]
        private let lock = NSLock()
        private let maxAttempts: Int
        private let windowSeconds: TimeInterval
        private let logger = Logger(subsystem: "com.remotedesktop.security", category: "RateLimit")

        /// - Parameters:
        ///   - maxAttempts: Maximum connections per IP within the window.
        ///   - windowSeconds: Time window in seconds.
        public init(maxAttempts: Int = 5, windowSeconds: TimeInterval = 60) {
            self.maxAttempts = maxAttempts
            self.windowSeconds = windowSeconds
        }

        /// Check if a connection from this IP should be allowed.
        /// Returns `true` if allowed, `false` if rate-limited.
        public func shouldAllow(ip: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            let now = Date()
            let cutoff = now.addingTimeInterval(-windowSeconds)

            // Clean old entries
            attempts[ip] = (attempts[ip] ?? []).filter { $0 > cutoff }

            let count = attempts[ip]?.count ?? 0
            if count >= maxAttempts {
                logger.warning("Rate limited connection from \(ip): \(count) attempts in \(Int(self.windowSeconds))s")
                return false
            }

            attempts[ip, default: []].append(now)
            return true
        }

        /// Reset rate limit state (e.g., after successful auth).
        public func reset(ip: String) {
            lock.lock()
            attempts.removeValue(forKey: ip)
            lock.unlock()
        }

        /// Clean up stale entries periodically.
        public func purgeStaleEntries() {
            lock.lock()
            let cutoff = Date().addingTimeInterval(-windowSeconds)
            for (ip, dates) in attempts {
                let filtered = dates.filter { $0 > cutoff }
                if filtered.isEmpty {
                    attempts.removeValue(forKey: ip)
                } else {
                    attempts[ip] = filtered
                }
            }
            lock.unlock()
        }
    }
}
#endif
