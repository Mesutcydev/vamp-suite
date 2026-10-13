import Foundation
import SharedUtilities
import Permissions
#if os(macOS)
import AppKit
import Darwin
#endif

/// Tailscale identity for this host, when the device is signed in to a tailnet.
struct TailscaleConnectionInfo: Equatable, Sendable {
    let ipAddress: String
    let dnsName: String?

    var connectHost: String {
        dnsName ?? ipAddress
    }

    var connectAddress: String {
        // Numeric IPv4 works even when MagicDNS is disabled and matches the
        // IPv4 listener. Keep DNS for the optional Tailscale Serve HTTPS URL.
        "\(ipAddress):\(RemoteDesktopConstants.defaultSignalingPort)"
    }

    /// Tailscale Serve terminates HTTPS on the tailnet hostname and proxies to
    /// the loopback browser service. This optional address is only reachable
    /// after the operator has enabled `tailscale serve`.
    var browserServeURL: String? {
        guard let dnsName, !dnsName.isEmpty else { return nil }
        return "https://\(dnsName)"
    }

    /// The direct tailnet address works without Tailscale Serve. It is the
    /// primary Safari address because the host listener accepts the 100.x
    /// interface whenever Tailscale is online. Loopback is intentionally never
    /// used for a remote device.
    func browserControlURL(port: UInt16) -> String {
        "http://\(ipAddress):\(port)"
    }
}

/// The small amount of Tailscale state the host dashboard needs to explain
/// whether a Safari connection can work. `info == nil` means the daemon is
/// either signed out, stopped, or not installed; `installed` lets the UI tell
/// those cases apart without guessing from an empty address list.
struct TailscaleDetectionSnapshot: Equatable, Sendable {
    let info: TailscaleConnectionInfo?
    let installed: Bool

    static let empty = Self(info: nil, installed: false)

    var isConnected: Bool { info != nil }
}

func getTailscaleDetectionSnapshot() -> TailscaleDetectionSnapshot {
    let info = getTailscaleConnectionInfo()
    return TailscaleDetectionSnapshot(info: info, installed: info != nil || isTailscaleInstalled())
}

/// Detects whether this Mac is on a Tailscale tailnet and returns its addressable identity.
/// Prefers the CLI status JSON (richest data), falls back to `tailscale ip`, then a raw scan of
/// the 100.64.0.0/10 CGNAT range on local interfaces — the last path works in sandboxed builds
/// where launching the CLI isn't permitted.
func getTailscaleConnectionInfo() -> TailscaleConnectionInfo? {
    // The daemon may retain its last IP while disconnected. Only advertise an
    // address currently assigned to an active tunnel, including in App Sandbox.
    guard let activeAddress = getTailscaleIPFromInterfaces() else { return nil }
    if let statusOutput = runTailscaleCommand(["status", "--json"]),
       let data = statusOutput.data(using: .utf8),
       let payload = try? JSONDecoder().decode(TailscaleStatusPayload.self, from: data),
       let device = payload.device,
       let ipAddress = device.tailscaleIPs?.first(where: { $0 == activeAddress && tsIsValidIPAddress($0) }) {
        let dnsName = device.dnsName?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return TailscaleConnectionInfo(ipAddress: ipAddress, dnsName: dnsName)
    }

    if let ipOutput = runTailscaleCommand(["ip", "-4"]),
       let ipAddress = ipOutput
        .components(separatedBy: .newlines)
        .first(where: { $0 == activeAddress && tsIsValidIPAddress($0) }) {
        return TailscaleConnectionInfo(ipAddress: ipAddress, dnsName: nil)
    }

    return TailscaleConnectionInfo(ipAddress: activeAddress, dnsName: nil)
}

private func isTailscaleInstalled() -> Bool {
    if findTailscaleBinary() != nil { return true }

    let fileManager = FileManager.default
    let applicationPaths = [
        "/Applications/Tailscale.app",
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Tailscale.app").path
    ]
    return applicationPaths.contains { fileManager.fileExists(atPath: $0) }
}

