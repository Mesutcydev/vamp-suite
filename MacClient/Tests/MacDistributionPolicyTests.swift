import XCTest

final class MacDistributionPolicyTests: XCTestCase {
    func testTailnetDestinationsAreDetected() {
        XCTAssertTrue(MacDistributionPolicy.isTailnetDestination("100.101.102.103"))
        XCTAssertTrue(MacDistributionPolicy.isTailnetDestination("mac.tailnet.ts.net"))
        XCTAssertTrue(MacDistributionPolicy.isTailnetDestination("fd7a:115c:a1e0::1"))
    }

    func testLANDestinationsAreNotTailnet() {
        XCTAssertFalse(MacDistributionPolicy.isTailnetDestination("192.168.1.20"))
        XCTAssertFalse(MacDistributionPolicy.isTailnetDestination("100.20.1.1"))
        XCTAssertFalse(MacDistributionPolicy.isTailnetDestination("mac.local"))
    }
}
