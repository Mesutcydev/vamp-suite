import CryptoKit
import Foundation
import SharedModels
import SharedUtilities
import dnssd
import os

private let discoveryLog = Logger(subsystem: "com.remotedesktop", category: "Discovery")

// MARK: - DNS-SD helpers
//
// Discovery is driven entirely by the low-level DNS-SD API (`DNSServiceRegister` /
// `DNSServiceBrowse` / `DNSServiceResolve` / `DNSServiceGetAddrInfo`) bound to a GCD
// dispatch queue via `DNSServiceSetDispatchQueue`. This replaces the legacy
// `NSNetService` / `NetServiceBrowser` API, which is CFRunLoop-based: scheduled on the
// main run loop its socket callback ran `DNSServiceProcessResult`'s **blocking**
// `recvfrom` on the main thread, freezing the host UI (the force-quit hang we shipped
// a stop-gap for). Driving DNS-SD on a dispatch queue keeps that read off the main
// thread with no run loop at all.
//
// Resolution uses `DNSServiceResolve` + `DNSServiceGetAddrInfo` rather than
// Network.framework's `NWBrowser`/`NWConnection`: an `NWConnection` only exposes the
// resolved `host:port` once it reaches `.ready`, i.e. after a real TCP handshake to the
// host's signaling port. Because the client browses *while sessions are live*, that
// would trip the host's connection rate-limiter and replace its active
// `serverConnection`, kicking the live session. DNS-SD resolve performs no TCP connect.

/// Parse a DNS-SD TXT record blob (as delivered to resolve callbacks) into `[key: value]`.
private func parseTXTRecord(length: UInt16, bytes: UnsafeRawPointer?) -> [String: Data] {
    guard let bytes, length > 0 else { return [:] }
    var result: [String: Data] = [:]
    let count = TXTRecordGetCount(length, bytes)
    var index: UInt16 = 0
    while index < count {
        var keyBuffer = [CChar](repeating: 0, count: 256) // TXT keys are <= 255 bytes
        var valueLen: UInt8 = 0
        var valuePtr: UnsafeRawPointer?
        let err = TXTRecordGetItemAtIndex(
            length,
            bytes,
            index,
            UInt16(keyBuffer.count),
            &keyBuffer,
            &valueLen,
            &valuePtr
        )
        index += 1
        guard err == DNSServiceErrorType(kDNSServiceErr_NoError) else { continue }
        let key = String(cString: keyBuffer)
        if let valuePtr, valueLen > 0 {
            result[key] = Data(bytes: valuePtr, count: Int(valueLen))
        } else {
            result[key] = Data()
        }
    }
    return result
}

/// Encode a `[key: value]` map into a DNS-SD TXT record blob for `DNSServiceRegister`.
private func encodeTXTRecord(_ txt: [String: Data]) -> Data {
    var record = TXTRecordRef()
    TXTRecordCreate(&record, 0, nil)
    defer { TXTRecordDeallocate(&record) }
    for (key, value) in txt {
        let size = UInt8(min(value.count, 255))
        value.withUnsafeBytes { raw in
            _ = TXTRecordSetValue(&record, key, size, raw.baseAddress)
        }
    }
    let len = TXTRecordGetLength(&record)
    guard len > 0, let ptr = TXTRecordGetBytesPtr(&record) else { return Data() }
    return Data(bytes: ptr, count: Int(len))
}

/// Convert a resolved `sockaddr` into a numeric IP string, skipping loopback.
/// Mirrors the previous `NetService.addresses` handling (numeric host, no `::1`/`127.0.0.1`).
private func numericAddress(from sockaddrPtr: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
    let family = Int32(sockaddrPtr.pointee.sa_family)
    guard family == AF_INET || family == AF_INET6 else { return nil }
    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let result = getnameinfo(
        sockaddrPtr,
        length,
        &hostBuffer,
        socklen_t(hostBuffer.count),
        nil,
        0,
        NI_NUMERICHOST
    )
    guard result == 0 else { return nil }
    let candidate = String(cString: hostBuffer)
    if candidate.isEmpty || candidate == "::1" || candidate == "127.0.0.1" {
        return nil
    }
    return candidate
}

