import SharedModels
import XCTest
@testable import Vamp_Stream

final class VampStreamPairingScanTests: XCTestCase {
    func testHomeScannerRoutesAllAssistantAndCompanionPortsToCodePairing() throws {
        for port in Array(9575...9583) + Array(9675...9683) {
            let scan = try XCTUnwrap(VampStreamPairingScan.parse("http://192.168.1.20:\(port)/?pair=123456"))
            guard case .assistant(let endpoint) = scan else {
                return XCTFail("An HTTP host must not enter Sync's fingerprint pairing flow")
            }
            XCTAssertEqual(endpoint.url.absoluteString, "http://192.168.1.20:\(port)")
            XCTAssertEqual(endpoint.pairingCode, "123456")
        }
    }

    func testHomeScannerPreservesSyncAddressAndFingerprintFlow() throws {
        let payload = try XCTUnwrap(VampHostPairingLink.make(address: "192.168.1.20:9473", displayName: "Studio Mac"))
        XCTAssertEqual(VampStreamPairingScan.parse(payload), .sync(address: "192.168.1.20:9473"))
    }

    func testHomeScannerRecognizesWebsiteTailscaleCompanionQR() throws {
        let scan = try XCTUnwrap(VampStreamPairingScan.parse("http://100.90.80.70:9675/?pair=123456"))
        guard case .assistant(let endpoint) = scan else { return XCTFail("Expected Companion pairing") }
        XCTAssertEqual(endpoint.url.host, "100.90.80.70")
        XCTAssertEqual(endpoint.url.port, 9675)
    }

    func testHomeScannerPreservesTailscaleIPv6AndMagicDNS() throws {
        for host in ["[fd7a:115c:a1e0::1234]", "studio.tailnet-example.ts.net"] {
            let scan = try XCTUnwrap(VampStreamPairingScan.parse("http://\(host):9675/?pair=123456"))
            guard case .assistant(let endpoint) = scan else { return XCTFail("Expected Companion pairing") }
            XCTAssertEqual(endpoint.url.port, 9675)
            XCTAssertEqual(endpoint.pairingCode, "123456")
        }
    }

    func testHomeScannerRejectsUnrelatedMissingAndInvalidPairingCodes() {
        for payload in [
            "not a pairing link",
            "http://192.168.1.20:9675/",
            "http://192.168.1.20:9675/?pair=123",
            "http://192.168.1.20:9475/?pair=123456",
            "http://example.com:9675/?pair=123456",
            "vampstream://pair?name=Studio",
        ] {
            XCTAssertNil(VampStreamPairingScan.parse(payload))
        }
    }
}
