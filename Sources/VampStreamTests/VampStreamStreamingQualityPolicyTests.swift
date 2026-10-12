import SharedModels
import XCTest
@testable import Vamp_Stream

final class VampStreamStreamingQualityPolicyTests: XCTestCase {
    func testPromotesCapableDeviceToNativeUltraPreset() {
        XCTAssertEqual(
            VampStreamStreamingQualityPolicy.preferredPreset(
                current: .balanced,
                supportsUltra: true
            ),
            .ultra
        )
    }

    func testPromotesOlderDeviceToQualityWithoutForcingUltra() {
        XCTAssertEqual(
            VampStreamStreamingQualityPolicy.preferredPreset(
                current: .performance,
                supportsUltra: false
            ),
            .quality
        )
    }

    func testAssistantResolutionMigrationUpgradesHistoricalDefaultOnce() {
        let suiteName = "VampStreamResolutionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("1080p", forKey: VampStreamStreamingQualityPolicy.assistantResolutionKey)

        VampStreamStreamingQualityPolicy.migrateAssistantResolution(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: VampStreamStreamingQualityPolicy.assistantResolutionKey),
            "native"
        )
        XCTAssertTrue(defaults.bool(forKey: VampStreamStreamingQualityPolicy.assistantNativeMigrationKey))

        defaults.set("720p", forKey: VampStreamStreamingQualityPolicy.assistantResolutionKey)
        VampStreamStreamingQualityPolicy.migrateAssistantResolution(defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: VampStreamStreamingQualityPolicy.assistantResolutionKey),
            "720p"
        )
    }

    func testAssistantResolutionMigrationPreservesExplicitLowerChoice() {
        let suiteName = "VampStreamResolutionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("480p", forKey: VampStreamStreamingQualityPolicy.assistantResolutionKey)

        VampStreamStreamingQualityPolicy.migrateAssistantResolution(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: VampStreamStreamingQualityPolicy.assistantResolutionKey),
            "480p"
        )
    }
}
