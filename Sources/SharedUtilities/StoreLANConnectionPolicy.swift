import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Focused remote desktop clients use a directly connected LAN in the App Store
/// edition (App Review 4.2.7). Private VPN addresses alone do not prove locality.
public enum StoreLANConnectionPolicy {
    public static var requiresLAN: Bool {
        Bundle.main.bundleIdentifier == "com.mesutcy.remotedesktop.stream"
            && Bundle.main.object(forInfoDictionaryKey: "VampDistributionChannel") as? String == "app-store"
    }

    public struct NotOnLocalNetwork: LocalizedError, Sendable {
        public var errorDescription: String? {
            "The App Store edition, App Stream connects to your own Mac on the same Wi-Fi or Ethernet network. The website edition also supports private Tailscale connections."
        }
        public init() {}
    }

    /// Resolves once and returns a numeric address, so the actual connection
    /// uses the address whose physical-interface subnet was checked.
    public static func validatedHost(_ host: String) async throws -> String {
        try await Task.detached(priority: .utility) {
            try resolveLocalHost(host)
        }.value
    }

    /// Pure byte-level check shared by IPv4 and IPv6 interface matching.
    public static func isOnSubnet(address: [UInt8], localAddress: [UInt8], netmask: [UInt8]) -> Bool {
        guard [4, 16].contains(address.count), localAddress.count == address.count,
              netmask.count == address.count, netmask.contains(where: { $0 != 0 }),
              address != localAddress else { return false }
        if address.count == 4 {
            guard address[0] != 0, address[0] != 127, address[0] < 224,
                  // Tailscale's CGNAT space remains website-only.
                  !(address[0] == 100 && (64...127).contains(address[1])),
                  zip(address, netmask).contains(where: { ($0 & ~$1) != ~$1 }) else { return false }
        } else {
            guard address[0] != 0xff, address.contains(where: { $0 != 0 }) else { return false }
        }
        return zip(zip(address, localAddress), netmask).allSatisfy { pair, mask in
            (pair.0 & mask) == (pair.1 & mask)
        }
    }

    private static func resolveLocalHost(_ host: String) throws -> String {
        #if canImport(Darwin)
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { throw NotOnLocalNetwork() }
        defer { freeifaddrs(interfaces) }
        var resolved: UnsafeMutablePointer<addrinfo>?
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        let candidate = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard getaddrinfo(candidate, nil, &hints, &resolved) == 0, let resolved else {
            throw NotOnLocalNetwork()
        }
        defer { freeaddrinfo(resolved) }
        var destination: UnsafeMutablePointer<addrinfo>? = resolved
        while let entry = destination {
            defer { destination = entry.pointee.ai_next }
            guard let address = entry.pointee.ai_addr, let bytes = addressBytes(address) else { continue }
            var interface: UnsafeMutablePointer<ifaddrs>? = interfaces
            while let current = interface {
                defer { interface = current.pointee.ifa_next }
                let name = String(cString: current.pointee.ifa_name)
                // en interfaces are Wi-Fi/Ethernet on Apple platforms; utun,
                // loopback, peer-to-peer and tunnel interfaces cannot qualify.
                guard name.hasPrefix("en"), current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                      let local = current.pointee.ifa_addr, let mask = current.pointee.ifa_netmask,
                      let localBytes = addressBytes(local), let maskBytes = addressBytes(mask),
                      isOnSubnet(address: bytes, localAddress: localBytes, netmask: maskBytes) else { continue }
                var numeric = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, entry.pointee.ai_addrlen, &numeric,
                                  socklen_t(numeric.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let result = String(cString: numeric)
                if bytes.count == 16, bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 {
                    // Link-local IPv6 needs the physical interface's scope.
                    return result.components(separatedBy: "%")[0] + "%" + name
                }
                return result
            }
        }
        #endif
        throw NotOnLocalNetwork()
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
