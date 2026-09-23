import Foundation
import Discovery
import SharedModels
import SharedUtilities

enum HostsListViewState: Equatable {
    case loading
    case empty
    case available
    case unavailable
    case localNetworkIssue(String)
}

struct DiscoveredHostRow: Identifiable, Hashable {
    var id: UUID { endpoint.id }
    var endpoint: ResolvedHostEndpoint
    var lastSeen: Date
    var isAvailable: Bool
    var isSaved: Bool

    var title: String {
        endpoint.metadata.displayName
    }

    var subtitle: String {
        "\(endpoint.hostname):\(endpoint.port)"
    }

    /// Terminal-only hosts advertise the terminal capabilities without a display
    /// stream. Remote Control can discover them, but it must not present them as
    /// ordinary remote-control targets.
    var isTerminalOnlyHost: Bool {
        endpoint.metadata.capabilities.isTerminalOnlyHost
    }
}

/// Lightweight record persisted to UserDefaults for manually-entered hosts.
struct SavedHost: Codable, Hashable, Identifiable {
    var id: UUID
    var hostname: String
    var port: UInt16
    var displayName: String
    var lastConnected: Date
    var macAddress: String?
    var bonjourServiceName: String?
    /// Host's advertised "Wake for network access" state, so we can warn before a doomed wake even
    /// after the host has gone offline. nil = unknown.
    var wakeSupported: Bool? = nil
    /// Whether a magic packet can wake this Mac (false for Apple-Silicon on Wi-Fi). Persisted so the
    /// wake button can warn before a doomed attempt even after the host goes offline. nil = unknown.
    var magicWakeCapable: Bool? = nil
    var publicKeyFingerprint: String?
    /// Host's Tailscale MagicDNS name / 100.x address, captured when it was last seen on
    /// the LAN. Persisted so we can still reach the host over Tailscale after an app
    /// restart while away from the home network (where Bonjour can't rediscover it).
    var tailscaleHostname: String?
    var tailscaleIP: String?
    /// TLS signaling port advertised by the host (9473). Persisted so a typed
    /// Tailscale/MagicDNS address can reuse TLS after the first Bonjour pair.
    var secureTLSPort: UInt16? = nil
    /// Host key-agreement public key used to seal the session token.
    var keyAgreementPublicKey: Data? = nil
}

@MainActor
final class HostsListViewModel: ObservableObject {
    @Published private(set) var state: HostsListViewState = .loading
    @Published private(set) var hosts: [DiscoveredHostRow] = []
    @Published var selectedHostID: UUID?
    @Published var connectionMessage: String?

    private let browser: any BonjourDiscoveryBrowsing
    private var eventsTask: Task<Void, Never>?
    private var hasStarted = false
    private var delayedRefreshTask: Task<Void, Never>?
    private var startupRetryTask: Task<Void, Never>?
    private var permissionRecoveryTask: Task<Void, Never>?
    private var permissionRecoveryAttempts = 0
    private var bonjourConfirmedIDs: Set<UUID> = []

    private static let savedHostsKey = "com.remotedesktop.savedHosts"

    init(browser: any BonjourDiscoveryBrowsing) {
        self.browser = browser
        CrashSafeStartupDiagnostics.mark("hosts.init.begin")
        loadSavedHosts()
        CrashSafeStartupDiagnostics.mark("hosts.init.end", details: "saved=\(hosts.count)")
    }

    func start() async {
        guard !hasStarted else {
            return
        }
        CrashSafeStartupDiagnostics.mark("hosts.start.begin")
        hasStarted = true
        startListeningForEvents()
        await refresh()
        scheduleStartupRetries()
        CrashSafeStartupDiagnostics.mark("hosts.start.end", details: "state=\(String(describing: state))")
    }

    func refresh() async {
        CrashSafeStartupDiagnostics.mark("hosts.refresh.begin")
        state = .loading
        bonjourConfirmedIDs = []
        do {
            await browser.stopBrowsing()
            try await browser.startBrowsing(
                serviceType: LANDiscoveryConstants.serviceType,
                domain: LANDiscoveryConstants.defaultDomain
            )
            // Give Bonjour a moment to discover nearby services before
            // checking resolved hosts. The async event stream will also
            // deliver updates, but reading immediately always returns empty.
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 s
            let endpoints = await browser.resolvedHosts()
            merge(endpoints: endpoints)
            updateState()
            CrashSafeStartupDiagnostics.mark("hosts.refresh.loaded", details: "resolved=\(endpoints.count) state=\(String(describing: state))")
            if hosts.contains(where: \.isAvailable) {
                permissionRecoveryAttempts = 0
            }

            // Schedule a second check after another 3 seconds in case
            // the initial resolve was still in progress.
            scheduleDelayedRefresh()
        } catch {
            CrashSafeStartupDiagnostics.error("hosts.refresh", error: error)
            state = .localNetworkIssue(localNetworkMessage(for: error))
            schedulePermissionRecoveryRefresh()
        }
    }