func resolvedHostMetadata(
    from txtRecord: [String: Data]?,
    serviceName: String,
    port: Int32,
    serviceKey: String
) -> (metadata: HostAdvertisementMetadata, usedFallback: Bool) {
    if let txtRecord, !txtRecord.isEmpty {
        do {
            return (try HostAdvertisementMetadata(txtRecord: txtRecord), false)
        } catch {
            discoveryLog.error("Bonjour TXT parse failed for \(serviceName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    } else {
        discoveryLog.info("Bonjour service resolved without TXT record for \(serviceName, privacy: .public)")
    }

    return (
        HostAdvertisementMetadata(
            protocolVersion: RemoteDesktopConstants.protocolVersion,
            hostID: fallbackHostID(serviceKey: serviceKey),
            displayName: serviceName,
            appVersion: "unknown",
            signalingPort: UInt16(max(port, 0)),
            capabilities: HostCapabilityFlags(stableNames: []),
            supportedCodecs: ["h264"],
            availability: .available
        ),
        true
    )
}

private func fallbackHostID(serviceKey: String) -> UUID {
    let digest = SHA256.hash(data: Data(serviceKey.utf8))
    let bytes = Array(digest.prefix(16))
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

public enum DiscoveryAdvertiserStatus: Hashable, Sendable {
    case stopped
    case starting(serviceName: String)
    case advertised(serviceName: String, endpoint: String)
    case failed(message: String)
}

public enum DiscoveryAdvertiserEvent: Hashable, Sendable {
    case statusChanged(DiscoveryAdvertiserStatus)
    case failed(String)
}

public protocol HostDiscoveryAdvertiserProtocol: BonjourHostAdvertising {
    func restartAdvertising(
        serviceType: String,
        domain: String,
        metadata: HostAdvertisementMetadata
    ) async throws

    func currentStatus() async -> DiscoveryAdvertiserStatus
    func events() -> AsyncStream<DiscoveryAdvertiserEvent>
}

// MARK: - Advertiser

/// Advertises the host's `_screenharbor._tcp` service over Bonjour using `DNSServiceRegister`
/// driven by a dispatch queue. Name collisions are resolved by mDNSResponder's automatic
/// rename; the final registered name is reported back via the registration callback.
public final class BonjourHostDiscoveryAdvertiser: HostDiscoveryAdvertiserProtocol, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.remotedesktop.discovery.advertiser")

    private let lock = NSLock()
    private var status: DiscoveryAdvertiserStatus = .stopped
    private var continuations: [UUID: AsyncStream<DiscoveryAdvertiserEvent>.Continuation] = [:]

    // Touched only on `queue`.
    private var registerRef: DNSServiceRef?
    private var registerContext: UnsafeMutableRawPointer?

    /// Carries a weak advertiser reference (and the advertised port for building the
    /// endpoint string) into the C registration callback. Weak so a dropped advertiser
    /// can still deinit even if `stopAdvertising()` was never called.
    private final class RegistrationBox: @unchecked Sendable {
        weak var advertiser: BonjourHostDiscoveryAdvertiser?
        let port: UInt16
        init(advertiser: BonjourHostDiscoveryAdvertiser, port: UInt16) {
            self.advertiser = advertiser
            self.port = port
        }
    }

    public init() {}

    deinit {
        let ref = registerRef
        let context = registerContext
        registerRef = nil
        registerContext = nil
        if ref != nil || context != nil {
            Self.queue.async {
                if let ref { DNSServiceRefDeallocate(ref) }
                if let context { Unmanaged<RegistrationBox>.fromOpaque(context).release() }
            }
        }
    }

    public func startAdvertising(
        serviceType: String = LANDiscoveryConstants.serviceType,
        domain: String = LANDiscoveryConstants.defaultDomain,
        metadata: HostAdvertisementMetadata
    ) async throws {
        discoveryLog.info("Bonjour advertiser starting")
        updateStatus(.starting(serviceName: metadata.displayName))
        Self.queue.async { [weak self] in
            self?.registerOnQueue(serviceType: serviceType, domain: domain, metadata: metadata)
        }
    }

    public func stopAdvertising() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Self.queue.async { [weak self] in
                self?.teardownOnQueue()
                continuation.resume()
            }
        }
        updateStatus(.stopped)
    }

    public func restartAdvertising(
        serviceType: String = LANDiscoveryConstants.serviceType,
        domain: String = LANDiscoveryConstants.defaultDomain,
        metadata: HostAdvertisementMetadata
    ) async throws {
        await stopAdvertising()
        try await startAdvertising(serviceType: serviceType, domain: domain, metadata: metadata)
    }

    public func currentStatus() async -> DiscoveryAdvertiserStatus {
        withLock { status }
    }

    public func events() -> AsyncStream<DiscoveryAdvertiserEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let currentStatus = status
            lock.unlock()
            continuation.yield(.statusChanged(currentStatus))
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    // MARK: Queue-confined registration

    private func registerOnQueue(serviceType: String, domain: String, metadata: HostAdvertisementMetadata) {
        teardownOnQueue()

        let box = RegistrationBox(advertiser: self, port: metadata.signalingPort)
        let context = Unmanaged.passRetained(box).toOpaque()
        let txtData = encodeTXTRecord(metadata.txtRecord)

        var ref: DNSServiceRef?
        let error = txtData.withUnsafeBytes { raw -> DNSServiceErrorType in
            DNSServiceRegister(
                &ref,
                0,                                  // flags: allow automatic rename on conflict
                0,                                  // interfaceIndex: any
                metadata.displayName,               // service instance name
                serviceType,
                domain,
                nil,                                // host: use the default
                metadata.signalingPort.bigEndian,   // port in network byte order
                UInt16(txtData.count),
                raw.baseAddress,
                { _, _, errorCode, name, regtype, domain, context in
                    guard let context else { return }
                    let box = Unmanaged<RegistrationBox>.fromOpaque(context).takeUnretainedValue()
                    guard let advertiser = box.advertiser else { return }
                    if errorCode == DNSServiceErrorType(kDNSServiceErr_NoError) {
                        let registeredName = name.map { String(cString: $0) } ?? ""
                        let type = regtype.map { String(cString: $0) } ?? ""
                        let dom = domain.map { String(cString: $0) } ?? ""
                        let endpoint = "\(registeredName).\(type)\(dom):\(box.port)"
                        discoveryLog.info("Bonjour advertiser published")
                        advertiser.updateStatus(.advertised(serviceName: registeredName, endpoint: endpoint))
                    } else {
                        let message = "Bonjour publish failed (code \(errorCode))"
                        discoveryLog.error("\(message, privacy: .public)")
                        advertiser.updateStatus(.failed(message: message))
                        advertiser.yield(.failed(message))
                    }
                },
                context
            )
        }

        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            Unmanaged<RegistrationBox>.fromOpaque(context).release()
            let message = "Bonjour publish failed to start (code \(error))"
            discoveryLog.error("\(message, privacy: .public)")
            updateStatus(.failed(message: message))
            yield(.failed(message))
            return
        }

        registerRef = ref
        registerContext = context
        DNSServiceSetDispatchQueue(ref, Self.queue)
    }

    private func teardownOnQueue() {
        if let registerRef {
            DNSServiceRefDeallocate(registerRef)
            self.registerRef = nil
        }
        if let registerContext {
            Unmanaged<RegistrationBox>.fromOpaque(registerContext).release()
            self.registerContext = nil
        }
    }

    // MARK: Status plumbing

    private func updateStatus(_ newStatus: DiscoveryAdvertiserStatus) {
        lock.lock()
        status = newStatus
        let continuations = Array(continuations.values)
        lock.unlock()
        continuations.forEach { $0.yield(.statusChanged(newStatus)) }
    }

    private func yield(_ event: DiscoveryAdvertiserEvent) {
        lock.lock()
        let continuations = Array(continuations.values)
        lock.unlock()
        continuations.forEach { $0.yield(event) }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Browser

/// Browses for `_screenharbor._tcp` hosts using `DNSServiceBrowse`, resolving each found
/// service with `DNSServiceResolve` + `DNSServiceGetAddrInfo` to produce a numeric
/// `ResolvedHostEndpoint`. All DNS-SD refs are driven on a single serial dispatch queue;
/// callbacks therefore run on that queue and mutate the per-service state there.
public final class BonjourHostDiscoveryBrowser:
    BonjourDiscoveryBrowsing,
    DiscoveryServiceProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.remotedesktop.discovery.browser")
    /// Time budget for a single service to go from discovered → resolved + addressed.
    private let resolveTimeout: TimeInterval = 5

    private var serviceType = LANDiscoveryConstants.serviceType
    private var domain = LANDiscoveryConstants.defaultDomain

    // Touched only on `queue`, except where guarded by `lock` for cross-thread readers.
    private var browseRef: DNSServiceRef?
    private var browseContext: UnsafeMutableRawPointer?
    private var resolveOps: [String: ResolveOp] = [:]

    // Guarded by `lock` (read from MainActor via resolvedHostEndpoints()/events()).
    private var hostIDByServiceKey: [String: UUID] = [:]
    private var endpointsByHostID: [UUID: ResolvedHostEndpoint] = [:]
    private var continuations: [UUID: AsyncStream<BonjourDiscoveryEvent>.Continuation] = [:]

    /// Carries a weak browser reference into the long-lived browse callback. Weak so a
    /// dropped browser can deinit even if `stopBrowsing()` was never called.
    private final class BrowseBox: @unchecked Sendable {
        weak var browser: BonjourHostDiscoveryBrowser?
        init(_ browser: BonjourHostDiscoveryBrowser) { self.browser = browser }
    }

    /// Per-service resolution state. Owned by `resolveOps`; DNS-SD contexts reference it
    /// unretained, so its refs are always deallocated before it leaves the dictionary
    /// (on the same serial queue), and teardown captures it strongly to bridge the gap.
    private final class ResolveOp: @unchecked Sendable {
        let name: String
        let type: String
        let domain: String
        let interfaceIndex: UInt32
        weak var browser: BonjourHostDiscoveryBrowser?
        var resolveRef: DNSServiceRef?
        var addrRef: DNSServiceRef?
        var port: UInt16?
        var txt: [String: Data]?
        var target: String?
        /// First IPv6 literal seen, used only if no IPv4 address arrives (IPv4 is preferred,
        /// matching the old NetService impl which returned `addresses` IPv4-first).
        var fallbackIP: String?
        var completed = false

        var key: String { "\(name)|\(type)|\(domain)" }

        init(name: String, type: String, domain: String, interfaceIndex: UInt32, browser: BonjourHostDiscoveryBrowser) {
            self.name = name
            self.type = type
            self.domain = domain
            self.interfaceIndex = interfaceIndex
            self.browser = browser
        }

        func deallocateRefs() {
            if let resolveRef {
                DNSServiceRefDeallocate(resolveRef)
                self.resolveRef = nil
            }
            if let addrRef {
                DNSServiceRefDeallocate(addrRef)
                self.addrRef = nil
            }
        }
    }

    public init() {}

    deinit {
        let ref = browseRef
        let context = browseContext
        let ops = Array(resolveOps.values)
        browseRef = nil
        browseContext = nil
        resolveOps.removeAll()
        queue.async {
            if let ref { DNSServiceRefDeallocate(ref) }
            if let context { Unmanaged<BrowseBox>.fromOpaque(context).release() }
            ops.forEach {
                $0.completed = true
                $0.deallocateRefs()
            }
        }
    }

    // MARK: Browsing lifecycle

    public func startBrowsing() async throws {
        let config = currentBrowseConfig()
        try await startBrowsing(serviceType: config.serviceType, domain: config.domain)
    }

    public func startBrowsing(serviceType: String, domain: String) async throws {
        setBrowseConfig(serviceType: serviceType, domain: domain)
        discoveryLog.info("Bonjour browser starting")
        queue.async { [weak self] in
            self?.startBrowseOnQueue(serviceType: serviceType, domain: domain)
        }
    }

    private func currentBrowseConfig() -> (serviceType: String, domain: String) {
        lock.lock()
        defer { lock.unlock() }
        return (serviceType, domain)
    }

    private func setBrowseConfig(serviceType: String, domain: String) {
        lock.lock()
        self.serviceType = serviceType
        self.domain = domain
        lock.unlock()
    }

    public func stopBrowsing() async {
        discoveryLog.info("Bonjour browser stopping")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.teardownBrowseOnQueue()
                continuation.resume()
            }
        }
    }

    private func startBrowseOnQueue(serviceType: String, domain: String) {
        teardownBrowseOnQueue()

        let box = BrowseBox(self)
        let context = Unmanaged.passRetained(box).toOpaque()

        var ref: DNSServiceRef?
        let error = DNSServiceBrowse(
            &ref,
            0,
            0, // interfaceIndex: any
            serviceType,
            domain,
            { _, flags, interfaceIndex, errorCode, serviceName, regtype, replyDomain, context in
                guard let context else { return }
                let box = Unmanaged<BrowseBox>.fromOpaque(context).takeUnretainedValue()
                guard let browser = box.browser else { return }
                guard errorCode == DNSServiceErrorType(kDNSServiceErr_NoError),
                      let serviceName, let regtype, let replyDomain else {
                    browser.yield(.failed("Bonjour browse failed (code \(errorCode))"))
                    return
                }
                let name = String(cString: serviceName)
                let type = String(cString: regtype)
                let dom = String(cString: replyDomain)
                if (flags & DNSServiceFlags(kDNSServiceFlagsAdd)) != 0 {
                    browser.handleServiceFound(name: name, type: type, domain: dom, interfaceIndex: interfaceIndex)
                } else {
                    browser.handleServiceRemoved(name: name, type: type, domain: dom)
                }
            },
            context
        )

        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            Unmanaged<BrowseBox>.fromOpaque(context).release()
            discoveryLog.error("Bonjour browse failed to start (code \(error))")
            yield(.failed("Bonjour browse failed to start (code \(error))"))
            return
        }

        browseRef = ref
        browseContext = context
        DNSServiceSetDispatchQueue(ref, queue)
    }

    private func teardownBrowseOnQueue() {
        if let browseRef {
            DNSServiceRefDeallocate(browseRef)
            self.browseRef = nil
        }
        if let browseContext {
            Unmanaged<BrowseBox>.fromOpaque(browseContext).release()
            self.browseContext = nil
        }
        let ops = resolveOps
        lock.lock()
        resolveOps.removeAll()
        lock.unlock()
        // `completed` first so any still-queued resolve-continuation bails instead of starting
        // a GetAddrInfo on an op we're about to free; `ops` keeps them alive across the loop.
        ops.values.forEach {
            $0.completed = true
            $0.deallocateRefs()
        }
    }

    // MARK: Found / removed (on queue)

    private func handleServiceFound(name: String, type: String, domain: String, interfaceIndex: UInt32) {
        let key = "\(name)|\(type)|\(domain)"
        discoveryLog.info("Bonjour browser found service")
        lock.lock()
        let existing = resolveOps[key]
        lock.unlock()
        // Retire any prior in-flight op for this key (a duplicate Add — e.g. the same host
        // seen on a second interface, since the key omits the interface index). Marking it
        // `completed` first makes its still-queued resolve-continuation and timeout bail
        // before they can start a GetAddrInfo on the evicted op (whose only strong holder is
        // that deferred block); `teardown` then frees its refs while keeping it alive across
        // deallocation. Doing only `deallocateRefs()` here would orphan a later addrRef and
        // free the op under a live, unretained DNS-SD context (use-after-free + leak).
        if let existing {
            existing.completed = true
            teardown(existing)
        }

        let op = ResolveOp(name: name, type: type, domain: domain, interfaceIndex: interfaceIndex, browser: self)
        lock.lock()
        resolveOps[key] = op
        lock.unlock()
        startResolve(op)

        queue.asyncAfter(deadline: .now() + resolveTimeout) { [weak self, weak op] in
            guard let self, let op, !op.completed else { return }
            op.completed = true
            // If the service resolved but addressing didn't finish in time, the host is still
            // reachable by its IPv6 literal or Bonjour hostname — emit it rather than dropping.
            if let host = op.fallbackIP ?? op.target {
                self.finalize(op: op, hostname: host)
            } else {
                discoveryLog.info("Bonjour resolve timed out")
            }
            self.teardown(op)
        }
    }

    private func handleServiceRemoved(name: String, type: String, domain: String) {
        let key = "\(name)|\(type)|\(domain)"
        discoveryLog.info("Bonjour browser removed service")
        lock.lock()
        let op = resolveOps[key]
        let hostID = hostIDByServiceKey[key]
        hostIDByServiceKey[key] = nil
        if let hostID { endpointsByHostID[hostID] = nil }
        lock.unlock()
        // Mark `completed` so an in-flight resolve/address pipeline for this op can't
        // re-emit a phantom .found (re-inserting the just-removed host) after this .removed.
        // `teardown` frees the op's refs and drops it from resolveOps while keeping it alive
        // across deallocation.
        if let op {
            op.completed = true
            teardown(op)
        }
        if let hostID { yield(.removed(hostID)) }
    }

    // MARK: Resolve → address (on queue)

    private func startResolve(_ op: ResolveOp) {
        let context = Unmanaged.passUnretained(op).toOpaque()
        var ref: DNSServiceRef?
        let error = DNSServiceResolve(
            &ref,
            0,
            op.interfaceIndex,
            op.name,
            op.type,
            op.domain,
            { _, _, interfaceIndex, errorCode, _, hosttarget, port, txtLen, txtRecord, context in
                guard let context else { return }
                let op = Unmanaged<ResolveOp>.fromOpaque(context).takeUnretainedValue()
                guard let browser = op.browser else { return }
                guard errorCode == DNSServiceErrorType(kDNSServiceErr_NoError), let hosttarget else {
                    return // leave the timeout to clean up
                }
                let target = String(cString: hosttarget)
                let resolvedPort = UInt16(bigEndian: port)
                let txt = parseTXTRecord(length: txtLen, bytes: txtRecord)
                browser.handleResolved(op: op, target: target, port: resolvedPort, txt: txt, interfaceIndex: interfaceIndex)
            },
            context
        )

        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            discoveryLog.error("Bonjour resolve failed to start (code \(error))")
            teardown(op)
            return
        }
        op.resolveRef = ref
        DNSServiceSetDispatchQueue(ref, queue)
    }

    private func handleResolved(op: ResolveOp, target: String, port: UInt16, txt: [String: Data], interfaceIndex: UInt32) {
        // DNSServiceResolve can fire more than once; only act on the first result so we
        // never start (and leak) a second GetAddrInfo query.
        guard !op.completed, op.target == nil else { return }
        op.target = target
        op.port = port
        op.txt = txt
        // Defer so we never deallocate the resolve ref from inside its own callback.
        queue.async { [self] in
            if let resolveRef = op.resolveRef {
                DNSServiceRefDeallocate(resolveRef)
                op.resolveRef = nil
            }
            guard !op.completed else { return }
            startAddrInfo(op, target: target, interfaceIndex: interfaceIndex)
        }
    }

    private func startAddrInfo(_ op: ResolveOp, target: String, interfaceIndex: UInt32) {
        let context = Unmanaged.passUnretained(op).toOpaque()
        var ref: DNSServiceRef?
        let proto = DNSServiceProtocol(kDNSServiceProtocol_IPv4) | DNSServiceProtocol(kDNSServiceProtocol_IPv6)
        let error = DNSServiceGetAddrInfo(
            &ref,
            DNSServiceFlags(kDNSServiceFlagsTimeout),
            interfaceIndex,
            proto,
            target,
            { _, flags, _, errorCode, _, address, _, context in
                guard let context else { return }
                let op = Unmanaged<ResolveOp>.fromOpaque(context).takeUnretainedValue()
                guard let browser = op.browser else { return }
                var ip: String?
                var isIPv4 = false
                if errorCode == DNSServiceErrorType(kDNSServiceErr_NoError), let address {
                    ip = numericAddress(from: address, length: socklen_t(address.pointee.sa_len))
                    isIPv4 = Int32(address.pointee.sa_family) == AF_INET
                }
                let moreComing = (flags & DNSServiceFlags(kDNSServiceFlagsMoreComing)) != 0
                browser.handleAddress(op: op, ip: ip, isIPv4: isIPv4, moreComing: moreComing)
            },
            context
        )

        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            // Resolution still produced a hostname; fall back to it so the host is reachable.
            op.completed = true
            finalize(op: op, hostname: target)
            teardown(op)
            return
        }
        op.addrRef = ref
        DNSServiceSetDispatchQueue(ref, queue)
    }

    private func handleAddress(op: ResolveOp, ip: String?, isIPv4: Bool, moreComing: Bool) {
        guard !op.completed else { return }
        if let ip, isIPv4 {
            // IPv4 is preferred (matches the old NetService impl, which returned `addresses`
            // IPv4-first); take it as soon as it arrives.
            op.completed = true
            finalize(op: op, hostname: ip)
            teardown(op)
            return
        }
        if let ip, op.fallbackIP == nil {
            // Stash the first IPv6 literal; only used if no IPv4 address arrives.
            op.fallbackIP = ip
        }
        if !moreComing {
            op.completed = true
            finalize(op: op, hostname: op.fallbackIP ?? op.target ?? op.name)
            teardown(op)
        }
    }

    private func finalize(op: ResolveOp, hostname: String) {
        let key = op.key
        let port = op.port ?? 0
        let txt = (op.txt?.isEmpty == false) ? op.txt : nil
        let result = resolvedHostMetadata(
            from: txt,
            serviceName: op.name,
            port: Int32(port),
            serviceKey: key
        )
        let metadata = result.metadata
        let endpoint = ResolvedHostEndpoint(
            hostname: hostname,
            port: op.port ?? metadata.signalingPort,
            metadata: metadata,
            bonjourServiceName: op.name
        )

        lock.lock()
        let previousHostID = hostIDByServiceKey[key]
        if let previousHostID, previousHostID != metadata.hostID {
            endpointsByHostID[previousHostID] = nil
        }
        let existed = endpointsByHostID[metadata.hostID] != nil
        endpointsByHostID[metadata.hostID] = endpoint
        hostIDByServiceKey[key] = metadata.hostID
        lock.unlock()

        if result.usedFallback {
            discoveryLog.info("Bonjour resolved host using fallback metadata for \(op.name, privacy: .public)")
        } else {
            let capsText = metadata.capabilities.stableNames.joined(separator: ",")
            discoveryLog.info("Bonjour resolved host metadata with capabilities: \(capsText, privacy: .private)")
        }
        if let previousHostID, previousHostID != metadata.hostID {
            yield(.removed(previousHostID))
        }
        yield(existed ? .updated(endpoint) : .found(endpoint))
    }

    /// Deallocate an op's refs and drop it from the dictionary. Captures `op` strongly so
    /// it outlives ref deallocation even after it leaves `resolveOps` (no use-after-free
    /// from a late callback referencing the unretained context).
    private func teardown(_ op: ResolveOp) {
        queue.async { [self] in
            op.deallocateRefs()
            lock.lock()
            if resolveOps[op.key] === op {
                resolveOps[op.key] = nil
            }
            lock.unlock()
        }
    }

    // MARK: Snapshots / events

    public func discoveredHosts() async -> [HostIdentity] {
        snapshotResolvedHostEndpoints().map { endpoint in
            HostIdentity(
                id: endpoint.metadata.hostID,
                displayName: endpoint.metadata.displayName,
                modelName: "Mac",
                osVersion: "Unknown",
                appVersion: endpoint.metadata.appVersion,
                publicKeyFingerprint: endpoint.metadata.publicKeyFingerprint ?? "unpaired"
            )
        }
    }

    public func resolvedHosts() async -> [ResolvedHostEndpoint] {
        snapshotResolvedHostEndpoints()
    }

    public func resolvedHostEndpoints() async -> [ResolvedHostEndpoint] {
        snapshotResolvedHostEndpoints()
    }

    private func snapshotResolvedHostEndpoints() -> [ResolvedHostEndpoint] {
        lock.lock()
        let endpoints = Array(endpointsByHostID.values)
            .sorted { $0.metadata.displayName.localizedCaseInsensitiveCompare($1.metadata.displayName) == .orderedAscending }
        lock.unlock()
        return endpoints
    }

    public func events() -> AsyncStream<BonjourDiscoveryEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let endpoints = Array(endpointsByHostID.values)
            lock.unlock()
            endpoints.forEach { continuation.yield(.found($0)) }
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    private func yield(_ event: BonjourDiscoveryEvent) {
        lock.lock()
        let continuations = Array(continuations.values)
        lock.unlock()
        continuations.forEach { $0.yield(event) }
    }
}
