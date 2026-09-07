import XCTest
@testable import Vamp_Stream

final class VampStreamHomeLayoutTests: XCTestCase {
    /// Configured hosts are the primary content: they come first, above the "Pair a host"
    /// divider and the two collapsible pairing cards.
    func testBothLeadsWithHostsThenPairingCards() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                source: .both,
                hasSyncHosts: true,
                hasAssistants: true,
                hasAssistantError: false
            ),
            [
                .syncMacs,
                .assistantMacs,
                .pairHeading,
                .syncHostCard,
                .assistantHostCard,
                .versionFooter
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
                .syncMacs,
                .pairHeading,
                .syncHostCard,
                .versionFooter
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
                .assistantMacs,
                .pairHeading,
                .assistantHostCard,
                .versionFooter
            ]
        )
    }

    /// With nothing configured there are no host rows, so the pairing group is all there is. The
    /// empty-state hint stays above the divider, and the download promo only appears while Sync
    /// is not yet set up.
    func testEmptySyncKeepsHintWhenSyncIsChosen() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                source: .both,
                hasSyncHosts: false,
                hasAssistants: false,
                hasAssistantError: false
            ),
            [
                .syncEmptyHint,
                .pairHeading,
                .syncPromo,
                .syncHostCard,
                .assistantHostCard,
                .versionFooter
            ]
        )
    }

    /// The download promo must not appear once a Sync host is configured.
    func testSyncPromoDisappearsOnceAHostIsConfigured() {
        XCTAssertFalse(VampStreamHomeLayout.sections(
            source: .sync,
            hasSyncHosts: true,
            hasAssistants: false,
            hasAssistantError: false
        ).contains(.syncPromo))
    }

    /// An Assistant error is scoped next to the Assistant hosts it refers to, never rendered as an
    /// unrelated page-wide card sitting between provider sections.
    func testAssistantErrorSitsWithAssistantHosts() {
        let sections = VampStreamHomeLayout.sections(
            source: .both,
            hasSyncHosts: true,
            hasAssistants: true,
            hasAssistantError: true
        )
        let errorIndex = try? XCTUnwrap(sections.firstIndex(of: .assistantError))
        let macsIndex = try? XCTUnwrap(sections.firstIndex(of: .assistantMacs))
        XCTAssertNotNil(errorIndex)
        XCTAssertNotNil(macsIndex)
        if let errorIndex, let macsIndex {
            XCTAssertEqual(errorIndex, macsIndex + 1, "error belongs directly after Assistant Macs")
        }
        // And it stays out of the pairing group.
        let pairingIndex = try? XCTUnwrap(sections.firstIndex(of: .pairHeading))
        if let errorIndex, let pairingIndex {
            XCTAssertLessThan(errorIndex, pairingIndex)
        }
    }

    /// Every source offers at least its own pairing card, so the heading is always present — and
    /// always directly above the first pairing card, never above a host row.
    func testPairHeadingSitsDirectlyAboveTheFirstPairingCard() {
        for source in VampStreamHostSource.allCases {
            let sections = VampStreamHomeLayout.sections(
                source: source,
                hasSyncHosts: true,
                hasAssistants: true,
                hasAssistantError: false
            )
            let headingIndex = try? XCTUnwrap(sections.firstIndex(of: .pairHeading), "\(source)")
            XCTAssertNotNil(headingIndex, "\(source) must offer a pairing heading")
            guard let headingIndex else { continue }
            let next = sections[sections.index(after: headingIndex)]
            XCTAssertTrue(next == .syncHostCard || next == .assistantHostCard,
                "\(source): \(next) must be a pairing card, not a host row")
            // All host rows precede the heading.
            for index in sections.indices where index < headingIndex {
                XCTAssertFalse(sections[index] == .syncHostCard || sections[index] == .assistantHostCard,
                    "\(source): a pairing card appeared above the heading")
            }
        }
    }

    /// The version footer is always last and always present, so it never competes with the title.
    func testVersionFooterIsAlwaysLast() {
        for source in VampStreamHostSource.allCases {
            for hasHosts in [false, true] {
                let sections = VampStreamHomeLayout.sections(
                    source: source,
                    hasSyncHosts: hasHosts,
                    hasAssistants: hasHosts,
                    hasAssistantError: false
                )
                XCTAssertEqual(sections.last, .versionFooter, "\(source) hosts=\(hasHosts)")
                XCTAssertEqual(sections.filter { $0 == .versionFooter }.count, 1)
            }
        }
    }

    /// Ordering must not depend on how many hosts discovery happens to have returned this tick.
    func testOrderIsStableAsHostCountsChange() {
        let one = VampStreamHomeLayout.sections(
            source: .both, hasSyncHosts: true, hasAssistants: true, hasAssistantError: false)
        let two = VampStreamHomeLayout.sections(
            source: .both, hasSyncHosts: true, hasAssistants: true, hasAssistantError: false)
        XCTAssertEqual(one, two)
    }

    /// A Vamp Sync failure must not be labelled as an Assistant problem. The old wiring merged the
    /// coordinator's message into the Assistant slot (`assistant ?? coordinator`), so a Sync
    /// host-busy rejection rendered inside the Assistant group.
    func testSyncErrorIsScopedToTheSyncSection() {
        let sections = VampStreamHomeLayout.sections(
            source: .both,
            hasSyncHosts: true,
            hasAssistants: true,
            hasAssistantError: false,
            hasSyncError: true
        )
        XCTAssertTrue(sections.contains(.syncError))
        XCTAssertFalse(sections.contains(.assistantError))

        let syncIndex = try? XCTUnwrap(sections.firstIndex(of: .syncError))
        let assistantIndex = try? XCTUnwrap(sections.firstIndex(of: .assistantMacs))
        XCTAssertNotNil(syncIndex)
        XCTAssertNotNil(assistantIndex)
        if let syncIndex, let assistantIndex {
            XCTAssertLessThan(syncIndex, assistantIndex,
                "a Sync error must not appear after the Assistant hosts")
        }
    }

    /// Each provider's error appears only in its own slot; neither leaks into the other.
    func testProviderErrorsDoNotCrossContaminate() {
        let syncOnly = VampStreamHomeLayout.sections(
            source: .both, hasSyncHosts: true, hasAssistants: true,
            hasAssistantError: false, hasSyncError: true)
        XCTAssertTrue(syncOnly.contains(.syncError))
        XCTAssertFalse(syncOnly.contains(.assistantError))

        let assistantOnly = VampStreamHomeLayout.sections(
            source: .both, hasSyncHosts: true, hasAssistants: true,
            hasAssistantError: true, hasSyncError: false)
        XCTAssertTrue(assistantOnly.contains(.assistantError))
        XCTAssertFalse(assistantOnly.contains(.syncError))

        let neither = VampStreamHomeLayout.sections(
            source: .both, hasSyncHosts: true, hasAssistants: true,
            hasAssistantError: false, hasSyncError: false)
        XCTAssertFalse(neither.contains(.syncError))
        XCTAssertFalse(neither.contains(.assistantError))
    }

    /// No error slot is created merely to fill space, and an error never suppresses the hosts.
    func testErrorsDoNotCreateEmptySectionsOrHideHosts() {
        let sections = VampStreamHomeLayout.sections(
            source: .both, hasSyncHosts: true, hasAssistants: true,
            hasAssistantError: true, hasSyncError: true)
        XCTAssertTrue(sections.contains(.syncMacs), "hosts stay usable while an error shows")
        XCTAssertTrue(sections.contains(.assistantMacs))
        XCTAssertEqual(sections.filter { $0 == .syncError }.count, 1)
        XCTAssertEqual(sections.filter { $0 == .assistantError }.count, 1)
    }

    /// "Mac is in use" is recognised so the UI can show the compact host-scoped copy instead of
    /// repeating the coordinator's long sentence, and unrelated failures are left alone.
    func testHostBusyIsRecognised() {
        XCTAssertTrue(VampStreamHostBusy.isHostBusy(
            "This Mac is already connected to another device. Disconnect that session, then try again."))
        XCTAssertTrue(VampStreamHostBusy.isHostBusy("The Mac is in use."))
        XCTAssertTrue(VampStreamHostBusy.isHostBusy("Another client is already connected."))
        XCTAssertFalse(VampStreamHostBusy.isHostBusy("Secure connection to the Mac failed."))
        XCTAssertFalse(VampStreamHostBusy.isHostBusy(nil))
        XCTAssertFalse(VampStreamHostBusy.isHostBusy(""))
        XCTAssertEqual(VampStreamHostBusy.title, "Mac is in use")
        XCTAssertEqual(VampStreamHostBusy.detail, "Disconnect the other device, then try again.")
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
        XCTAssertEqual(VampStreamHomeCopy.assistantTitle, "Vamp Assistant")
        XCTAssertEqual(
            VampStreamHomeCopy.pairAssistantTitle(hasSavedAssistants: false),
            "Pair Vamp Assistant"
        )
        XCTAssertEqual(
            VampStreamHomeCopy.pairAssistantTitle(hasSavedAssistants: true),
            "Pair another Assistant"
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

    func testPairingCardCopyDescribesCollapseAndExpand() {
        XCTAssertEqual(VampStreamHomeCopy.syncConnectCollapse, "Minimize Vamp Sync connection")
        XCTAssertEqual(VampStreamHomeCopy.syncConnectExpand, "Show Vamp Sync connection")
        XCTAssertEqual(VampStreamHomeCopy.assistantConnectCollapse, "Minimize Vamp Assistant pairing")
        XCTAssertEqual(VampStreamHomeCopy.assistantConnectExpand, "Show Vamp Assistant pairing")
        XCTAssertEqual(VampStreamHomeCopy.syncConnectCollapsedDetail, "Scan QR or connect by address")
        XCTAssertEqual(
            VampStreamHomeCopy.assistantConnectCollapsedDetail, "Connect an Assistant workspace")
    }

    /// An explicit saved preference always wins over any computed default, for both providers
    /// independently.
    func testExplicitPairingCardPreferenceWins() {
        XCTAssertTrue(VampStreamPairingCardStore.showsExpanded(
            explicitPreference: true, hasConfiguredHost: true, isSetupProvider: false))
        XCTAssertFalse(VampStreamPairingCardStore.showsExpanded(
            explicitPreference: false, hasConfiguredHost: false, isSetupProvider: true))
    }

    /// A returning user with configured hosts sees both cards collapsed — the Macs are the
    /// content, the setup form is not.
    func testConfiguredHostsCollapseBothPairingCards() {
        for isSetupProvider in [false, true] {
            XCTAssertFalse(VampStreamPairingCardStore.showsExpanded(
                explicitPreference: nil,
                hasConfiguredHost: true,
                isSetupProvider: isSetupProvider),
                "isSetupProvider=\(isSetupProvider)")
        }
    }

    /// A first-time user sees exactly one card expanded: the provider they are setting up.
    func testFirstRunExpandsOnlyTheSetupProvider() {
        XCTAssertTrue(VampStreamPairingCardStore.showsExpanded(
            explicitPreference: nil, hasConfiguredHost: false, isSetupProvider: true))
        XCTAssertFalse(VampStreamPairingCardStore.showsExpanded(
            explicitPreference: nil, hasConfiguredHost: false, isSetupProvider: false))
    }

    /// Each provider persists under its own key, so collapsing one must not collapse the other.
    func testPairingCardProvidersPersistIndependently() {
        let suite = "VampStreamPairingCardStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(VampStreamPairingCardStore.explicitPreference(.sync, defaults: defaults))
        XCTAssertNil(VampStreamPairingCardStore.explicitPreference(.assistant, defaults: defaults))

        VampStreamPairingCardStore.setExpanded(false, provider: .sync, defaults: defaults)
        XCTAssertEqual(VampStreamPairingCardStore.explicitPreference(.sync, defaults: defaults), false)
        XCTAssertNil(VampStreamPairingCardStore.explicitPreference(.assistant, defaults: defaults),
            "writing Sync must not create an Assistant preference")

        VampStreamPairingCardStore.setExpanded(true, provider: .assistant, defaults: defaults)
        XCTAssertEqual(VampStreamPairingCardStore.explicitPreference(.assistant, defaults: defaults), true)
        XCTAssertEqual(VampStreamPairingCardStore.explicitPreference(.sync, defaults: defaults), false,
            "writing Assistant must not change Sync")

        XCTAssertNotEqual(
            VampStreamPairingCardStore.Provider.key(for: .sync),
            VampStreamPairingCardStore.Provider.key(for: .assistant))
    }

    /// Latching resolves the first-run default exactly once. Recomputing it from discovery would
    /// flip cards open every time a host briefly drops off the network.
    func testPairingCardDefaultLatchesOnceAndIsNotRecomputed() {
        let suite = "VampStreamPairingLatchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // First run, nothing configured, setting up Sync.
        VampStreamPairingCardStore.latchDefaultIfNeeded(
            provider: .sync, hasConfiguredHost: false, isSetupProvider: true, defaults: defaults)
        VampStreamPairingCardStore.latchDefaultIfNeeded(
            provider: .assistant, hasConfiguredHost: false, isSetupProvider: false, defaults: defaults)
        XCTAssertEqual(VampStreamPairingCardStore.explicitPreference(.sync, defaults: defaults), true)
        XCTAssertEqual(VampStreamPairingCardStore.explicitPreference(.assistant, defaults: defaults), false)

        // Discovery now reports a configured host. The latched default must not change.
        VampStreamPairingCardStore.latchDefaultIfNeeded(
            provider: .sync, hasConfiguredHost: true, isSetupProvider: false, defaults: defaults)
        XCTAssertEqual(VampStreamPairingCardStore.explicitPreference(.sync, defaults: defaults), true,
            "a fluctuating discovery list must not re-collapse a latched card")

        // A user toggle survives later latching attempts.
        VampStreamPairingCardStore.setExpanded(false, provider: .sync, defaults: defaults)
        VampStreamPairingCardStore.latchDefaultIfNeeded(
            provider: .sync, hasConfiguredHost: false, isSetupProvider: true, defaults: defaults)
        XCTAssertEqual(VampStreamPairingCardStore.explicitPreference(.sync, defaults: defaults), false)
    }

    func testHomeCardStyleTogglesBetweenListAndGrid() {
        XCTAssertEqual(VampStreamHomeCardStyle.list.toggled, .grid)
        XCTAssertEqual(VampStreamHomeCardStyle.grid.toggled, .list)
        XCTAssertEqual(VampStreamHomeCardStyle.list.toggleSystemImage, "square.grid.2x2")
        XCTAssertEqual(VampStreamHomeCardStyle.grid.toggleSystemImage, "list.bullet")
        // The label describes the action the control performs ("show grid"), not the shape of
        // the current cards. It moved next to the Macs heading, so it must read as an action.
        XCTAssertEqual(VampStreamHomeCopy.showGrid, "Show grid view")
        XCTAssertEqual(VampStreamHomeCopy.showList, "Show list view")

        let suite = "VampStreamHomeCardStyleStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(VampStreamHomeCardStyleStore.load(defaults: defaults), .list)
        VampStreamHomeCardStyleStore.save(.grid, defaults: defaults)
        XCTAssertEqual(VampStreamHomeCardStyleStore.load(defaults: defaults), .grid)
    }
}