    private func scheduleDelayedRefresh() {
        delayedRefreshTask?.cancel()
        delayedRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 s
            guard !Task.isCancelled, let self else { return }
            let endpoints = await browser.resolvedHosts()
            merge(endpoints: endpoints)
            markUnconfirmedSavedHostsUnavailable()
            updateState()
        }
    }

    private func scheduleStartupRetries() {
        startupRetryTask?.cancel()
        startupRetryTask = Task { [weak self] in
            guard let self else { return }
            let retryDelays: [UInt64] = [2_000_000_000, 5_000_000_000, 10_000_000_000, 15_000_000_000]
            for delay in retryDelays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                if hosts.contains(where: \.isAvailable) {
                    return
                }
                await refresh()
            }
        }
    }

    private func schedulePermissionRecoveryRefresh() {
        guard permissionRecoveryAttempts < 15 else { return }
        permissionRecoveryAttempts += 1

        permissionRecoveryTask?.cancel()
        permissionRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 s
            guard !Task.isCancelled, let self else { return }
            if hosts.contains(where: \.isAvailable) {
                permissionRecoveryAttempts = 0
                return
            }
            await refresh()
        }
    }

    func handleSceneBecameActive() async {
        guard hasStarted else { return }
        permissionRecoveryAttempts = 0
        await refresh()
    }

    func connect(to host: DiscoveredHostRow) {
        selectedHostID = host.id
        connectionMessage = nil
    }

    private func startListeningForEvents() {
        guard eventsTask == nil else {
            return
        }
        eventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in browser.events() {
                switch event {
                case .found(let endpoint), .updated(let endpoint):
                    upsert(endpoint: endpoint, isAvailable: endpoint.metadata.availability == .available)
                case .removed(let id):
                    markUnavailable(id: id)
                case .failed(let message):
                    state = .localNetworkIssue(localNetworkMessage(for: message))
                    schedulePermissionRecoveryRefresh()
                }
            }
        }
    }

    private func merge(endpoints: [ResolvedHostEndpoint]) {
        for endpoint in endpoints {
            upsert(endpoint: endpoint, isAvailable: endpoint.metadata.availability == .available)
        }
    }

    private func upsert(endpoint: ResolvedHostEndpoint, isAvailable: Bool, skipTailscaleSibling: Bool = false) {
        bonjourConfirmedIDs.insert(endpoint.id)

        // Collapse a stale entry for the same physical host that advertised under a different
        // hostID (e.g. older builds generated a fresh UUID on every MacHost launch).
        // Prefer the stable key fingerprint, then fall back to MAC address and hostname:port.
        //
        // IMPORTANT: skip this entirely for the Tailscale sibling. The sibling inherits the
        // parent's fingerprint/MAC, so running the collapse here would delete the very LAN row
        // it was spawned from — leaving only the relay address, which can't resolve unless
        // Tailscale is active. The sibling must be purely additive; the LAN/primary upsert path
        // still performs the full stale-collapse.
        var inheritedSaved = false
        if !skipTailscaleSibling {
            let fingerprint = normalizedFingerprint(endpoint.metadata.publicKeyFingerprint)
            let macAddress = normalizedMACAddress(endpoint.metadata.macAddress)
            let staleIndexes = hosts.indices.filter { index in
                staleHost(hosts[index], matches: endpoint, fingerprint: fingerprint, macAddress: macAddress)
            }
            for staleIndex in staleIndexes.sorted(by: >) {
                let stale = hosts[staleIndex]
                inheritedSaved = inheritedSaved || stale.isSaved
                if stale.isSaved {
                    var records = loadSavedHostRecords()
                    records.removeAll { savedRecordMatchesStaleHost($0, stale: stale) }
                    persistSavedHosts(records)
                }
                hosts.remove(at: staleIndex)
                if selectedHostID == stale.id {
                    selectedHostID = endpoint.id
                }
            }
        }

        let existingSaved = hosts.first(where: { $0.id == endpoint.id })?.isSaved ?? false
        let isSaved = existingSaved || inheritedSaved
        let row = DiscoveredHostRow(endpoint: endpoint, lastSeen: Date(), isAvailable: isAvailable, isSaved: isSaved)
        if let index = hosts.firstIndex(where: { $0.id == endpoint.id }) {
            hosts[index] = row
        } else {
            hosts.append(row)
        }
        // Persist a newly-discovered MAC + Bonjour name so the wake button works after the host
        // goes offline. The Bonjour name is what triggers Sleep Proxy wake on M-series Macs.
        if existingSaved {
            refreshSavedWakeFieldsIfNeeded(
                hostID: endpoint.id,
                mac: endpoint.metadata.macAddress,
                bonjourServiceName: endpoint.bonjourServiceName,
                wakeSupported: endpoint.metadata.wakeSupported,
                magicWakeCapable: endpoint.metadata.magicWakeCapable,
                publicKeyFingerprint: endpoint.metadata.publicKeyFingerprint,
                tailscaleHostname: endpoint.metadata.tailscaleHostname,
                tailscaleIP: endpoint.metadata.tailscaleIP,
                secureTLSPort: endpoint.metadata.secureTLSPort,
                keyAgreementPublicKey: endpoint.metadata.keyAgreementPublicKey
            )
        }
        // If we adopted a stale saved entry, re-persist under the new hostID so future launches
        // recognise this row without going through the merge path again.
        if inheritedSaved {
            let saved = SavedHost(
                id: endpoint.id,
                hostname: endpoint.hostname,
                port: endpoint.port,
                displayName: endpoint.metadata.displayName,
                lastConnected: Date(),
                macAddress: endpoint.metadata.macAddress,
                bonjourServiceName: endpoint.bonjourServiceName,
                wakeSupported: endpoint.metadata.wakeSupported,
                magicWakeCapable: endpoint.metadata.magicWakeCapable,
                publicKeyFingerprint: endpoint.metadata.publicKeyFingerprint,
                tailscaleHostname: endpoint.metadata.tailscaleHostname,
                tailscaleIP: endpoint.metadata.tailscaleIP,
                secureTLSPort: endpoint.metadata.secureTLSPort,
                keyAgreementPublicKey: endpoint.metadata.keyAgreementPublicKey
            )
            upsertSavedHostRecord(saved)
        }

        // When the host advertises a Tailscale identity, fold a sibling row pointing at the
        // tailnet address into the list so the user doesn't have to type it manually. Recursing
        // with `skipTailscaleSibling: true` re-uses the existing merge-by-hostname:port logic to
        // collapse any prior manual entry into the auto-discovered sibling.
        if !skipTailscaleSibling, let sibling = makeTailscaleSiblingEndpoint(parent: endpoint) {
            upsert(endpoint: sibling, isAvailable: true, skipTailscaleSibling: true)
        }

        sortHosts()
        updateState()
    }

    private func makeTailscaleSiblingEndpoint(parent: ResolvedHostEndpoint) -> ResolvedHostEndpoint? {
        let candidate = parent.metadata.tailscaleHostname ?? parent.metadata.tailscaleIP
        guard let host = candidate, !host.isEmpty else { return nil }

        var siblingMetadata = parent.metadata
        siblingMetadata.hostID = tailscaleSiblingID(from: parent.metadata.hostID)
        // "unknown" appVersion keeps the sibling out of `markUnconfirmedSavedHostsUnavailable` —
        // the LAN row going dark shouldn't drag the tailnet row down, since we can't probe it
        // without a connection attempt.
        siblingMetadata.appVersion = "unknown"
        // Clear the tailscale fields so this sibling row can never spawn its own sibling.
        siblingMetadata.tailscaleHostname = nil
        siblingMetadata.tailscaleIP = nil

        return ResolvedHostEndpoint(
            hostname: host,
            port: parent.port,
            metadata: siblingMetadata,
            resolvedAt: Date()
        )
    }

    private func tailscaleSiblingID(from hostID: UUID) -> UUID {
        var bytes = withUnsafeBytes(of: hostID.uuid) { Array($0) }
        // Deterministic, distinct-from-parent UUID derived by XORing a fixed 16-byte salt.
        let salt: [UInt8] = [0x54, 0x53, 0x4E, 0x45, 0x54, 0x43, 0x41, 0x4C,
                             0x44, 0x4E, 0x53, 0x53, 0x49, 0x42, 0x4C, 0x47]
        for i in 0..<16 { bytes[i] ^= salt[i] }
        let uuidBytes: uuid_t = (bytes[0], bytes[1], bytes[2], bytes[3],
                                 bytes[4], bytes[5], bytes[6], bytes[7],
                                 bytes[8], bytes[9], bytes[10], bytes[11],
                                 bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: uuidBytes)
    }

    private func refreshSavedWakeFieldsIfNeeded(
        hostID: UUID,
        mac: String?,
        bonjourServiceName: String?,
        wakeSupported: Bool?,
        magicWakeCapable: Bool? = nil,
        publicKeyFingerprint: String?,
        tailscaleHostname: String? = nil,
        tailscaleIP: String? = nil,
        secureTLSPort: UInt16? = nil,
        keyAgreementPublicKey: Data? = nil
    ) {
        var records = loadSavedHostRecords()
        guard let index = records.firstIndex(where: { $0.id == hostID }) else { return }
        var changed = false
        if records[index].macAddress == nil, let mac {
            records[index].macAddress = mac
            changed = true
        }
        // Backfill the tailnet address learned on the LAN so the host stays reachable over
        // Tailscale after a restart away from home (where Bonjour can't rediscover it).
        if records[index].tailscaleHostname == nil, let tailscaleHostname, !tailscaleHostname.isEmpty {
            records[index].tailscaleHostname = tailscaleHostname
            changed = true
        }
        if records[index].tailscaleIP == nil, let tailscaleIP, !tailscaleIP.isEmpty {
            records[index].tailscaleIP = tailscaleIP
            changed = true
        }
        if records[index].bonjourServiceName != bonjourServiceName, let bonjourServiceName {
            records[index].bonjourServiceName = bonjourServiceName
            changed = true
        }
        if records[index].wakeSupported != wakeSupported, let wakeSupported {
            records[index].wakeSupported = wakeSupported
            changed = true
        }
        if records[index].magicWakeCapable != magicWakeCapable, let magicWakeCapable {
            records[index].magicWakeCapable = magicWakeCapable
            changed = true
        }
        if normalizedFingerprint(records[index].publicKeyFingerprint) == nil,
           let publicKeyFingerprint = normalizedFingerprint(publicKeyFingerprint) {
            records[index].publicKeyFingerprint = publicKeyFingerprint
            changed = true
        }
        if records[index].secureTLSPort == nil, let secureTLSPort {
            records[index].secureTLSPort = secureTLSPort
            changed = true
        }
        if records[index].keyAgreementPublicKey == nil, let keyAgreementPublicKey {
            records[index].keyAgreementPublicKey = keyAgreementPublicKey
            changed = true
        }
        if changed {
            persistSavedHosts(records)
        }
    }

    private func markUnconfirmedSavedHostsUnavailable() {
        var changed = false
        for index in hosts.indices {
            // Never mark manually-added hosts (Tailscale/IP) offline via Bonjour logic —
            // they were never discoverable via mDNS. Let connection errors surface naturally.
            guard hosts[index].isSaved,
                  hosts[index].isAvailable,
                  !bonjourConfirmedIDs.contains(hosts[index].id),
                  hosts[index].endpoint.metadata.appVersion != "unknown" else { continue }
            hosts[index].isAvailable = false
            hosts[index].endpoint.metadata.availability = .unavailable
            changed = true
        }
        if changed {
            sortHosts()
            updateState()
        }
    }

    private func markUnavailable(id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else {
            updateState()
            return
        }
        hosts[index].isAvailable = false
        hosts[index].endpoint.metadata.availability = .unavailable
        hosts[index].lastSeen = Date()
        updateState()
    }

    private func sortHosts() {
        hosts.sort {
            if $0.isAvailable != $1.isAvailable {
                return $0.isAvailable && !$1.isAvailable
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func updateState() {
        if hosts.isEmpty {
            state = .empty
        } else if hosts.contains(where: \.isAvailable) {
            state = .available
        } else {
            state = .unavailable
        }
    }

    private func localNetworkMessage(for error: Error) -> String {
        let nsError = error as NSError
        // NetService/NWBrowser-domain errors when Local Network permission is
        // denied surface with code 1 ("no auth") or domain-specific strings.
        // Recognise the common patterns and give the user a concrete next step
        // instead of the generic "discovery is unavailable" wall.
        let description = error.localizedDescription.lowercased()
        if description.contains("permission") ||
            description.contains("denied") ||
            description.contains("not allowed") ||
            description.contains("no auth") ||
            nsError.code == 1 {
            return "Allow Local Network in Settings → Privacy → Local Network so Vamp Terminal can find your Mac."
        }
        if description.contains("offline") || description.contains("not reachable") {
            return "Wi-Fi appears offline. Connect to the same Wi-Fi as your Mac and try again."
        }
        return localNetworkMessage(for: error.localizedDescription)
    }

    private func localNetworkMessage(for message: String) -> String {
        // Generic fallback — try to be actionable rather than blame-the-user.
        "Couldn't find any Macs on this network yet. Make sure Vamp Sync is open on the Mac and both devices are on the same Wi-Fi, or connect by address."
    }

    // MARK: - Manual Connection

    /// Parse an address string like "192.168.1.5", "myhost.example.com:9471",
    /// or "[2001:db8::1]:9471" and add a synthetic host entry so the user can connect to it.
    @discardableResult
    func addManualHost(address: String) -> DiscoveredHostRow? {
        guard let parsedAddress = parseManualAddress(address) else {
            return nil
        }
        let hostname = parsedAddress.hostname
        let port = parsedAddress.port

        // Reuse existing entry for the same hostname:port to avoid duplicates
        if let existing = hosts.first(where: { $0.endpoint.hostname == hostname && $0.endpoint.port == port }) {
            var updated = existing
            updated.isAvailable = true
            updated.lastSeen = Date()
            updated.endpoint.metadata.availability = .available
            if let index = hosts.firstIndex(where: { $0.id == existing.id }) {
                hosts[index] = updated
            }
            sortHosts()
            updateState()
            return updated
        }

        var metadata = HostAdvertisementMetadata(
            protocolVersion: RemoteDesktopConstants.protocolVersion,
            hostID: UUID(),
            displayName: hostname,
            appVersion: "unknown",
            signalingPort: port,
            capabilities: HostCapabilityFlags(stableNames: []),
            supportedCodecs: ["h264"],
            availability: .available
        )
        applyKnownHostIdentity(hostname: hostname, to: &metadata)
        let endpoint = ResolvedHostEndpoint(
            hostname: hostname,
            port: port,
            metadata: metadata,
            resolvedAt: Date()
        )
        return upsertManual(endpoint: endpoint, isAvailable: true)
    }

    // MARK: - Saved Hosts

    func saveHost(_ hostID: UUID) {
        guard let host = hosts.first(where: { $0.id == hostID }) else { return }
        if let index = hosts.firstIndex(where: { $0.id == hostID }) {
            hosts[index].isSaved = true
        }

        let displayName = host.endpoint.metadata.displayName
        let saved = SavedHost(
            id: host.id,
            hostname: host.endpoint.hostname,
            port: host.endpoint.port,
            displayName: displayName,
            lastConnected: Date(),
            macAddress: host.endpoint.metadata.macAddress,
            bonjourServiceName: host.endpoint.bonjourServiceName,
            wakeSupported: host.endpoint.metadata.wakeSupported,
            magicWakeCapable: host.endpoint.metadata.magicWakeCapable,
            publicKeyFingerprint: host.endpoint.metadata.publicKeyFingerprint,
            tailscaleHostname: host.endpoint.metadata.tailscaleHostname,
            tailscaleIP: host.endpoint.metadata.tailscaleIP,
            secureTLSPort: host.endpoint.metadata.secureTLSPort,
            keyAgreementPublicKey: host.endpoint.metadata.keyAgreementPublicKey
        )
        upsertSavedHostRecord(saved)
        sortHosts()
        updateState()
    }

    func renameSavedHost(_ hostID: UUID, to newDisplayName: String) {
        let trimmedName = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        var all = loadSavedHostRecords()
        guard let recordIndex = all.firstIndex(where: { $0.id == hostID }) else { return }
        all[recordIndex].displayName = trimmedName
        all[recordIndex].lastConnected = Date()
        persistSavedHosts(all)

        if let hostIndex = hosts.firstIndex(where: { $0.id == hostID }) {
            hosts[hostIndex].endpoint.metadata.displayName = trimmedName
            hosts[hostIndex].isSaved = true
        }
        sortHosts()
        updateState()
    }

    /// Call after a successful connection to persist the host for future use.
    func markHostConnected(_ hostID: UUID) {
        saveHost(hostID)
    }

    func refreshedEndpoint(matching endpoint: ResolvedHostEndpoint) -> ResolvedHostEndpoint? {
        let fingerprint = normalizedFingerprint(endpoint.metadata.publicKeyFingerprint)
        let macAddress = normalizedMACAddress(endpoint.metadata.macAddress)
        return hosts
            .filter { host in
                host.id == endpoint.id || staleHost(host, matches: endpoint, fingerprint: fingerprint, macAddress: macAddress)
            }
            .sorted { lhs, rhs in
                if lhs.isAvailable != rhs.isAvailable {
                    return lhs.isAvailable && !rhs.isAvailable
                }
                let lhsKnown = lhs.endpoint.metadata.appVersion != "unknown"
                let rhsKnown = rhs.endpoint.metadata.appVersion != "unknown"
                if lhsKnown != rhsKnown {
                    return lhsKnown && !rhsKnown
                }
                return lhs.lastSeen > rhs.lastSeen
            }
            .first?
            .endpoint
    }

    /// Every distinct address we know for the physical host behind `endpoint` — the LAN
    /// row plus any Tailscale relay sibling — ordered best-first for a reconnect sweep:
    /// reachable LAN beats reachable relay beats anything offline. Deduped by hostname:port.
    func candidateEndpoints(matching endpoint: ResolvedHostEndpoint) -> [ResolvedHostEndpoint] {
        let fingerprint = normalizedFingerprint(endpoint.metadata.publicKeyFingerprint)
        let macAddress = normalizedMACAddress(endpoint.metadata.macAddress)

        var rows = hosts.filter { host in
            host.id == endpoint.id
                || staleHost(host, matches: endpoint, fingerprint: fingerprint, macAddress: macAddress)
        }
        // Always include the endpoint we were asked about, even if it isn't in `hosts`.
        if !rows.contains(where: { $0.endpoint.hostname == endpoint.hostname && $0.endpoint.port == endpoint.port }) {
            rows.append(DiscoveredHostRow(endpoint: endpoint, lastSeen: Date(), isAvailable: true, isSaved: false))
        }

        let ordered = rows.sorted { lhs, rhs in
            if lhs.isAvailable != rhs.isAvailable {
                return lhs.isAvailable && !rhs.isAvailable
            }
            let lhsRelay = Self.isRelayEndpoint(lhs)
            let rhsRelay = Self.isRelayEndpoint(rhs)
            if lhsRelay != rhsRelay {
                return !lhsRelay // prefer LAN (non-relay) first
            }
            return lhs.lastSeen > rhs.lastSeen
        }

        var seen = Set<String>()
        var result: [ResolvedHostEndpoint] = []
        for row in ordered {
            let key = "\(row.endpoint.hostname.lowercased()):\(row.endpoint.port)"
            if seen.insert(key).inserted {
                result.append(row.endpoint)
            }
        }
        return result
    }

    /// The fingerprint we previously verified and persisted for the physical Mac behind
    /// `endpoint`, if any. The session coordinator pins host identity against THIS value rather
    /// than whatever the (attacker-influenceable) Bonjour advertisement currently claims — so a
    /// same-LAN impostor re-advertising a trusted Mac's name/IP/MAC is rejected on the key change
    /// instead of being silently trusted and overwriting the stored trust anchor (TOFU).
    func trustedFingerprint(matching endpoint: ResolvedHostEndpoint) -> String? {
        let records = loadSavedHostRecords()
        let endpointFingerprint = normalizedFingerprint(endpoint.metadata.publicKeyFingerprint)
        let mac = normalizedMACAddress(endpoint.metadata.macAddress)
        let match = records.first { record in
            if record.id == endpoint.metadata.hostID { return true }
            if let endpointFingerprint,
               normalizedFingerprint(record.publicKeyFingerprint) == endpointFingerprint { return true }
            if let mac, normalizedMACAddress(record.macAddress) == mac { return true }
            return record.hostname == endpoint.hostname && record.port == endpoint.port
        }
        return match.flatMap { normalizedFingerprint($0.publicKeyFingerprint) }
    }

    @discardableResult
    func recordVerifiedHostIdentity(
        endpoint: ResolvedHostEndpoint,
        hostID: UUID,
        publicKeyFingerprint: String
    ) -> ResolvedHostEndpoint? {
        guard let fingerprint = normalizedFingerprint(publicKeyFingerprint) else {
            return refreshedEndpoint(matching: endpoint)
        }

        var verifiedEndpoint = endpoint
        verifiedEndpoint.metadata.hostID = hostID
        verifiedEndpoint.metadata.publicKeyFingerprint = fingerprint

        let existingFingerprint = normalizedFingerprint(endpoint.metadata.publicKeyFingerprint)
        let macAddress = normalizedMACAddress(endpoint.metadata.macAddress)
        let matchingIndexes = hosts.indices.filter { index in
            let host = hosts[index]
            return host.id == endpoint.id
                || host.id == hostID
                || staleHost(host, matches: endpoint, fingerprint: existingFingerprint, macAddress: macAddress)
                || staleHost(host, matches: verifiedEndpoint, fingerprint: fingerprint, macAddress: macAddress)
        }

        var shouldRemainSaved = false
        for index in matchingIndexes.sorted(by: >) {
            let host = hosts[index]
            shouldRemainSaved = shouldRemainSaved || host.isSaved
            if selectedHostID == host.id {
                selectedHostID = hostID
            }
            hosts.remove(at: index)
        }

        var records = loadSavedHostRecords()
        // This is the SOLE host-persistence entry point. A record is written only here — after
        // the host's signed answer has passed the fingerprint check — so failed / typo'd /
        // unreachable connection attempts (which never verify) are never saved, and every saved
        // record carries the canonical fingerprint. Keying future merges on that fingerprint means
        // a re-discovery of the same Mac always collapses instead of creating a duplicate tile.
        // Preserve any tailnet address we'd previously learned for this host even if this
        // (e.g. LAN) verification didn't carry one, so the relay sibling survives.
        let priorTailscaleHost = records.first { savedHostRecord($0, matches: endpoint) || $0.id == hostID || normalizedFingerprint($0.publicKeyFingerprint) == fingerprint }
        records.removeAll {
            savedHostRecord($0, matches: endpoint)
                || $0.id == hostID
                || normalizedFingerprint($0.publicKeyFingerprint) == fingerprint
        }
        let saved = SavedHost(
            id: hostID,
            hostname: verifiedEndpoint.hostname,
            port: verifiedEndpoint.port,
            displayName: verifiedEndpoint.metadata.displayName,
            lastConnected: Date(),
            macAddress: verifiedEndpoint.metadata.macAddress,
            bonjourServiceName: verifiedEndpoint.bonjourServiceName,
            wakeSupported: verifiedEndpoint.metadata.wakeSupported,
            magicWakeCapable: verifiedEndpoint.metadata.magicWakeCapable,
            publicKeyFingerprint: fingerprint,
            tailscaleHostname: verifiedEndpoint.metadata.tailscaleHostname ?? priorTailscaleHost?.tailscaleHostname,
            tailscaleIP: verifiedEndpoint.metadata.tailscaleIP ?? priorTailscaleHost?.tailscaleIP,
            secureTLSPort: verifiedEndpoint.metadata.secureTLSPort ?? priorTailscaleHost?.secureTLSPort,
            keyAgreementPublicKey: verifiedEndpoint.metadata.keyAgreementPublicKey ?? priorTailscaleHost?.keyAgreementPublicKey
        )
        records.append(saved)
        persistSavedHosts(records)
        shouldRemainSaved = true

        hosts.append(DiscoveredHostRow(
            endpoint: verifiedEndpoint,
            lastSeen: Date(),
            isAvailable: true,
            isSaved: shouldRemainSaved
        ))

        sortHosts()
        updateState()
        return verifiedEndpoint
    }

    func removeSavedHost(_ hostID: UUID) {
        var all = loadSavedHostRecords()
        all.removeAll { $0.id == hostID }
        persistSavedHosts(all)
        // If host is not from Bonjour discovery, remove from list entirely
        if let index = hosts.firstIndex(where: { $0.id == hostID }) {
            hosts[index].isSaved = false
            // Remove manual hosts that are not from discovery
            if !hosts[index].isAvailable || hosts[index].endpoint.metadata.appVersion == "unknown" {
                hosts.remove(at: index)
            }
        }
        updateState()
    }

    var savedHosts: [DiscoveredHostRow] {
        hosts.filter(\.isSaved)
    }

    // MARK: - Physical-host de-duplication

    /// One row per *physical* Mac. The same Mac can surface several times — an old
    /// saved IP, a freshly-discovered IP, and a Tailscale "relay" sibling — which is
    /// confusing in the UI. This collapses them and picks the single best endpoint to
    /// show/connect: a reachable LAN address beats a reachable relay, which beats any
    /// offline entry.
    var displayHosts: [DiscoveredHostRow] {
        Self.dedupePhysicalHosts(hosts)
    }

    static func dedupePhysicalHosts(_ rows: [DiscoveredHostRow]) -> [DiscoveredHostRow] {
        guard rows.count > 1 else { return rows }

        // Union-find: two rows are the same Mac if they share a key fingerprint or a
        // MAC address; if NEITHER has a fingerprint, fall back to matching by display
        // name (covers hosts that don't advertise a fingerprint over Bonjour). Rows
        // that *do* have distinct fingerprints are never merged by name, so two
        // different Macs that happen to share a name stay separate.
        var parent = Array(0..<rows.count)
        func find(_ i: Int) -> Int { var r = i; while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }; return r }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }

        func fp(_ r: DiscoveredHostRow) -> String? { normalizedFingerprintStatic(r.endpoint.metadata.publicKeyFingerprint) }
        func mac(_ r: DiscoveredHostRow) -> String? { normalizedMACStatic(r.endpoint.metadata.macAddress) }
        func name(_ r: DiscoveredHostRow) -> String { r.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        for i in 0..<rows.count {
            for j in (i + 1)..<rows.count {
                let a = rows[i], b = rows[j]
                let same: Bool
                if let fa = fp(a), let fb = fp(b) {
                    same = fa == fb
                } else if let ma = mac(a), let mb = mac(b) {
                    same = ma == mb
                } else if fp(a) == nil, fp(b) == nil, !name(a).isEmpty {
                    same = name(a) == name(b)
                } else {
                    same = false
                }
                if same { union(i, j) }
            }
        }

        // Pick the best representative per group.
        var byGroup: [Int: DiscoveredHostRow] = [:]
        for i in 0..<rows.count {
            let g = find(i)
            if let current = byGroup[g] {
                byGroup[g] = preferredRow(current, rows[i])
            } else {
                byGroup[g] = rows[i]
            }
        }

        // Keep stable ordering: available first, then saved, then name.
        return byGroup.values.sorted {
            if $0.isAvailable != $1.isAvailable { return $0.isAvailable && !$1.isAvailable }
            if $0.isSaved != $1.isSaved { return $0.isSaved && !$1.isSaved }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Of two rows for the same Mac, choose the one we'd rather show/connect to:
    /// reachable LAN > reachable relay > offline; ties broken by most recently seen.
    private static func preferredRow(_ a: DiscoveredHostRow, _ b: DiscoveredHostRow) -> DiscoveredHostRow {
        func rank(_ r: DiscoveredHostRow) -> Int {
            let relay = isRelayEndpoint(r)
            if r.isAvailable && !relay { return 3 }   // LAN, reachable — best
            if r.isAvailable && relay { return 2 }    // relay, reachable
            if !relay { return 1 }                    // LAN, offline (wake target)
            return 0                                  // relay, offline
        }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra > rb ? a : b }
        return a.lastSeen >= b.lastSeen ? a : b
    }

    private static func isRelayEndpoint(_ r: DiscoveredHostRow) -> Bool {
        r.endpoint.hostname.contains("ts.net") || r.endpoint.hostname.hasPrefix("100.")
    }

    private static func normalizedFingerprintStatic(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized,
              RemoteDesktopConstants.isValidPublicKeyFingerprint(normalized) else { return nil }
        return normalized
    }

    private static func normalizedMACStatic(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    /// Collapse persisted records that refer to the same physical Mac. Two records match if they
    /// share a key fingerprint, or a MAC address, or (only when NEITHER has a fingerprint) a
    /// hostname:port. The surviving record prefers a fingerprinted one, then the most recent, and
    /// backfills any fields the survivor was missing from the other so wake/tailnet data isn't lost.
    static func collapseDuplicateRecords(_ records: [SavedHost]) -> [SavedHost] {
        guard records.count > 1 else { return records }
        var result: [SavedHost] = []
        for record in records {
            if let index = result.firstIndex(where: { recordsSamePhysicalHost($0, record) }) {
                result[index] = mergeRecords(result[index], record)
            } else {
                result.append(record)
            }
        }
        return result
    }

    private static func recordsSamePhysicalHost(_ a: SavedHost, _ b: SavedHost) -> Bool {
        if let fa = normalizedFingerprintStatic(a.publicKeyFingerprint),
           let fb = normalizedFingerprintStatic(b.publicKeyFingerprint) {
            return fa == fb
        }
        if let ma = normalizedMACStatic(a.macAddress), let mb = normalizedMACStatic(b.macAddress) {
            return ma == mb
        }
        if normalizedFingerprintStatic(a.publicKeyFingerprint) == nil,
           normalizedFingerprintStatic(b.publicKeyFingerprint) == nil {
            return a.hostname.caseInsensitiveCompare(b.hostname) == .orderedSame && a.port == b.port
        }
        return false
    }

    private static func mergeRecords(_ a: SavedHost, _ b: SavedHost) -> SavedHost {
        // Prefer the fingerprinted record, else the more recently connected one.
        let aHasFingerprint = normalizedFingerprintStatic(a.publicKeyFingerprint) != nil
        let bHasFingerprint = normalizedFingerprintStatic(b.publicKeyFingerprint) != nil
        let primary: SavedHost
        let other: SavedHost
        if aHasFingerprint != bHasFingerprint {
            primary = aHasFingerprint ? a : b
            other = aHasFingerprint ? b : a
        } else {
            primary = a.lastConnected >= b.lastConnected ? a : b
            other = a.lastConnected >= b.lastConnected ? b : a
        }
        var merged = primary
        merged.lastConnected = max(a.lastConnected, b.lastConnected)
        merged.macAddress = merged.macAddress ?? other.macAddress
        merged.bonjourServiceName = merged.bonjourServiceName ?? other.bonjourServiceName
        merged.publicKeyFingerprint = merged.publicKeyFingerprint ?? other.publicKeyFingerprint
        merged.wakeSupported = merged.wakeSupported ?? other.wakeSupported
        merged.magicWakeCapable = merged.magicWakeCapable ?? other.magicWakeCapable
        merged.tailscaleHostname = merged.tailscaleHostname ?? other.tailscaleHostname
        merged.tailscaleIP = merged.tailscaleIP ?? other.tailscaleIP
        merged.secureTLSPort = merged.secureTLSPort ?? other.secureTLSPort
        merged.keyAgreementPublicKey = merged.keyAgreementPublicKey ?? other.keyAgreementPublicKey
        return merged
    }

    // MARK: - Saved Hosts Persistence

    private func loadSavedHosts() {
        var records = loadSavedHostRecords()
        // One-time cleanup: collapse duplicate records left by older builds that persisted a host
        // before its fingerprint was known (e.g. a manual/early row that couldn't merge with the
        // later Bonjour-discovered one). Keeps the best-identified, most-recent record per Mac.
        let deduped = Self.collapseDuplicateRecords(records)
        if deduped.count != records.count {
            persistSavedHosts(deduped)
            records = deduped
        }
        for saved in records {
            let metadata = HostAdvertisementMetadata(
                protocolVersion: RemoteDesktopConstants.protocolVersion,
                hostID: saved.id,
                displayName: saved.displayName,
                appVersion: "unknown",
                signalingPort: saved.port,
                capabilities: HostCapabilityFlags(stableNames: []),
                supportedCodecs: ["h264"],
                availability: .available,
                publicKeyFingerprint: saved.publicKeyFingerprint,
                secureTLSPort: saved.secureTLSPort ?? (saved.publicKeyFingerprint == nil ? nil : RemoteDesktopConstants.defaultTLSSignalingPort),
                macAddress: saved.macAddress,
                wakeSupported: saved.wakeSupported,
                magicWakeCapable: saved.magicWakeCapable,
                tailscaleHostname: saved.tailscaleHostname,
                tailscaleIP: saved.tailscaleIP,
                keyAgreementPublicKey: saved.keyAgreementPublicKey
            )
            let endpoint = ResolvedHostEndpoint(
                hostname: saved.hostname,
                port: saved.port,
                metadata: metadata,
                resolvedAt: saved.lastConnected,
                bonjourServiceName: saved.bonjourServiceName
            )
            // A LAN host we can wake (has a MAC or Bonjour name) starts out *offline* until this
            // launch's Bonjour refresh actually confirms it. Showing it as online on a cold launch
            // would hide the wake button (gated on !isAvailable) for a Mac that is asleep right now —
            // the exact case the wake feature exists for. Manual / Tailscale-relay hosts (no wake
            // metadata) stay available so they remain tappable to connect over the relay off-network.
            let isWakeable = saved.macAddress != nil || saved.bonjourServiceName != nil
            let row = DiscoveredHostRow(endpoint: endpoint, lastSeen: saved.lastConnected, isAvailable: !isWakeable, isSaved: true)
            if hosts.firstIndex(where: { $0.id == endpoint.id }) == nil {
                hosts.append(row)
            }
            // Recreate the Tailscale relay sibling so the reconnect sweep can reach this
            // host over the tailnet even on a cold launch away from the home network.
            if let sibling = makeTailscaleSiblingEndpoint(parent: endpoint),
               hosts.firstIndex(where: { $0.id == sibling.id }) == nil {
                hosts.append(DiscoveredHostRow(endpoint: sibling, lastSeen: saved.lastConnected, isAvailable: true, isSaved: false))
            }
        }
        sortHosts()
        updateState()
    }

    private func loadSavedHostRecords() -> [SavedHost] {
        guard let data = UserDefaults.standard.data(forKey: Self.savedHostsKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([SavedHost].self, from: data)
        } catch {
            CrashSafeStartupDiagnostics.error("hosts.saved-hosts.decode", error: error)
            UserDefaults.standard.removeObject(forKey: Self.savedHostsKey)
            return []
        }
    }

    private func persistSavedHosts(_ records: [SavedHost]) {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.savedHostsKey)
        } else {
            CrashSafeStartupDiagnostics.fault("hosts.saved-hosts.encode", message: "Failed to encode \(records.count) records")
        }
    }

    private func upsertSavedHostRecord(_ saved: SavedHost) {
        var all = loadSavedHostRecords()
        all.removeAll { savedHostRecord($0, matches: saved) }
        all.append(saved)
        persistSavedHosts(all)
    }

    private func parseManualAddress(_ address: String) -> (hostname: String, port: UInt16)? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { return nil }
        // Valid hostnames and IPs never contain spaces — reject error strings
        guard !trimmedAddress.contains(" ") else { return nil }

        let addressWithScheme: String
        if trimmedAddress.contains("://") {
            addressWithScheme = trimmedAddress
        } else {
            addressWithScheme = "rdt://\(trimmedAddress)"
        }

        guard let components = URLComponents(string: addressWithScheme),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !normalizedHost.isEmpty else { return nil }

        let port = components.port.flatMap(UInt16.init) ?? RemoteDesktopConstants.defaultSignalingPort
        return (normalizedHost, port)
    }

    /// Reuse a previously discovered fingerprint, TLS port, and sealing key so a
    /// typed Tailscale/MagicDNS address does not fall back to cleartext 9471.
    private func applyKnownHostIdentity(hostname: String, to metadata: inout HostAdvertisementMetadata) {
        let matches: (String?) -> Bool = { candidate in
            guard let candidate, !candidate.isEmpty else { return false }
            return candidate.caseInsensitiveCompare(hostname) == .orderedSame
        }
        let live = hosts.compactMap { row -> HostAdvertisementMetadata? in
            guard matches(row.endpoint.hostname)
                    || matches(row.endpoint.metadata.tailscaleHostname)
                    || matches(row.endpoint.metadata.tailscaleIP) else {
                return nil
            }
            return row.endpoint.metadata
        }
        let saved = loadSavedHostRecords().compactMap { record -> HostAdvertisementMetadata? in
            guard matches(record.hostname) || matches(record.tailscaleHostname) || matches(record.tailscaleIP) else {
                return nil
            }
            return HostAdvertisementMetadata(
                protocolVersion: RemoteDesktopConstants.protocolVersion,
                hostID: record.id,
                displayName: record.displayName,
                appVersion: "unknown",
                signalingPort: record.port,
                capabilities: HostCapabilityFlags(stableNames: []),
                publicKeyFingerprint: record.publicKeyFingerprint,
                secureTLSPort: record.secureTLSPort,
                keyAgreementPublicKey: record.keyAgreementPublicKey
            )
        }
        for source in live + saved {
            if metadata.publicKeyFingerprint == nil {
                metadata.publicKeyFingerprint = source.publicKeyFingerprint
            }
            if metadata.keyAgreementPublicKey == nil {
                metadata.keyAgreementPublicKey = source.keyAgreementPublicKey
            }
            if metadata.secureTLSPort == nil {
                metadata.secureTLSPort = source.secureTLSPort
            }
        }
        if metadata.publicKeyFingerprint != nil, metadata.secureTLSPort == nil {
            metadata.secureTLSPort = RemoteDesktopConstants.defaultTLSSignalingPort
        }
    }

    private func upsertManual(endpoint: ResolvedHostEndpoint, isAvailable: Bool) -> DiscoveredHostRow {
        let isSaved = loadSavedHostRecords().contains { $0.hostname == endpoint.hostname && $0.port == endpoint.port }
        let row = DiscoveredHostRow(endpoint: endpoint, lastSeen: Date(), isAvailable: isAvailable, isSaved: isSaved)
        if let index = hosts.firstIndex(where: { $0.id == endpoint.id }) {
            hosts[index] = row
        } else {
            hosts.append(row)
        }
        sortHosts()
        updateState()
        return row
    }

    private func staleHost(
        _ host: DiscoveredHostRow,
        matches endpoint: ResolvedHostEndpoint,
        fingerprint: String?,
        macAddress: String?
    ) -> Bool {
        guard host.id != endpoint.id else { return false }
        if let fingerprint,
           normalizedFingerprint(host.endpoint.metadata.publicKeyFingerprint) == fingerprint {
            return true
        }
        if let macAddress,
           normalizedMACAddress(host.endpoint.metadata.macAddress) == macAddress {
            return true
        }
        return host.endpoint.hostname == endpoint.hostname && host.endpoint.port == endpoint.port
    }

    private func savedHostRecord(_ lhs: SavedHost, matches rhs: SavedHost) -> Bool {
        if lhs.id == rhs.id {
            return true
        }
        if let lhsFingerprint = normalizedFingerprint(lhs.publicKeyFingerprint),
           let rhsFingerprint = normalizedFingerprint(rhs.publicKeyFingerprint),
           lhsFingerprint == rhsFingerprint {
            return true
        }
        if let lhsMAC = normalizedMACAddress(lhs.macAddress),
           let rhsMAC = normalizedMACAddress(rhs.macAddress),
           lhsMAC == rhsMAC {
            return true
        }
        return lhs.hostname == rhs.hostname && lhs.port == rhs.port
    }

    private func savedHostRecord(_ record: SavedHost, matches endpoint: ResolvedHostEndpoint) -> Bool {
        if record.id == endpoint.id {
            return true
        }
        if let recordFingerprint = normalizedFingerprint(record.publicKeyFingerprint),
           let endpointFingerprint = normalizedFingerprint(endpoint.metadata.publicKeyFingerprint),
           recordFingerprint == endpointFingerprint {
            return true
        }
        if let recordMAC = normalizedMACAddress(record.macAddress),
           let endpointMAC = normalizedMACAddress(endpoint.metadata.macAddress),
           recordMAC == endpointMAC {
            return true
        }
        return record.hostname == endpoint.hostname && record.port == endpoint.port
    }

    private func savedRecordMatchesStaleHost(_ record: SavedHost, stale: DiscoveredHostRow) -> Bool {
        if record.id == stale.id {
            return true
        }
        if let recordFingerprint = normalizedFingerprint(record.publicKeyFingerprint),
           let staleFingerprint = normalizedFingerprint(stale.endpoint.metadata.publicKeyFingerprint),
           recordFingerprint == staleFingerprint {
            return true
        }
        if let recordMAC = normalizedMACAddress(record.macAddress),
           let staleMAC = normalizedMACAddress(stale.endpoint.metadata.macAddress),
           recordMAC == staleMAC {
            return true
        }
        return record.hostname == stale.endpoint.hostname && record.port == stale.endpoint.port
    }

    private func normalizedFingerprint(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized,
              RemoteDesktopConstants.isValidPublicKeyFingerprint(normalized) else { return nil }
        return normalized
    }

    private func normalizedMACAddress(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }
}
