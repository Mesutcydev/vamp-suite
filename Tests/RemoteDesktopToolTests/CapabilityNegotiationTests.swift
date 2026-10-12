import XCTest
@testable import SharedModels
@testable import SharedProtocol

final class CapabilityNegotiationTests: XCTestCase {
    func testCursorlessCaptureRequiresBothPeers() {
        let host: HostCapabilityFlags = [.supportsH264, .supportsCursorlessCapture]
        let macClient = HostCapabilityFlags.currentClient(isMacClient: true)
        let iOSClient = HostCapabilityFlags.currentClient(isMacClient: false)

        // Every client in this stack draws a local cursor overlay (LocalCursorOverlay),
        // so all of them advertise cursorless capture — hover feedback is zero-latency
        // on the phone, not just on the Mac client.
        XCTAssertTrue(CapabilityNegotiator.negotiate(host: host, client: macClient)?.supportsCursorlessCapture == true)
        XCTAssertTrue(CapabilityNegotiator.negotiate(host: host, client: iOSClient)?.supportsCursorlessCapture == true)
        XCTAssertFalse(CapabilityNegotiator.negotiate(host: [.supportsH264], client: macClient)?.supportsCursorlessCapture == true)
        XCTAssertEqual(
            HostCapabilityFlags(stableNames: host.stableNames),
            host
        )
    }

    func testNegotiationPrefersHEVCWhenBothPeersSupportIt() {
        let host: HostCapabilityFlags = [.supportsHEVC, .supportsH264, .supportsMultiDisplay]
        let client: HostCapabilityFlags = [.supportsHEVC, .supportsH264, .supportsMultiDisplay]

        let result = CapabilityNegotiator.negotiate(host: host, client: client)

        XCTAssertEqual(result?.videoCodec, .hevc)
        XCTAssertEqual(result?.supportsMultiDisplay, true)
    }

    func testNegotiationFallsBackToH264() {
        let host: HostCapabilityFlags = [.supportsHEVC, .supportsH264]
        let client: HostCapabilityFlags = [.supportsH264]

        let result = CapabilityNegotiator.negotiate(host: host, client: client)

        XCTAssertEqual(result?.videoCodec, .h264)
    }

    func testNegotiationFailsWithoutCommonCodec() {
        let host: HostCapabilityFlags = [.supportsHEVC]
        let client: HostCapabilityFlags = [.supportsH264]

        XCTAssertNil(CapabilityNegotiator.negotiate(host: host, client: client))
    }

    func testNegotiationIncludesTerminalCapabilities() {
        let host: HostCapabilityFlags = [
            .supportsH264,
            .supportsTerminal,
            .supportsMultipleTerminals,
            .supportsTerminalChat,
            .supportsTaskPlans,
            .supportsWorkspaces
        ]
        let client: HostCapabilityFlags = [
            .supportsH264,
            .supportsTerminal,
            .supportsMultipleTerminals,
            .supportsTerminalChat,
            .supportsTaskPlans,
            .supportsWorkspaces
        ]

        let result = CapabilityNegotiator.negotiate(host: host, client: client)

        XCTAssertEqual(result?.supportsTerminal, true)
        XCTAssertEqual(result?.supportsMultipleTerminals, true)
        XCTAssertEqual(result?.supportsTerminalChat, true)
        XCTAssertEqual(result?.supportsTaskPlans, true)
        XCTAssertEqual(result?.supportsWorkspaces, true)
    }
}
