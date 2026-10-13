import Foundation

/// QR addresses follow the user's selected private network. A local interface
/// must never override an explicit Tailscale selection on a dual-homed Mac.
public enum HostPairingAddress {
    public enum Network: String, CaseIterable, Sendable {
        case localWiFi, tailscale
    }

    public static func make(network: Network, localIPv4: String?, tailscaleIPv4: String?,
                            port: UInt16) -> String? {
        let host = network == .localWiFi ? localIPv4 : tailscaleIPv4
        guard let host, isUsableIPv4(host) else { return nil }
        if network == .tailscale && !StorePrivateNetworkConnectionPolicy.isTailscaleHost(host) {
            return nil
        }
        return "\(host):\(port)"
    }

    private static func isUsableIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let first = UInt8(parts[0]), first > 0, first < 224,
              parts.dropFirst().allSatisfy({ UInt8($0) != nil }) else { return false }
        return first != 127 && !host.hasPrefix("169.254.")
    }
}
