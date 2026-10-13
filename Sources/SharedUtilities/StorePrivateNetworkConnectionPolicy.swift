import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Store Stream connects to physical LAN peers or private Tailscale peers.
/// Pairing and host identity verification still run after this network check.
public enum StorePrivateNetworkConnectionPolicy {
    public static var requiresPrivateNetwork: Bool {
        requiresPrivateNetwork(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            distributionChannel: Bundle.main.object(forInfoDictionaryKey: "VampDistributionChannel") as? String)
    }

    public static func requiresPrivateNetwork(bundleIdentifier: String?, distributionChannel: String?) -> Bool {
        bundleIdentifier == "com.mesutcy.remotedesktop.stream" && distributionChannel == "app-store"
    }

    public struct NotOnPrivateNetwork: LocalizedError, Sendable {
        public var errorDescription: String? {
            "Connect to your own Mac on the same Wi-Fi or Ethernet network, or connect both devices to your private Tailscale network."
        }
        public init() {}
    }

    /// Resolves once and returns a numeric address, so the actual connection
    /// uses the private address that was checked, including MagicDNS names.
    public static func validatedHost(_ host: String) async throws -> String {
        try await Task.detached(priority: .utility) {
            try resolvePrivateHost(host)
        }.value
    }

    public struct NetworkInterface: Equatable, Sendable {
        public let name: String
        public let address: [UInt8]
        public let netmask: [UInt8]
        public let isUp: Bool

        public init(name: String, address: [UInt8], netmask: [UInt8] = [], isUp: Bool) {
            self.name = name
            self.address = address
            self.netmask = netmask
            self.isUp = isUp
        }
    }

    public static func permits(address: [UInt8], interfaces: [NetworkInterface]) -> Bool {
        permittedInterface(for: address, interfaces: interfaces) != nil
    }

    public static func isTailscaleAddress(_ address: [UInt8]) -> Bool {
        if address.count == 4 {
            return address[0] == 100 && (64...127).contains(address[1])
        }
        return address.count == 16 && address.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
    }

    public static func isTailscaleHost(_ host: String) -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        let candidate = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var ipv4 = in_addr()
        if inet_pton(AF_INET, candidate, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4) { isTailscaleAddress(Array($0)) }
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, candidate, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { isTailscaleAddress(Array($0)) }
        }
        #endif
        return false
    }

    private static func permittedInterface(for address: [UInt8], interfaces: [NetworkInterface]) -> NetworkInterface? {
        guard !interfaces.contains(where: { $0.isUp && $0.address == address }) else { return nil }
        if isTailscaleAddress(address) {
            // A CGNAT address or DNS suffix alone is insufficient. Require an
            // active private tunnel carrying a Tailscale address on this device.
            return interfaces.first {
                $0.isUp && ($0.name.hasPrefix("utun") || $0.name.hasPrefix("tun"))
                    && isTailscaleAddress($0.address) && address != $0.address
            }
        }
        return interfaces.first {
            $0.isUp && $0.name.hasPrefix("en")
                && isOnSubnet(address: address, localAddress: $0.address, netmask: $0.netmask)
        }
    }

    /// Pure byte-level check shared by IPv4 and IPv6 interface matching.
    public static func isOnSubnet(address: [UInt8], localAddress: [UInt8], netmask: [UInt8]) -> Bool {
        guard [4, 16].contains(address.count), localAddress.count == address.count,
              netmask.count == address.count, netmask.contains(where: { $0 != 0 }),
              address != localAddress else { return false }
        if address.count == 4 {
            guard address[0] != 0, address[0] != 127, address[0] < 224,
                  // Tailscale peers use the active-tunnel check instead.
                  !(address[0] == 100 && (64...127).contains(address[1])),
                  zip(address, netmask).contains(where: { ($0 & ~$1) != ~$1 }) else { return false }
        } else {
            guard address[0] != 0xff, address.contains(where: { $0 != 0 }) else { return false }
        }
        return zip(zip(address, localAddress), netmask).allSatisfy { pair, mask in
            (pair.0 & mask) == (pair.1 & mask)
        }
    }

    private static func resolvePrivateHost(_ host: String) throws -> String {
        #if canImport(Darwin)
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { throw NotOnPrivateNetwork() }
        defer { freeifaddrs(interfaces) }
        var networkInterfaces: [NetworkInterface] = []
        var interface: UnsafeMutablePointer<ifaddrs>? = interfaces
        while let current = interface {
            defer { interface = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  let bytes = addressBytes(address) else { continue }
            networkInterfaces.append(NetworkInterface(
                name: String(cString: current.pointee.ifa_name),
                address: bytes,
                netmask: current.pointee.ifa_netmask.flatMap { addressBytes($0) } ?? [],
                isUp: current.pointee.ifa_flags & UInt32(IFF_UP) != 0))
        }
        var resolved: UnsafeMutablePointer<addrinfo>?
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        let candidate = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard getaddrinfo(candidate, nil, &hints, &resolved) == 0, let resolved else {
            throw NotOnPrivateNetwork()
        }
        defer { freeaddrinfo(resolved) }
        var destination: UnsafeMutablePointer<addrinfo>? = resolved
        while let entry = destination {
            defer { destination = entry.pointee.ai_next }
            guard let address = entry.pointee.ai_addr, let bytes = addressBytes(address) else { continue }
            if let allowed = permittedInterface(for: bytes, interfaces: networkInterfaces) {
                var numeric = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, entry.pointee.ai_addrlen, &numeric,
                                  socklen_t(numeric.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let result = String(cString: numeric)
                if bytes.count == 16, bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 {
                    // Link-local IPv6 needs the physical interface's scope.
                    return result.components(separatedBy: "%")[0] + "%" + allowed.name
                }
                return result
            }
        }
        #endif
        throw NotOnPrivateNetwork()
    }

    #if canImport(Darwin)
    private static func addressBytes(_ address: UnsafePointer<sockaddr>) -> [UInt8]? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            return withUnsafeBytes(of: &value) { Array($0) }
        case AF_INET6:
            var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            return withUnsafeBytes(of: &value) { Array($0) }
        default: return nil
        }
    }
    #endif
}
