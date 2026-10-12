import CoreVideo
import XCTest
@testable import CaptureEngine

final class ColorPipelineTests: XCTestCase {
    func testSDRCaptureUsesFullRangeSurface() {
        let config = CaptureConfiguration.forPreset(
            .balanced,
            displayWidth: 1920,
            displayHeight: 1080,
            scaleFactor: 1,
            allowsHighResolution: false
        )

        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }
}
