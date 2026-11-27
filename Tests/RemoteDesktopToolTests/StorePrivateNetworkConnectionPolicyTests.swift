import XCTest
import SharedUtilities

final class StorePrivateNetworkConnectionPolicyTests: XCTestCase {
    private typealias Policy = StorePrivateNetworkConnectionPolicy
    private let lan = Policy.NetworkInterface(name: "en0", address: [192, 168, 1, 8], netmask: [255, 255, 255, 0], isUp: true)
    private let tunnel = Policy.NetworkInterface(name: "utun4", address: [100, 90, 80, 1], isUp: true)

    func testStoreStreamStillRequiresNetworkValidation() {
        XCTAssertTrue(Policy.requiresPrivateNetwork(bundleIdentifier: "com.mesutcy.remotedesktop.stream", distributionChannel: "app-store"))
        XCTAssertFalse(Policy.requiresPrivateNetwork(bundleIdentifier: "com.mesutcy.remotedesktop.stream", distributionChannel: "website"))
        XCTAssertFalse(Policy.requiresPrivateNetwork(bundleIdentifier: "com.mesutcy.remotedesktop.ios", distributionChannel: "app-store"))
    }

    func testTailscalePeerWorksWithoutPhysicalLAN() {
        XCTAssertTrue(Policy.permits(address: [100, 90, 80, 2], interfaces: [tunnel]))
        XCTAssertTrue(Policy.permits(address: [100, 90, 80, 2], interfaces: [lan, tunnel]))
        XCTAssertFalse(Policy.permits(address: [100, 90, 80, 2], interfaces: [lan]))
    }

    func testInactiveOrUnrelatedVPNCannotAuthorizeTailscalePeer() {
        let inactive = Policy.NetworkInterface(name: "utun4", address: [100, 90, 80, 1], isUp: false)
        let unrelated = Policy.NetworkInterface(name: "utun4", address: [10, 9, 8, 7], isUp: true)
        let cellular = Policy.NetworkInterface(name: "pdp_ip0", address: [100, 90, 80, 1], isUp: true)
        XCTAssertFalse(Policy.permits(address: [100, 90, 80, 2], interfaces: [inactive]))
        XCTAssertFalse(Policy.permits(address: [100, 90, 80, 2], interfaces: [unrelated]))
        XCTAssertFalse(Policy.permits(address: [100, 90, 80, 2], interfaces: [cellular]))
    }

    func testPublicLoopbackAndUnrelatedPrivatePeersRemainBlocked() {
        for address: [UInt8] in [[8, 8, 8, 8], [100, 63, 255, 255], [100, 128, 0, 1], [127, 0, 0, 1], [192, 168, 2, 9]] {
            XCTAssertFalse(Policy.permits(address: address, interfaces: [lan, tunnel]))
        }
    }

    func testLANRequiresActivePhysicalInterface() {
        XCTAssertTrue(Policy.permits(address: [192, 168, 1, 9], interfaces: [lan]))
        let vpn = Policy.NetworkInterface(name: "utun8", address: lan.address, netmask: lan.netmask, isUp: true)
        let down = Policy.NetworkInterface(name: "en0", address: lan.address, netmask: lan.netmask, isUp: false)
        XCTAssertFalse(Policy.permits(address: [192, 168, 1, 9], interfaces: [vpn, down]))
    }

    func testTailscaleIPv4AndIPv6Boundaries() {
        XCTAssertTrue(Policy.isTailscaleHost("100.64.0.1"))
        XCTAssertTrue(Policy.isTailscaleHost("100.127.255.254"))
        XCTAssertFalse(Policy.isTailscaleHost("100.63.255.255"))
        XCTAssertFalse(Policy.isTailscaleHost("100.128.0.1"))
        XCTAssertTrue(Policy.isTailscaleHost("fd7a:115c:a1e0::1234"))
        XCTAssertTrue(Policy.isTailscaleHost("[FD7A:115C:A1E0::1234]"))
        XCTAssertFalse(Policy.isTailscaleHost("fd7a:115c:a1e1::1234"))
        XCTAssertFalse(Policy.isTailscaleHost("mac.ts.net")) // DNS must be resolved and checked.
    }

