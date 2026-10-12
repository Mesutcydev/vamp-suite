import SharedUtilities
import XCTest

final class MacConnectionPreferencesTests: XCTestCase {
    func testMigrationIsolationAndPersistence() {
        let suite = "MacConnectionPreferencesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(DisplayMappingEngine.DisplayMode.fillScreen.rawValue, forKey: "client.displayMode")
        let store = MacConnectionPreferenceStore(defaults: defaults)
        var a = store.load(for: "fp:first")
        XCTAssertEqual(a.displayModeRaw, DisplayMappingEngine.DisplayMode.fillScreen.rawValue)
        a.displayModeRaw = DisplayMappingEngine.DisplayMode.actualSize.rawValue
        a.keepsDisplayShortcutsLocal = false
        a.quickActionID = "screenshot"
        store.save(a, for: "fp:first")
        XCTAssertEqual(MacConnectionPreferenceStore(defaults: defaults).load(for: "fp:first"), a)
        let b = store.load(for: "fp:second")
        XCTAssertEqual(b.displayModeRaw, DisplayMappingEngine.DisplayMode.fillScreen.rawValue)
        XCTAssertTrue(b.keepsDisplayShortcutsLocal)
        XCTAssertEqual(b.quickActionID, "none")
    }

    func testMalformedStorageAndUnknownModeFallBackToFit() {
        let suite = "MacConnectionPreferencesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacConnectionPreferenceStore(defaults: defaults)
        defaults.set(Data("bad".utf8), forKey: "vampcontrol.connection.preferences.host")
        XCTAssertEqual(store.load(for: "host"), MacConnectionPreferences())
        var invalid = MacConnectionPreferences()
        invalid.displayModeRaw = "future-mode"
        store.save(invalid, for: "host")
        XCTAssertEqual(store.load(for: "host").displayModeRaw, DisplayMappingEngine.DisplayMode.fitDisplay.rawValue)
    }

    func testAssistantIdentityIgnoresPathAndCredentialsButSeparatesPorts() {
        XCTAssertEqual(MacConnectionPreferenceStore.assistantKey(address: "http://MAC.local:9575/"),
                       MacConnectionPreferenceStore.assistantKey(address: "http://mac.local:9575/path?token=test"))
        XCTAssertNotEqual(MacConnectionPreferenceStore.assistantKey(address: "http://mac.local:9575"),
                          MacConnectionPreferenceStore.assistantKey(address: "http://mac.local:9576"))
    }
}
