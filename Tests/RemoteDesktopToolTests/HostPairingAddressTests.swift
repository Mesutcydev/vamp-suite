import XCTest
import SharedUtilities
import SharedModels

final class HostPairingAddressTests: XCTestCase {
    func testTailscaleSelectionWinsWhenLANIsAlsoAvailable() throws {
        let address = HostPairingAddress.make(network: .tailscale, localIPv4: "192.168.1.10",
                                             tailscaleIPv4: "100.90.80.10", port: 9471)
        XCTAssertEqual(address, "100.90.80.10:9471")
        let link = VampHostPairingLink.make(address: try XCTUnwrap(address), displayName: "App Sync")
        XCTAssertEqual(link.flatMap(VampHostPairingLink.parse)?.address, address)
    }

    func testLocalSelectionUsesLANAndTailscaleWorksWithoutLAN() {
        XCTAssertEqual(HostPairingAddress.make(network: .localWiFi, localIPv4: "192.168.1.10",
                                               tailscaleIPv4: "100.90.80.10", port: 9471), "192.168.1.10:9471")
        XCTAssertEqual(HostPairingAddress.make(network: .tailscale, localIPv4: nil,
                                               tailscaleIPv4: "100.90.80.10", port: 9471), "100.90.80.10:9471")
    }

    func testMissingTailscaleNeverSilentlyReturnsLAN() {
        XCTAssertNil(HostPairingAddress.make(network: .tailscale, localIPv4: "192.168.1.10",
                                            tailscaleIPv4: nil, port: 9471))
        XCTAssertNil(HostPairingAddress.make(network: .localWiFi, localIPv4: nil,
                                            tailscaleIPv4: "100.90.80.10", port: 9471))
    }

    func testOnlyValidNumericTailnetIPv4IsAdvertised() {
        for address in ["8.8.8.8", "100.63.1.2", "100.128.1.2", "100.90.999.10",
                        "mac.example.ts.net", "fd7a:115c:a1e0::1", "100.90.80.10:9471", "100.90.80.10\n"] {
            XCTAssertNil(HostPairingAddress.make(network: .tailscale, localIPv4: nil,
                                                tailscaleIPv4: address, port: 9471))
        }
    }

}
