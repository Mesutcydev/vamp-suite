import XCTest
@testable import ClientiOS
import SharedModels

final class ClientVideoDynamicRangePolicyTests: XCTestCase {
    func testUltraRemainsSDRUnlessHDRIsExplicitlyEnabled() {
        let preferred = ClientVideoDynamicRangePolicy.preferredDynamicRange(
            qualityPreset: .ultra,
            clientCapabilities: [.supportsHDR10],
            hdrExplicitlyEnabled: false
        )

        XCTAssertNil(preferred)
    }

    func testExplicitHDRUsesHDR10WhenUltraAndSupported() {
        let preferred = ClientVideoDynamicRangePolicy.preferredDynamicRange(
            qualityPreset: .ultra,
            clientCapabilities: [.supportsHDR10],
            hdrExplicitlyEnabled: true
        )

        XCTAssertEqual(preferred, .hdr10)
    }

    func testExplicitHDRFallsBackToSDRWhenUnsupported() {
        let preferred = ClientVideoDynamicRangePolicy.preferredDynamicRange(
            qualityPreset: .ultra,
            clientCapabilities: [],
            hdrExplicitlyEnabled: true
        )

        XCTAssertNil(preferred)
    }

    func testExplicitHDRDoesNotChangeNonUltraPresets() {
        let preferred = ClientVideoDynamicRangePolicy.preferredDynamicRange(
            qualityPreset: .quality,
            clientCapabilities: [.supportsHDR10],
            hdrExplicitlyEnabled: true
        )

        XCTAssertNil(preferred)
    }
}
