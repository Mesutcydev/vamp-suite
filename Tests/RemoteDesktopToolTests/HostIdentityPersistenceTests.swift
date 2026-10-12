import XCTest
@testable import ClientiOS
@testable import Discovery
@testable import SharedModels
@testable import SharedUtilities

final class HostIdentityPersistenceTests: XCTestCase {
    private let savedHostsKey = "com.remotedesktop.savedHosts"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: savedHostsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: savedHostsKey)
        super.tearDown()
    }

    func testStableHostIDIsDerivedFromFingerprint() {
        let fingerprint = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

        let first = HostIdentity.stableID(publicKeyFingerprint: fingerprint)
        let second = HostIdentity.stableID(publicKeyFingerprint: fingerprint.uppercased())

        XCTAssertEqual(first, UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        XCTAssertEqual(first, second)
    }

    @MainActor
    func testSavedUnknownHostIsAdoptedWhenSameFingerprintIsDiscoveredWithNewIDAndAddress() async {
        let fingerprint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let oldID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let newID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        persistSavedHosts([
            SavedHost(
                id: oldID,
                hostname: "192.168.1.20",
                port: RemoteDesktopConstants.defaultSignalingPort,
                displayName: "Studio Mac",
                lastConnected: Date(timeIntervalSince1970: 100),
                macAddress: nil,
                bonjourServiceName: "Studio Mac",
                publicKeyFingerprint: fingerprint
            )
        ])
        let browser = HostListTestBrowser(endpoints: [
            makeEndpoint(
                id: newID,
                hostname: "192.168.1.44",
                displayName: "Studio Mac",
                appVersion: "2.1",
                fingerprint: fingerprint
            )
        ])
        let viewModel = HostsListViewModel(browser: browser)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.hosts.count, 1)
        XCTAssertEqual(viewModel.savedHosts.count, 1)
        XCTAssertEqual(viewModel.savedHosts.first?.id, newID)
        XCTAssertEqual(viewModel.savedHosts.first?.endpoint.metadata.appVersion, "2.1")
        XCTAssertEqual(loadSavedHosts().map(\.id), [newID])
    }

    @MainActor
    func testDisplayHostsCollapsesLANAndTailscaleRowsForSameMac() {
        let fingerprint = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let lan = DiscoveredHostRow(
            endpoint: makeEndpoint(
                id: UUID(),
                hostname: "192.168.1.13",
                displayName: "Mac M4",
                appVersion: "2.3",
                fingerprint: fingerprint),
            lastSeen: Date(),
            isAvailable: true,
            isSaved: true)
        let tailscale = DiscoveredHostRow(
            endpoint: makeEndpoint(
                id: UUID(),
                hostname: "100.73.221.10",
                displayName: "Mac M4",
                appVersion: "2.3",
                fingerprint: fingerprint),
            lastSeen: Date().addingTimeInterval(1),
            isAvailable: true,
            isSaved: true)

        let visible = HostsListViewModel.dedupePhysicalHosts([tailscale, lan])

        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.endpoint.hostname, "192.168.1.13")
    }

    private func persistSavedHosts(_ hosts: [SavedHost]) {
        let data = try! JSONEncoder().encode(hosts)
        UserDefaults.standard.set(data, forKey: savedHostsKey)
    }

    private func loadSavedHosts() -> [SavedHost] {
        guard let data = UserDefaults.standard.data(forKey: savedHostsKey) else { return [] }
        return (try? JSONDecoder().decode([SavedHost].self, from: data)) ?? []
    }

    private func makeEndpoint(
        id: UUID,
        hostname: String,
        displayName: String,
        appVersion: String,
        fingerprint: String
    ) -> ResolvedHostEndpoint {
        let metadata = HostAdvertisementMetadata(
            protocolVersion: RemoteDesktopConstants.protocolVersion,
            hostID: id,
            displayName: displayName,
            appVersion: appVersion,
            signalingPort: RemoteDesktopConstants.defaultSignalingPort,
            capabilities: [.supportsH264],
            supportedCodecs: ["h264"],
            availability: .available,
            publicKeyFingerprint: fingerprint
        )
        return ResolvedHostEndpoint(
            hostname: hostname,
            port: RemoteDesktopConstants.defaultSignalingPort,
            metadata: metadata,
            resolvedAt: Date(),
            bonjourServiceName: displayName
        )
    }
}

private final class HostListTestBrowser: BonjourDiscoveryBrowsing {
    var endpoints: [ResolvedHostEndpoint]

    init(endpoints: [ResolvedHostEndpoint]) {
        self.endpoints = endpoints
    }

    func startBrowsing(serviceType: String, domain: String) async throws {}

    func stopBrowsing() async {}

    func resolvedHosts() async -> [ResolvedHostEndpoint] {
        endpoints
    }

    func events() -> AsyncStream<BonjourDiscoveryEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
