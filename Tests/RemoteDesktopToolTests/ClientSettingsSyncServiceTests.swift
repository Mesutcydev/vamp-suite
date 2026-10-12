import XCTest
@testable import ClientiOS
@testable import SharedModels

final class ClientSettingsSyncServiceTests: XCTestCase {
    func testLocalFallbackPersistsNonSensitiveSettings() {
        let suiteName = "ClientSettingsSyncServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let service = ClientSettingsSyncService(defaults: defaults, cloudStore: nil)

        let settings = SessionFeatureSettings(
            preferredQualityPreset: .quality,
            showsStatsOverlay: true,
            lowPowerModeEnabled: true,
            prefersViewOnly: true
        )
        service.save(settings)

        XCTAssertEqual(service.load(), settings)
    }

    func testLoadUsesLocalSettingsBeforeCloudFallback() {
        let suiteName = "ClientSettingsSyncServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let service = ClientSettingsSyncService(defaults: defaults, cloudStore: nil)

        service.save(SessionFeatureSettings(preferredQualityPreset: .performance))
        XCTAssertEqual(service.load().preferredQualityPreset, .performance)
    }
}
