import XCTest

final class ClientFileTransferPreferenceTests: XCTestCase {
    func testPreferenceDefaultsToEnabledAndCanBeDisabled() throws {
        let suiteName = "ClientFileTransferPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(ClientFileTransferPreference.isEnabled(in: defaults))

        ClientFileTransferPreference.setEnabled(false, in: defaults)
        XCTAssertFalse(ClientFileTransferPreference.isEnabled(in: defaults))

        ClientFileTransferPreference.setEnabled(true, in: defaults)
        XCTAssertTrue(ClientFileTransferPreference.isEnabled(in: defaults))
    }

    func testMigratesExistingMacOptOutBeforeReadingTheNewPreference() throws {
        let suiteName = "ClientFileTransferPreferenceMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: ClientFileTransferPreference.legacyMacStorageKey)

        XCTAssertFalse(ClientFileTransferPreference.isEnabled(in: defaults))
        XCTAssertEqual(defaults.object(forKey: ClientFileTransferPreference.storageKey) as? Bool, false)
    }

    func testMigratesAnExistingManagerOptOutWhenThereIsNoMacSetting() throws {
        let suiteName = "ClientFileTransferManagerPreferenceMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "com.mesutcy.remotedesktop.terminal.filetransfer.enabled")

        XCTAssertFalse(ClientFileTransferPreference.isEnabled(in: defaults))
        XCTAssertEqual(defaults.object(forKey: ClientFileTransferPreference.storageKey) as? Bool, false)
    }
}
