import Foundation
import Discovery
import SharedModels
import SharedUtilities
import TransportWebRTC

@MainActor
final class DiscoveryAdvertiserViewModel: ObservableObject {
    @Published private(set) var status: DiscoveryAdvertiserStatus = .stopped
    @Published private(set) var errorMessage: String?

    private let hostIdentity: HostIdentity
    private let advertiser: any HostDiscoveryAdvertiserProtocol
    private let productMode: HostProductMode
    private let secureTLSPortProvider: () -> UInt16?
    private let keyAgreementPublicKeyProvider: () -> Data?
    private var eventsTask: Task<Void, Never>?
    private var tailscaleHostname: String?
    private var tailscaleIP: String?
    /// Cached "Wake for network access" state, advertised so clients can warn before a doomed wake.
    private var wakeSupported: Bool?
    private var isRefreshingWakeReadiness = false
    /// Whether the active network interface is Wi-Fi only (no wired Ethernet). `nil` until the first
    /// path update. Combined with the Mac's architecture to advertise `magicWakeCapable`.
    private var activeInterfaceIsWiFiOnly: Bool?

    /// True on Apple-Silicon Macs. A magic packet can't wake these over Wi-Fi (only a Sleep Proxy
    /// can), so the client needs to know to steer the user elsewhere. Detected via sysctl so it's
    /// correct regardless of process architecture (e.g. under Rosetta).
    private static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }()

    /// Whether a Wake-on-LAN magic packet can wake this Mac: yes unless it's Apple Silicon on Wi-Fi
    /// with no wired path. `nil` until we know the active interface (client falls back to its own guidance).
    private var magicWakeCapable: Bool? {
        guard let wiFiOnly = activeInterfaceIsWiFiOnly else { return nil }
        return !(Self.isAppleSilicon && wiFiOnly)
    }

    init(
        hostIdentity: HostIdentity,
        advertiser: any HostDiscoveryAdvertiserProtocol,
        productMode: HostProductMode = .full,
        secureTLSPortProvider: @escaping () -> UInt16? = { nil },
        keyAgreementPublicKeyProvider: @escaping () -> Data? = { nil }
    ) {
        self.hostIdentity = hostIdentity
        self.advertiser = advertiser
        self.productMode = productMode
        self.secureTLSPortProvider = secureTLSPortProvider
        self.keyAgreementPublicKeyProvider = keyAgreementPublicKeyProvider
    }

    /// Update the Tailscale identity broadcast in the mDNS TXT record. Triggers a re-advertise
    /// when the values change so clients on the LAN learn the tailnet address without typing.
    /// Pass `nil` for both to clear (e.g. user signed out of Tailscale).
    func updateTailscaleIdentity(hostname: String?, ip: String?) async {
        guard hostname != tailscaleHostname || ip != tailscaleIP else { return }
        tailscaleHostname = hostname
        tailscaleIP = ip
        // Only re-advertise if we were already advertising; otherwise the new values are picked up
        // on the next start.
        if isAdvertised { await restart() }
    }

    /// Update the active-interface fact (Wi-Fi-only vs has-wired) used to advertise `magicWakeCapable`.
    /// Re-advertises only when the derived capability changes. Fed from the host's NWPathMonitor.
    func updateActiveInterface(isWiFiOnly: Bool) async {
        guard activeInterfaceIsWiFiOnly != isWiFiOnly else { return }
        let oldCapable = magicWakeCapable
        activeInterfaceIsWiFiOnly = isWiFiOnly
        if isAdvertised, magicWakeCapable != oldCapable { await restart() }
    }

    var serviceName: String {
        LANDiscoveryConstants.serviceType
    }

    var endpointText: String {
        switch status {
        case .advertised(_, let endpoint):
            return endpoint
        default:
            return "Not listening"
        }
    }

    var statusText: String {
        switch status {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .advertised:
            return "Advertised"
        case .failed:
            return "Failed"
        }
    }

    var isAdvertised: Bool {
        if case .advertised = status {
            return true
        }
        return false
    }

    func startIfNeeded() async {
        startObservingEvents()
        await refreshWakeReadiness()
        if case .stopped = status {
            await start()
        }
    }

    /// Re-detects the Mac's "Wake for network access" setting off the main actor and re-advertises
    /// if it changed. `.unknown` (e.g. sandboxed) is advertised as absent rather than a misleading value.
    func refreshWakeReadiness() async {
        guard !isRefreshingWakeReadiness else { return }
        isRefreshingWakeReadiness = true
        defer { isRefreshingWakeReadiness = false }

        let readiness = await Task.detached(priority: .utility) {
            HostWakeReadinessDetector.detect()
        }.value
        let newValue: Bool? = readiness.wakeOnNetwork == .unknown ? nil : readiness.isWakeable
        guard newValue != wakeSupported else { return }
        wakeSupported = newValue
        // Only re-advertise mid-session (e.g. the user just enabled wake). On cold launch this runs
        // before start(), so isAdvertised is false and the value is simply folded into the first advert.
        if isAdvertised { await restart() }
    }

    func start() async {
        errorMessage = nil
        do {
            try await advertiser.startAdvertising(
                serviceType: LANDiscoveryConstants.serviceType,
                domain: LANDiscoveryConstants.defaultDomain,
                metadata: metadata(availability: .available)
            )
        } catch {
            errorMessage = error.localizedDescription
            status = .failed(message: error.localizedDescription)
        }
    }

    func stop() async {
        await advertiser.stopAdvertising()
    }

    func restart() async {
        errorMessage = nil
        do {
            try await advertiser.restartAdvertising(
                serviceType: LANDiscoveryConstants.serviceType,
                domain: LANDiscoveryConstants.defaultDomain,
                metadata: metadata(availability: .available)
            )
        } catch {
            errorMessage = error.localizedDescription
            status = .failed(message: error.localizedDescription)
        }
    }

    /// Ensure LAN advertising is active; if a prior advertise attempt failed,
    /// use restart to recover underlying listener state.
    func ensureAdvertising() async {
        startObservingEvents()
        switch status {
        case .advertised, .starting:
            return
        case .stopped:
            await start()
        case .failed:
            await restart()
        }
    }

    private func startObservingEvents() {
        guard eventsTask == nil else {
            return
        }
        eventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in advertiser.events() {
                switch event {
                case .statusChanged(let newStatus):
                    status = newStatus
                    if case .failed(let message) = newStatus {
                        errorMessage = message
                    }
                case .failed(let message):
                    errorMessage = message
                }
            }
        }
    }

    private func metadata(availability: HostAvailabilityState) -> HostAdvertisementMetadata {
        HostAdvertisementMetadata(
            protocolVersion: RemoteDesktopConstants.protocolVersion,
            hostID: hostIdentity.id,
            displayName: hostIdentity.displayName,
            appVersion: hostIdentity.appVersion,
            signalingPort: RemoteDesktopConstants.defaultSignalingPort,
            capabilities: productMode.advertisedCapabilities,
            supportedCodecs: productMode.supportedCodecs,
            availability: availability,
            publicKeyFingerprint: hostIdentity.publicKeyFingerprint,
            secureTLSPort: secureTLSPortProvider(),
            macAddress: primaryMACAddress(),
            wakeSupported: wakeSupported,
            magicWakeCapable: magicWakeCapable,
            tailscaleHostname: tailscaleHostname,
            tailscaleIP: tailscaleIP,
            keyAgreementPublicKey: keyAgreementPublicKeyProvider()
        )
    }

    /// Returns the MAC address of the primary network interface (en0 preferred, other en* as fallback).
    private func primaryMACAddress() -> String? {
        #if os(macOS)
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        // First pass: which interfaces actually carry an IPv4 address and are up & running. We
        // advertise the MAC of an *active* interface so a down Ethernet port, a parked secondary
        // NIC, or a VPN/Tailscale virtual adapter can't shadow the real LAN interface the client
        // shares a broadcast domain with. (Wake-on-LAN is meaningless for an idle interface.)
        var activeIPv4Interfaces: Set<String> = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = ptr.pointee
            let flags = Int32(entry.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = entry.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            activeIPv4Interfaces.insert(String(cString: entry.ifa_name))
        }

        var firstValid: String?
        var firstActive: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en"), let addr = ptr.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_LINK) else { continue }

            let sdl = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_dl.self).pointee
            guard sdl.sdl_alen == 6 else { continue }

            let offset = Int(sdl.sdl_nlen)
            let macBytes: [UInt8] = withUnsafeBytes(of: sdl.sdl_data) { raw in
                (0..<6).map { raw.load(fromByteOffset: offset + $0, as: UInt8.self) }
            }
            // Skip all-zero and multicast/locally-administered MACs
            guard macBytes.contains(where: { $0 != 0 }), macBytes[0] & 0x01 == 0 else { continue }

            let mac = macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            let isActive = activeIPv4Interfaces.contains(name)
            // The built-in NIC (en0) carrying live traffic is the best answer.
            if name == "en0", isActive { return mac }
            if isActive, firstActive == nil { firstActive = mac }
            if firstValid == nil { firstValid = mac }
        }
        // Prefer any active interface's MAC; only fall back to a present-but-idle NIC if nothing is active.
        return firstActive ?? firstValid
        #else
        return nil
        #endif
    }
}
