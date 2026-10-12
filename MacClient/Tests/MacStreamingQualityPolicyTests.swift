import SharedModels
import XCTest

final class MacStreamingQualityPolicyTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "MacStreamingQualityPolicyTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    func testPromotesStaleBalancedInstallOnce() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            MacStreamingQualityPolicy.promotedPreset(
                current: .balanced,
                supportsUltra: true,
                defaults: defaults
            ),
            .quality
        )
        // Second launch must leave the (possibly user-lowered) preference alone.
        XCTAssertNil(
            MacStreamingQualityPolicy.promotedPreset(
                current: .balanced,
                supportsUltra: true,
                defaults: defaults
            )
        )
    }

    func testNeverLowersADeliberatelyHigherPreset() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(
            MacStreamingQualityPolicy.promotedPreset(
                current: .ultra,
                supportsUltra: true,
                defaults: defaults
            )
        )
    }

    func testLeavesQualityAloneWhenItIsAlreadyTheRecommendation() {
        XCTAssertEqual(
            MacStreamingQualityPolicy.preferredPreset(current: .performance, supportsUltra: true),
            .quality
        )
        XCTAssertEqual(
            MacStreamingQualityPolicy.preferredPreset(current: .quality, supportsUltra: true),
            .quality
        )
    }
}