    func testIPv6TailnetPeerUsesActiveTunnel() {
        let peer: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] + [UInt8](repeating: 0, count: 9) + [2]
        var own = peer
        own[15] = 1
        let ipv6Tunnel = Policy.NetworkInterface(name: "utun4", address: own, isUp: true)
        XCTAssertTrue(Policy.permits(address: peer, interfaces: [ipv6Tunnel]))
        XCTAssertFalse(Policy.permits(address: peer, interfaces: [lan]))
        XCTAssertFalse(Policy.permits(address: own, interfaces: [ipv6Tunnel, tunnel]))
        XCTAssertFalse(Policy.permits(address: tunnel.address, interfaces: [ipv6Tunnel, tunnel]))
    }

    func testDualStackHostnamePrefersAllowedIPv4AndRetainsIPv6Fallback() {
        let ipv6: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] + [UInt8](repeating: 0, count: 9) + [2]
        let ipv4: [UInt8] = [100, 90, 80, 2]
        XCTAssertEqual(Policy.preferredAddress(from: [ipv6, ipv4], interfaces: [tunnel]), ipv4)
        XCTAssertEqual(Policy.preferredAddress(from: [ipv6], interfaces: [tunnel]), ipv6)
        XCTAssertEqual(Policy.preferredAddress(from: [[8, 8, 8, 8], ipv6], interfaces: [tunnel]), ipv6)
        XCTAssertNil(Policy.preferredAddress(from: [ipv4], interfaces: [lan]))
    }

    func testPhysicalLANSubnetAllowsNeighborButRejectsDifferentNetwork() {
        let local: [UInt8] = [192, 168, 1, 8]
        let mask: [UInt8] = [255, 255, 255, 0]
        XCTAssertTrue(StorePrivateNetworkConnectionPolicy.isOnSubnet(address: [192, 168, 1, 9], localAddress: local, netmask: mask))
        XCTAssertFalse(StorePrivateNetworkConnectionPolicy.isOnSubnet(address: [192, 168, 2, 9], localAddress: local, netmask: mask))
        XCTAssertFalse(StorePrivateNetworkConnectionPolicy.isOnSubnet(address: local, localAddress: local, netmask: mask))
        XCTAssertFalse(StorePrivateNetworkConnectionPolicy.isOnSubnet(address: [192, 168, 1, 255], localAddress: local, netmask: mask))
    }

    func testPrivateVPNAndLoopbackAreNotLANHosts() {
        XCTAssertFalse(StorePrivateNetworkConnectionPolicy.isOnSubnet(
            address: [100, 64, 0, 2], localAddress: [100, 64, 0, 1], netmask: [255, 192, 0, 0]))
        XCTAssertFalse(StorePrivateNetworkConnectionPolicy.isOnSubnet(
            address: [127, 0, 0, 2], localAddress: [127, 0, 0, 1], netmask: [255, 0, 0, 0]))
        XCTAssertFalse(StorePrivateNetworkConnectionPolicy.isOnSubnet(
            address: [224, 0, 0, 2], localAddress: [224, 0, 0, 1], netmask: [255, 0, 0, 0]))
    }

    func testIPv6SubnetAndInvalidMasks() {
        let local: [UInt8] = [0xfd, 1, 2, 3, 4, 5, 6, 7, 0, 0, 0, 0, 0, 0, 0, 1]
        var neighbor = local
        neighbor[15] = 2
        let mask = [UInt8](repeating: 255, count: 8) + [UInt8](repeating: 0, count: 8)
        XCTAssertTrue(StorePrivateNetworkConnectionPolicy.isOnSubnet(address: neighbor, localAddress: local, netmask: mask))
        neighbor[7] = 9
        XCTAssertFalse(StorePrivateNetworkConnectionPolicy.isOnSubnet(address: neighbor, localAddress: local, netmask: mask))
        XCTAssertFalse(StorePrivateNetworkConnectionPolicy.isOnSubnet(address: neighbor, localAddress: local, netmask: []))
        XCTAssertFalse(StorePrivateNetworkConnectionPolicy.isOnSubnet(
            address: neighbor, localAddress: local, netmask: [UInt8](repeating: 0, count: 16)))
    }
}
