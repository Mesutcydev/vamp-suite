import XCTest
@testable import Vamp_Stream

final class VampStreamHomeLayoutTests: XCTestCase {
    func testBothLeadsWithSyncThenAssistant() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                source: .both,
                hasSyncHosts: true,
                hasAssistants: true,
                hasAssistantError: false
            ),
            [
                .syncHostCard,
                .syncMacs,
                .syncPromo,
                .assistantHostCard,
                .assistantMacs
            ]
        )
    }

    func testSyncOnlyHidesAssistant() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                source: .sync,
                hasSyncHosts: true,
                hasAssistants: true,
                hasAssistantError: true
            ),
            [
                .syncHostCard,
                .syncMacs,
                .syncPromo
            ]
        )
    }

    func testAssistantOnlyHidesSync() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                source: .assistant,
                hasSyncHosts: true,
                hasAssistants: true,
                hasAssistantError: false
            ),
            [
                .assistantHostCard,
                .assistantMacs
            ]
        )
    }

    func testEmptySyncKeepsHintWhenSyncIsChosen() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                source: .both,
                hasSyncHosts: false,
                hasAssistants: false,
                hasAssistantError: false
            ),
            [
                .syncHostCard,
                .syncEmptyHint,
                .syncPromo,
                .assistantHostCard
            ]
        )
    }

    func testAssistantErrorSitsWithAssistantFollowOn() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                source: .both,
                hasSyncHosts: true,
                hasAssistants: false,
                hasAssistantError: true
            ),
            [
                .syncHostCard,
                .syncMacs,
                .syncPromo,
                .assistantError,
                .assistantHostCard
            ]
        )
    }

    func testHostSourceVisibility() {
        XCTAssertTrue(VampStreamHostSource.sync.showsSync)
        XCTAssertFalse(VampStreamHostSource.sync.showsAssistant)
        XCTAssertFalse(VampStreamHostSource.assistant.showsSync)
        XCTAssertTrue(VampStreamHostSource.assistant.showsAssistant)
        XCTAssertTrue(VampStreamHostSource.both.showsSync)
        XCTAssertTrue(VampStreamHostSource.both.showsAssistant)
    }

    func testHostSourceStoreRoundTrips() {
        let suite = "VampStreamHostSourceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(VampStreamHostSourceStore.load(defaults: defaults))
        VampStreamHostSourceStore.save(.assistant, defaults: defaults)
        XCTAssertEqual(VampStreamHostSourceStore.load(defaults: defaults), .assistant)
        VampStreamHostSourceStore.save(.sync, defaults: defaults)
        XCTAssertEqual(VampStreamHostSourceStore.load(defaults: defaults), .sync)
    }

    func testPrimaryScanCopyNamesVampSync() {
        XCTAssertEqual(VampStreamHomeCopy.syncTitle, "Vamp Sync")
        XCTAssertEqual(VampStreamHomeCopy.scanSync, "Scan Vamp Sync")
        XCTAssertTrue(VampStreamHomeCopy.assistantTitle.contains("Assistant"))
        XCTAssertTrue(VampStreamHomeCopy.assistantTitle.contains("Companion"))
        XCTAssertEqual(
            VampStreamHomeCopy.pairAssistantTitle(hasSavedAssistants: false),
            "Pair Assistant or Companion"
        )
        XCTAssertEqual(
            VampStreamHomeCopy.pairAssistantTitle(hasSavedAssistants: true),
            "Pair another Mac"
        )
    }

    func testSyncPromoOpensTheDownloadPage() {
        XCTAssertEqual(VampStreamHomeLinks.syncDownload.absoluteString, "https://thevamp.app/sync/#download")
        XCTAssertEqual(VampStreamHomeCopy.syncPromoCTA, "Get Vamp Sync")
        XCTAssertFalse(VampStreamHomeLayout.sections(
            source: .assistant,
            hasSyncHosts: false,
            hasAssistants: false,
            hasAssistantError: false
        ).contains(.syncPromo))
        XCTAssertTrue(VampStreamHomeLayout.sections(
            source: .sync,
            hasSyncHosts: false,
            hasAssistants: false,
            hasAssistantError: false
        ).contains(.syncPromo))
    }

    func testSyncPromoHidesAfterInstallConfirmation() {
        XCTAssertFalse(VampStreamHomeLayout.sections(
            source: .sync,
            hasSyncHosts: false,
            hasAssistants: false,
            hasAssistantError: false,
            showsSyncPromo: false
        ).contains(.syncPromo))

        let suite = "VampStreamSyncPromoStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(VampStreamSyncPromoStore.isInstalled(defaults: defaults))
        VampStreamSyncPromoStore.setInstalled(true, defaults: defaults)
        XCTAssertTrue(VampStreamSyncPromoStore.isInstalled(defaults: defaults))
        XCTAssertEqual(VampStreamHomeCopy.syncPromoInstalledTitle, "Is Vamp Sync installed on your Mac?")
        XCTAssertEqual(VampStreamHomeCopy.syncPromoInstalledYes, "Yes, it’s installed")
        XCTAssertEqual(VampStreamHomeCopy.syncPromoInstalledNotYet, "Not yet")
    }

    func testSyncConnectCardCollapsesOnlyWhenPaired() {
        XCTAssertFalse(VampStreamSyncConnectCardStore.showsCollapsed(isPaired: false, preference: true))
        XCTAssertFalse(VampStreamSyncConnectCardStore.showsCollapsed(isPaired: true, preference: false))
        XCTAssertTrue(VampStreamSyncConnectCardStore.showsCollapsed(isPaired: true, preference: true))
        XCTAssertEqual(VampStreamHomeCopy.syncConnectCollapse, "Minimize Vamp Sync connection")
        XCTAssertEqual(VampStreamHomeCopy.syncConnectExpand, "Show Vamp Sync connection")
    }

    func testHomeCardStyleTogglesBetweenListAndGrid() {
        XCTAssertEqual(VampStreamHomeCardStyle.list.toggled, .grid)
        XCTAssertEqual(VampStreamHomeCardStyle.grid.toggled, .list)
        XCTAssertEqual(VampStreamHomeCardStyle.list.toggleSystemImage, "square.grid.2x2")
        XCTAssertEqual(VampStreamHomeCardStyle.grid.toggleSystemImage, "list.bullet")
        XCTAssertEqual(VampStreamHomeCopy.showGrid, "Show rectangular cards")
        XCTAssertEqual(VampStreamHomeCopy.showList, "Show list cards")

        let suite = "VampStreamHomeCardStyleStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(VampStreamHomeCardStyleStore.load(defaults: defaults), .list)
        VampStreamHomeCardStyleStore.save(.grid, defaults: defaults)
        XCTAssertEqual(VampStreamHomeCardStyleStore.load(defaults: defaults), .grid)
    }
}