#if os(macOS)
/// Opens the installed Tailscale client. The daemon still owns the VPN
/// permission flow, so the host intentionally hands activation to the
/// official app instead of trying to run `tailscale up` behind the user's
/// back. The caller can poll `getTailscaleDetectionSnapshot()` afterwards.
@discardableResult
func openTailscaleApplication() -> Bool {
    let fileManager = FileManager.default
    let applicationPaths = [
        "/Applications/Tailscale.app",
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Tailscale.app").path
    ]

    for path in applicationPaths where fileManager.fileExists(atPath: path) {
        if NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
            return true
        }
    }

    if let url = URL(string: "tailscale://") {
        return NSWorkspace.shared.open(url)
    }
    return false
}
#endif

// MARK: - Internals

private struct TailscaleStatusPayload: Decodable {
    struct SelfDevice: Decodable {
        let dnsName: String?
        let tailscaleIPs: [String]?

        enum CodingKeys: String, CodingKey {
            case dnsName = "DNSName"
            case tailscaleIPs = "TailscaleIPs"
        }
    }

    let device: SelfDevice?

    enum CodingKeys: String, CodingKey {
        case device = "Self"
    }
}

private let tailscaleBinaryPaths: [String] = [
    "/usr/local/bin/tailscale",
    "/opt/homebrew/bin/tailscale",
    "/usr/bin/tailscale",
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
]

private let tailscaleCommandTimeout: DispatchTimeInterval = .seconds(3)

private func findTailscaleBinary() -> String? {
    tailscaleBinaryPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func isSandboxedApp() -> Bool {
    MacHostRuntimePolicy.current.isSandboxedDistribution
}

private func runTailscaleCommand(_ arguments: [String]) -> String? {
    guard !isSandboxedApp() else { return nil }
    guard let binaryPath = findTailscaleBinary() else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = arguments

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice

    let outputReader = DispatchGroup()
    let output = LockedData()
    outputReader.enter()
    DispatchQueue.global(qos: .utility).async {
        output.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
        outputReader.leave()
    }

    let termination = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in termination.signal() }

    do {
        try process.run()
    } catch {
        outputPipe.fileHandleForWriting.closeFile()
        outputReader.wait()
        return nil
    }

    guard termination.wait(timeout: .now() + tailscaleCommandTimeout) == .success else {
        process.terminate()
        if termination.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = termination.wait(timeout: .now() + .milliseconds(500))
        }
        outputPipe.fileHandleForWriting.closeFile()
        outputReader.wait()
        return nil
    }

    outputReader.wait()
    guard process.terminationStatus == 0 else { return nil }

    let data = output.value
    guard let output = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !output.isEmpty else {
        return nil
    }

    // The CLI sometimes prints diagnostic text on stdout while still exiting 0
    // (e.g. "not running"). Reject obvious non-data outputs so we don't poison UI.
    let normalized = output.lowercased()
    let looksLikeError = ["error", "failed", "not running", "permission denied", "cannot", "unable"]
        .contains { normalized.contains($0) }
    if looksLikeError { return nil }

    return output
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func set(_ newValue: Data) {
        lock.lock()
        data = newValue
        lock.unlock()
    }
}

private func getTailscaleIPFromInterfaces() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        let name = String(cString: ptr.pointee.ifa_name)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
              name.hasPrefix("utun") || name.hasPrefix("tun") else { continue }
        guard let addr = ptr.pointee.ifa_addr,
              addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                          &buf, socklen_t(buf.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let ip = String(cString: buf)
        let parts = ip.split(separator: ".")
        guard parts.count == 4,
              parts[0] == "100",
              let second = Int(parts[1]),
              second >= 64, second <= 127 else { continue }
        return ip
    }
    return nil
}

private func tsIsValidIPAddress(_ address: String) -> Bool {
    HostPairingAddress.make(network: .tailscale, localIPv4: nil,
                            tailscaleIPv4: address, port: RemoteDesktopConstants.defaultSignalingPort) != nil
}
