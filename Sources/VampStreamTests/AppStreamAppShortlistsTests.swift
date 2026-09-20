import XCTest
@testable import Vamp_Stream

/// Favourites and recents are now shared by both app browsers, so the list arithmetic is the
/// one piece of logic a bug in either browser would show up in.
final class AppStreamAppShortlistsTests: XCTestCase {

    // MARK: - Encoding

    func testDecodeRejectsGarbageInsteadOfCrashing() {
        XCTAssertEqual(AppStreamAppShortlists.decode("not json"), [])
        XCTAssertEqual(AppStreamAppShortlists.decode(""), [])
        XCTAssertEqual(AppStreamAppShortlists.decode("[]"), [])
    }

    func testRoundTripPreservesOrder() {
        let ids = ["com.apple.Safari", "com.apple.Terminal", "com.apple.Notes"]
        XCTAssertEqual(AppStreamAppShortlists.decode(AppStreamAppShortlists.encode(ids)), ids)
    }

    // MARK: - Favourites

    func testToggleAddsWhenAbsent() {
        let after = AppStreamAppShortlists.toggled("com.apple.Safari", in: "[]")
        XCTAssertEqual(AppStreamAppShortlists.decode(after), ["com.apple.Safari"])
    }

    func testToggleRemovesWhenPresentAndKeepsTheRest() {
        let start = AppStreamAppShortlists.encode(["a", "b", "c"])
        let after = AppStreamAppShortlists.toggled("b", in: start)
        XCTAssertEqual(AppStreamAppShortlists.decode(after), ["a", "c"])
    }

    func testToggleTwiceIsANoOp() {
        let start = AppStreamAppShortlists.encode(["a", "b"])
        let once = AppStreamAppShortlists.toggled("b", in: start)
        let twice = AppStreamAppShortlists.toggled("b", in: once)
        XCTAssertEqual(AppStreamAppShortlists.decode(twice), ["a", "b"])
    }

    // MARK: - Recents

    func testPromoteMovesToFrontWithoutDuplicating() {
        let start = AppStreamAppShortlists.encode(["a", "b", "c"])
        let after = AppStreamAppShortlists.promoting("c", in: start)
        XCTAssertEqual(AppStreamAppShortlists.decode(after), ["c", "a", "b"])
    }

    func testPromoteAddsNewEntryAtFront() {
        let start = AppStreamAppShortlists.encode(["a"])
        let after = AppStreamAppShortlists.promoting("z", in: start)
        XCTAssertEqual(AppStreamAppShortlists.decode(after), ["z", "a"])
    }

    /// Without the cap, "Recent" slowly becomes a second, worse copy of All Apps.
    func testPromoteTrimsToTheLimitDroppingTheOldest() {
        let existing = (1...AppStreamAppShortlists.recentLimit).map { "app\($0)" }
        let after = AppStreamAppShortlists.promoting("new", in: AppStreamAppShortlists.encode(existing))
        let ids = AppStreamAppShortlists.decode(after)

        XCTAssertEqual(ids.count, AppStreamAppShortlists.recentLimit)
        XCTAssertEqual(ids.first, "new")
        XCTAssertFalse(ids.contains("app\(AppStreamAppShortlists.recentLimit)"), "oldest entry should be dropped")
    }

    func testPromotingAnExistingEntryDoesNotGrowTheList() {
        let existing = (1...AppStreamAppShortlists.recentLimit).map { "app\($0)" }
        let after = AppStreamAppShortlists.promoting("app5", in: AppStreamAppShortlists.encode(existing))
        let ids = AppStreamAppShortlists.decode(after)

        XCTAssertEqual(ids.count, AppStreamAppShortlists.recentLimit)
        XCTAssertEqual(ids.first, "app5")
        XCTAssertEqual(Set(ids).count, ids.count, "no duplicates")
    }

    /// Both browsers key on the bundle identifier, which is what lets a favourite follow the
    /// user from a Vamp Sync Mac to a Vamp Assistant one.
    func testStorageKeysAreTheOnesTheSyncBrowserAlreadyWrote() {
        XCTAssertEqual(AppStreamAppShortlists.favoritesKey, "vampstream.favoriteApps")
        XCTAssertEqual(AppStreamAppShortlists.recentsKey, "vampstream.recentApps")
    }
}
