import Discovery
import SharedModels
import XCTest

@MainActor
final class MacHostNicknameStoreTests: XCTestCase {
    private func endpoint(
        hostname: String = "mac-m4.local",
        port: UInt16 = 9471,
        displayName: String = "Mac M4",
        fingerprint: String? = "AB12CD"
    ) -> ResolvedHostEndpoint {
        ResolvedHostEndpoint(
            hostname: hostname,
            port: port,
            metadata: HostAdvertisementMetadata(
                protocolVersion: 1,
                hostID: UUID(),
                displayName: displayName,
                appVersion: "1.0",
                signalingPort: port,
                capabilities: .baseline,
                publicKeyFingerprint: fingerprint
            )
        )
    }

    private func makeStore() -> (MacHostNicknameStore, String) {
        let suiteName = "MacHostNicknameStoreTests.\(UUID().uuidString)"
        return (MacHostNicknameStore(defaults: UserDefaults(suiteName: suiteName)!), suiteName)
    }

    func testFallsBackToTheAdvertisedName() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertEqual(store.displayName(for: endpoint()), "Mac M4")
        XCTAssertNil(store.nickname(for: endpoint()))
    }

    func testRenameWins() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.setNickname("Studio", for: endpoint())
        XCTAssertEqual(store.displayName(for: endpoint()), "Studio")
    }

    func testRenameSurvivesAnAddressChangeWhenTheKeyIsPinned() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.setNickname("Studio", for: endpoint(hostname: "mac-m4.local"))
        // Same Mac, new address: keyed on the pinned fingerprint, so the name holds.
        XCTAssertEqual(store.displayName(for: endpoint(hostname: "192.168.1.40")), "Studio")
    }

    func testDifferentHostsDoNotShareANickname() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.setNickname("Studio", for: endpoint(fingerprint: "AB12CD"))
        XCTAssertEqual(
            store.displayName(for: endpoint(displayName: "Mac mini", fingerprint: "EF34GH")),
            "Mac mini"
        )
    }

    func testClearingRestoresTheAdvertisedName() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.setNickname("Studio", for: endpoint())
        for cleared in [nil, "", "   "] as [String?] {
            store.setNickname("Studio", for: endpoint())
            store.setNickname(cleared, for: endpoint())
            XCTAssertEqual(store.displayName(for: endpoint()), "Mac M4")
            XCTAssertNil(store.nickname(for: endpoint()))
        }
    }

    func testRenamingToTheAdvertisedNameStoresNothing() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.setNickname("Mac M4", for: endpoint())
        XCTAssertNil(store.nickname(for: endpoint()), "No pencil badge for a no-op rename")
    }

    func testAddressKeyedWhenTheHostAdvertisesNoFingerprint() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let manual = endpoint(hostname: "192.168.1.20", displayName: "192.168.1.20", fingerprint: nil)
        store.setNickname("Lab Mac", for: manual)
        XCTAssertEqual(store.displayName(for: manual), "Lab Mac")
        XCTAssertEqual(
            store.displayName(for: endpoint(hostname: "192.168.1.21", displayName: "Other", fingerprint: nil)),
            "Other"
        )
    }
}
