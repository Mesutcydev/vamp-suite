import SharedModels
import SharedProtocol
import XCTest
@testable import HostApp

/// Vamp Control has to tell a "share one app window" host apart from a "share
/// the whole desktop" host purely from the negotiated capabilities, because the
/// two need completely different session UI. Pin that against the capabilities
/// the host products actually advertise.
final class AppStreamingOnlyHostTests: XCTestCase {
    private func negotiate(_ mode: HostProductMode) -> NegotiatedCapabilities? {
        CapabilityNegotiator.negotiate(
            host: mode.advertisedCapabilities,
            client: .currentClient(isMacClient: true)
        )
    }

    func testVampSyncNegotiatesAsAppStreamingOnly() throws {
        let negotiated = try XCTUnwrap(negotiate(.mini))
        XCTAssertTrue(negotiated.supportsAppStreaming)
        XCTAssertTrue(negotiated.isAppStreamingOnly)
    }

    func testNewMacControlStartsOnDesktopWithoutAddingTerminalOrAudio() throws {
        let client = HostCapabilityFlags.currentClient(isMacClient: true)
        let host = HostProductMode.mini.sessionCapabilities(for: client)
        let negotiated = try XCTUnwrap(CapabilityNegotiator.negotiate(host: host, client: client))
        XCTAssertFalse(HostProductMode.mini.startsWithAppBrowser(for: client))
        XCTAssertFalse(negotiated.isAppStreamingOnly)
        XCTAssertTrue(negotiated.supportsMultiDisplay)
        XCTAssertTrue(negotiated.supportsAppStreaming)
        XCTAssertFalse(negotiated.supportsTerminal)
        XCTAssertFalse(negotiated.supportsAudio)
    }

    func testStreamAndOldMacClientsStillStartWithApps() throws {
        var oldMac = HostCapabilityFlags.currentClient(isMacClient: true)
        oldMac.remove(.supportsDesktopControl)
        for client in [HostCapabilityFlags.currentClient(isMacClient: false), oldMac] {
            let host = HostProductMode.mini.sessionCapabilities(for: client)
            let negotiated = try XCTUnwrap(CapabilityNegotiator.negotiate(host: host, client: client))
            XCTAssertTrue(HostProductMode.mini.startsWithAppBrowser(for: client))
            XCTAssertTrue(negotiated.isAppStreamingOnly)
        }
    }

    func testDesktopFlagAloneDoesNotEnableDesktopAndRoundTripsDiscovery() {
        let flags: HostCapabilityFlags = [.supportsDesktopControl, .supportsH264]
        XCTAssertTrue(HostProductMode.mini.startsWithAppBrowser(for: flags))
        XCTAssertEqual(HostCapabilityFlags(stableNames: flags.stableNames), flags)
        XCTAssertFalse(HostProductMode.terminalOnly.sessionCapabilities(for: .currentClient(isMacClient: true)).contains(.supportsDesktopControl))
    }

    func testVampHostIsNotAppStreamingOnly() throws {
        let negotiated = try XCTUnwrap(negotiate(.full))
        // The full host also offers App Streaming, but it has a display stream —
        // it must keep the normal remote-desktop surface.
        XCTAssertTrue(negotiated.supportsMultiDisplay)
        XCTAssertFalse(negotiated.isAppStreamingOnly)
    }

    func testTerminalHostIsNotAppStreamingOnly() throws {
        let negotiated = try XCTUnwrap(negotiate(.terminalOnly))
        XCTAssertFalse(negotiated.isAppStreamingOnly)
    }

    func testMacClientKeepsItsMacCapabilityAgainstTheFullHost() throws {
        let negotiated = try XCTUnwrap(negotiate(.full))
        XCTAssertTrue(negotiated.supportsMacClient)
    }
}
