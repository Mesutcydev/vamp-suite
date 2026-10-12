import Foundation
import Network
import OSLog

/// Sends a Wake-on-LAN magic packet to a target MAC address.
///
/// The magic packet is: 6 x 0xFF followed by 16 repetitions of the 6-byte MAC address.
/// Each burst sends 3 packets per connection to compensate for UDP loss, and targets
/// both WOL ports (9 and 7). Destinations cover global broadcast, subnet broadcast,
/// and direct host when an IPv4 address is known.
struct WakeOnLANService {
    private static let logger = Logger(subsystem: "com.mesutcy.remotedesktop.ios", category: "WakeOnLAN")

    enum WakeError: Error, LocalizedError {
        case invalidMACAddress(String)
        case sendFailed(Error)

        var errorDescription: String? {
            switch self {
            case .invalidMACAddress(let mac):
                return "Invalid MAC address: \(mac)"
            case .sendFailed(let underlying):
                return "Wake packet send failed: \(underlying.localizedDescription)"
            }
        }
    }

    private static let wolPorts: [NWEndpoint.Port] = [9, 7]
    private static let burstCount = 3
    /// Per-connection ceiling so a broadcast that stalls in `.preparing` can't hang the wake or leak
    /// the NWConnection. UDP `.ready` is effectively instant, so legitimate sends complete well before.
    private static let sendTimeout: TimeInterval = 3

    /// Sends magic packets to the given MAC address.
    /// - Parameters:
    ///   - macAddress: Colon- or dash-separated hex octets, e.g. "a1:b2:c3:d4:e5:f6".
    ///   - targetHost: Optional known host IPv4 address, used to derive subnet broadcast.
    func wake(macAddress: String, targetHost: String? = nil) async throws {
        let macBytes = try parseMACBytes(macAddress)
        let packet = buildMagicPacket(macBytes: macBytes)

        let hosts = destinationHosts(targetHost: targetHost)
        Self.logger.info("WoL: dispatching magic packets to \(hosts.count, privacy: .public) destination(s) on ports 9/7")

        var lastError: Error?
        var sent = false
        for host in hosts {
            for port in Self.wolPorts {
                do {
                    try await sendPackets(packet, to: host, port: port)
                    sent = true
                    Self.logger.info("WoL: sent to \(String(describing: host), privacy: .public):\(port.rawValue, privacy: .public)")
                } catch {
                    lastError = error
                    Self.logger.error("WoL: failed to \(String(describing: host), privacy: .public):\(port.rawValue, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        if !sent, let lastError {
            Self.logger.error("WoL: every destination failed — magic-packet wake did not send")
            throw WakeError.sendFailed(lastError)
        }
    }

    private func parseMACBytes(_ mac: String) throws -> [UInt8] {
        let parts = mac.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ":- "))
            .filter { !$0.isEmpty }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else {
            throw WakeError.invalidMACAddress(mac)
        }
        return bytes
    }

    private func buildMagicPacket(macBytes: [UInt8]) -> Data {
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }
        return packet
    }

    private func destinationHosts(targetHost: String?) -> [NWEndpoint.Host] {
        var addresses: [String] = []

        for broadcast in localInterfaceBroadcastAddresses() {
            if !addresses.contains(broadcast) {
                addresses.append(broadcast)
            }
        }

        if let targetHost {
            let trimmed = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let broadcast = subnetBroadcastAddress(fromIPv4: trimmed), !addresses.contains(broadcast) {
                    addresses.append(broadcast)
                }
                if isIPv4(trimmed), !addresses.contains(trimmed) {
                    addresses.append(trimmed)
                }
            }
        }

        if !addresses.contains("255.255.255.255") {
            addresses.append("255.255.255.255")
        }

        return addresses.map { NWEndpoint.Host($0) }
    }

    private func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let octet = Int(part), octet >= 0, octet <= 255 else { return false }
            return true
        }
    }

    private func subnetBroadcastAddress(fromIPv4 host: String) -> String? {
        guard let target = ipv4Value(host) else { return nil }
        // Use the netmask of the local interface whose subnet contains the target, so the broadcast
        // is correct for /16, /23, etc. — not just the /24 we used to assume. Fall back to /24 only
        // when no local interface matches the target's subnet.
        for iface in localIPv4Interfaces() where (iface.address & iface.mask) == (target & iface.mask) {
            return ipv4String((target & iface.mask) | ~iface.mask)
        }
        let fallbackMask: UInt32 = 0xFFFF_FF00 // /24
        return ipv4String((target & fallbackMask) | ~fallbackMask)
    }

    private func localInterfaceBroadcastAddresses() -> [String] {
        var broadcasts: [String] = []
        for iface in localIPv4Interfaces() {
            let broadcast = ipv4String((iface.address & iface.mask) | ~iface.mask)
            if !broadcasts.contains(broadcast) {
                broadcasts.append(broadcast)
            }
        }
        return broadcasts
    }

    /// Up, broadcast-capable, non-loopback en*/bridge* interfaces as native-byte-order
    /// (address, netmask) pairs. Shared by broadcast-address derivation so the netmask is always real.
    private func localIPv4Interfaces() -> [(address: UInt32, mask: UInt32)] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var result: [(address: UInt32, mask: UInt32)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)

            guard (flags & IFF_UP) != 0,
                  (flags & IFF_BROADCAST) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let sockaddr = entry.ifa_addr,
                  sockaddr.pointee.sa_family == UInt8(AF_INET),
                  let netmask = entry.ifa_netmask else {
                continue
            }

            let interfaceName = String(cString: entry.ifa_name)
            guard interfaceName.hasPrefix("en") || interfaceName.hasPrefix("bridge") else {
                continue
            }

            let addressValue = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let maskValue = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            result.append((address: addressValue, mask: maskValue))
        }
        return result
    }

    private func ipv4Value(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    private func ipv4String(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    /// Opens one UDP connection and sends `burstCount` copies of the packet sequentially.
    private func sendPackets(_ data: Data, to host: NWEndpoint.Host, port: NWEndpoint.Port) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class ResumeGate: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false

                func take() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return false }
                    resumed = true
                    return true
                }
            }

            let connection = NWConnection(host: host, port: port, using: .udp)
            let resumeGate = ResumeGate()

            @Sendable func resumeOnce(_ result: Result<Void, Error>) {
                guard resumeGate.take() else { return }
                connection.cancel()
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    @Sendable func sendNext(_ remaining: Int) {
                        guard remaining > 0 else {
                            resumeOnce(.success(()))
                            return
                        }
                        connection.send(content: data, completion: .contentProcessed { error in
                            if let error {
                                resumeOnce(.failure(error))
                            } else {
                                sendNext(remaining - 1)
                            }
                        })
                    }
                    sendNext(Self.burstCount)
                case .failed(let error):
                    resumeOnce(.failure(error))
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))

            // Safety net: guarantee the continuation is resumed and the connection torn down even if
            // it never reaches .ready or .failed (e.g. a broadcast that stalls in .preparing). Without
            // this, each stuck destination would leak an NWConnection + continuation and the caller's
            // "waking…" UI would never clear. resumeOnce() is gated, so this is a no-op once finished.
            Task {
                try? await Task.sleep(for: .seconds(Self.sendTimeout))
                resumeOnce(.failure(WakeError.sendFailed(URLError(.timedOut))))
            }
        }
    }
}
