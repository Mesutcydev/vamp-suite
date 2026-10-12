import XCTest
@testable import Vamp_Stream

@MainActor
final class BeetCodeRemoteSessionViewModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "VampStreamTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadsMultipleSavedAssistantsWithoutCollapsingThem() throws {
        let saved = [
            BeetCodeRemoteSessionViewModel.SavedAssistant(
                address: "http://192.168.1.20:9575",
                displayName: "Studio Mac"
            ),
            BeetCodeRemoteSessionViewModel.SavedAssistant(
                address: "http://100.90.80.70:9575",
                displayName: "Travel Mac"
            ),
        ]
        defaults.set(try JSONEncoder().encode(saved), forKey: "vampstream.assistant.savedAssistants.v1")

        let model = BeetCodeRemoteSessionViewModel(defaults: defaults)

        XCTAssertEqual(model.savedAssistants, saved)
    }

    func testMigratesLegacyAddressAlongsideExistingSavedAssistants() throws {
        let existing = BeetCodeRemoteSessionViewModel.SavedAssistant(
            address: "http://192.168.1.20:9575",
            displayName: "Studio Mac"
        )
        defaults.set(try JSONEncoder().encode([existing]), forKey: "vampstream.assistant.savedAssistants.v1")
        defaults.set("http://192.168.1.30:9575", forKey: "vampstream.beetcode.savedAddress")

        let model = BeetCodeRemoteSessionViewModel(defaults: defaults)

        XCTAssertEqual(model.savedAssistants.map(\.address), [
            "http://192.168.1.20:9575",
            "http://192.168.1.30:9575",
        ])
        XCTAssertNil(defaults.string(forKey: "vampstream.beetcode.savedAddress"))
    }

    func testForgettingOneAssistantPreservesTheOther() throws {
        let first = BeetCodeRemoteSessionViewModel.SavedAssistant(
            address: "http://192.168.1.20:9575",
            displayName: "Studio Mac"
        )
        let second = BeetCodeRemoteSessionViewModel.SavedAssistant(
            address: "http://192.168.1.30:9575",
            displayName: "Office Mac"
        )
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "vampstream.assistant.savedAssistants.v1")
        let model = BeetCodeRemoteSessionViewModel(defaults: defaults)

        model.forget(first)

        XCTAssertEqual(model.savedAssistants, [second])
        let persisted = try XCTUnwrap(defaults.data(forKey: "vampstream.assistant.savedAssistants.v1"))
        XCTAssertEqual(
            try JSONDecoder().decode([BeetCodeRemoteSessionViewModel.SavedAssistant].self, from: persisted),
            [second]
        )
    }

    func testGenericAssistantNamesAreDistinguishedByConnectionKind() {
        let local = BeetCodeRemoteSessionViewModel.SavedAssistant(
            address: "http://192.168.1.7:9575",
            displayName: "Vamp Assistant"
        )
        let tailscale = BeetCodeRemoteSessionViewModel.SavedAssistant(
            address: "http://100.73.221.10:9575",
            displayName: "Vamp Assistant"
        )

        XCTAssertTrue(local.hasGenericDisplayName)
        XCTAssertEqual(local.connectionKind, .localNetwork)
        XCTAssertEqual(tailscale.connectionKind, .tailscale)
    }

    func testCustomAssistantNameIsPreserved() {
        let saved = BeetCodeRemoteSessionViewModel.SavedAssistant(
            address: "http://studio-mac.local:9575",
            displayName: "Studio Mac"
        )

        XCTAssertFalse(saved.hasGenericDisplayName)
        XCTAssertEqual(saved.connectionKind, .localNetwork)
    }

    func testAssistantUnlockStatusOffersEntryOnSecureRoute() throws {
        let data = Data(#"{"enabled":true,"screenRecording":true,"accessibility":true,"ready":false,"locked":true,"remoteUnlockEnabled":true,"remoteUnlockAvailable":true,"remoteUnlockMessage":"Enter the Mac login password.","displays":[]}"#.utf8)

        let status = try JSONDecoder().decode(BeetCodeControlStatus.self, from: data)

        XCTAssertTrue(status.shouldOfferRemoteUnlock)
        XCTAssertEqual(status.remoteUnlockMessage, "Enter the Mac login password.")
    }

    func testLockedAssistantStatusIsReachableEvenThoughControlIsNotReady() throws {
        let data = Data(#"{"enabled":true,"screenRecording":true,"accessibility":true,"ready":false,"locked":true,"remoteUnlockEnabled":true,"remoteUnlockAvailable":true,"displays":[]}"#.utf8)
        let status = try JSONDecoder().decode(BeetCodeControlStatus.self, from: data)

        XCTAssertFalse(status.ready)
        // Availability describes network reachability. A locked Assistant is online and
        // must remain selectable so App Stream can present its authenticated unlock form.
        XCTAssertTrue(status.shouldOfferRemoteUnlock)
        XCTAssertEqual(
            BeetCodeRemoteSessionViewModel.Availability.authenticatedStatus(status),
            .reachable)
    }

    func testAssistantUnlockStatusKeepsEntryHiddenWhenUnavailable() throws {
        let data = Data(#"{"enabled":true,"screenRecording":true,"accessibility":true,"ready":false,"locked":true,"remoteUnlockEnabled":true,"remoteUnlockAvailable":false,"remoteUnlockMessage":"Remote Unlock requires Tailscale.","displays":[]}"#.utf8)

        let status = try JSONDecoder().decode(BeetCodeControlStatus.self, from: data)

        XCTAssertFalse(status.shouldOfferRemoteUnlock)
    }
    func testCancelledPairResponseCannotPublishOrPersistSession() async {
        var resume: CheckedContinuation<BeetCodePairResponse, Error>?
        let started = expectation(description: "Pair request started")
        var statusRequests = 0
        let model = BeetCodeRemoteSessionViewModel(defaults: defaults, pairRequest: { _, _ in
            try await withCheckedThrowingContinuation { continuation in
                resume = continuation
                started.fulfill()
            }
        }, statusRequest: { _ in
            statusRequests += 1
            throw URLError(.badServerResponse)
        })
        let task = Task { await model.pair(address: "http://127.0.0.1:9575", code: "123456") }
        await fulfillment(of: [started], timeout: 2)
        model.cancelConnectionAttempt()
        resume?.resume(returning: BeetCodePairResponse(token: "test-fixture", expiresAt: 0, product: nil))
        await task.value
        XCTAssertFalse(model.isPairing)
        XCTAssertNil(model.session)
        XCTAssertNil(model.lastError)
        XCTAssertTrue(model.savedAssistants.isEmpty)
        XCTAssertEqual(statusRequests, 0)
    }

    func testTaskCancellationDuringStatusCannotPersistOrNavigate() async throws {
        var resume: CheckedContinuation<BeetCodeControlStatus, Error>?
        let started = expectation(description: "Status request started")
        let model = BeetCodeRemoteSessionViewModel(defaults: defaults, pairRequest: { _, _ in
            BeetCodePairResponse(token: "test-fixture", expiresAt: 0, product: nil)
        }, statusRequest: { _ in
            try await withCheckedThrowingContinuation { continuation in
                resume = continuation
                started.fulfill()
            }
        })
        let task = Task { await model.pair(address: "http://127.0.0.1:9575", code: "123456") }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let status = try JSONDecoder().decode(BeetCodeControlStatus.self, from:
            Data(#"{"enabled":true,"screenRecording":true,"accessibility":true,"ready":true}"#.utf8))
        resume?.resume(returning: status)
        await task.value
        XCTAssertNil(model.session)
        XCTAssertNil(model.lastError)
        XCTAssertTrue(model.savedAssistants.isEmpty)
        XCTAssertFalse(model.isPairing)
    }

}
