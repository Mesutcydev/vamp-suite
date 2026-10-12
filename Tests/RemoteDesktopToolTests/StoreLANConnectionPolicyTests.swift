import XCTest
import SharedUtilities

final class StoreLANConnectionPolicyTests: XCTestCase {
    func testPhysicalLANSubnetAllowsNeighborButRejectsDifferentNetwork() {
        let local: [UInt8] = [192, 168, 1, 8]
        let mask: [UInt8] = [255, 255, 255, 0]
        XCTAssertTrue(StoreLANConnectionPolicy.isOnSubnet(address: [192, 168, 1, 9], localAddress: local, netmask: mask))
        XCTAssertFalse(StoreLANConnectionPolicy.isOnSubnet(address: [192, 168, 2, 9], localAddress: local, netmask: mask))
        XCTAssertFalse(StoreLANConnectionPolicy.isOnSubnet(address: local, localAddress: local, netmask: mask))
        XCTAssertFalse(StoreLANConnectionPolicy.isOnSubnet(address: [192, 168, 1, 255], localAddress: local, netmask: mask))
    }

    func testPrivateVPNAndLoopbackAreNotLANHosts() {
        XCTAssertFalse(StoreLANConnectionPolicy.isOnSubnet(
            address: [100, 64, 0, 2], localAddress: [100, 64, 0, 1], netmask: [255, 192, 0, 0]))
        XCTAssertFalse(StoreLANConnectionPolicy.isOnSubnet(
            address: [127, 0, 0, 2], localAddress: [127, 0, 0, 1], netmask: [255, 0, 0, 0]))
        XCTAssertFalse(StoreLANConnectionPolicy.isOnSubnet(
            address: [224, 0, 0, 2], localAddress: [224, 0, 0, 1], netmask: [255, 0, 0, 0]))
    }

    func testIPv6SubnetAndInvalidMasks() {
        let local: [UInt8] = [0xfd, 1, 2, 3, 4, 5, 6, 7, 0, 0, 0, 0, 0, 0, 0, 1]
        var neighbor = local
        neighbor[15] = 2
        let mask = [UInt8](repeating: 255, count: 8) + [UInt8](repeating: 0, count: 8)
        XCTAssertTrue(StoreLANConnectionPolicy.isOnSubnet(address: neighbor, localAddress: local, netmask: mask))
        neighbor[7] = 9
        XCTAssertFalse(StoreLANConnectionPolicy.isOnSubnet(address: neighbor, localAddress: local, netmask: mask))
        XCTAssertFalse(StoreLANConnectionPolicy.isOnSubnet(address: neighbor, localAddress: local, netmask: []))
        XCTAssertFalse(StoreLANConnectionPolicy.isOnSubnet(
            address: neighbor, localAddress: local, netmask: [UInt8](repeating: 0, count: 16)))
    }
}
