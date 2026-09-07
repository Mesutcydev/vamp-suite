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

/// A host session whose data channel never opened used to be immortal: the liveness watchdog
/// required a non-nil last-activity stamp, so a half-open transport that still reported
/// `.connected` kept capture/encode running for nobody — and `activeSessionID` made the host
/// reject every real client as "already connected to another device". Vamp Stream could then
/// never re-attach to Vamp Sync until the host process was quit.
final class HostLivenessWatchdogTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let timeout: TimeInterval = 30

    private func silence(
        phase: HostSessionCoordinator.SessionPhase = .streaming,
        connectionState: ConnectionState = .connected,
        lastActivity: Date?,
        now: TimeInterval
    ) -> TimeInterval? {
        HostClientLiveness.clientSilence(
            isStreaming: phase == .streaming,
            isConnected: connectionState == .connected,
            lastActivity: lastActivity,
            sessionStartedAt: start,
            now: start.addingTimeInterval(now),
            timeout: timeout)
    }

    /// The regression itself: no traffic at all, transport claiming connected, well past the
    /// timeout. Must be reclaimed rather than skipped.
    func testSilentSessionWithNoTrafficIsReclaimed() {
        XCTAssertNotNil(silence(lastActivity: nil, now: 31),
            "a session that never received a data-channel message must time out")
        XCTAssertNotNil(silence(lastActivity: nil, now: 600),
            "an idle phantom session must not survive indefinitely")
    }

    /// Within the timeout the session is still healthy — including before the first ping lands.
    func testFreshSessionIsNotReclaimed() {
        XCTAssertNil(silence(lastActivity: nil, now: 0))
        XCTAssertNil(silence(lastActivity: nil, now: 29))
        XCTAssertNil(silence(lastActivity: nil, now: 30))
    }

    /// The client pings every 2 s, so real activity keeps resetting the clock.
    func testActiveSessionIsNotReclaimed() {
        let pinged = start.addingTimeInterval(100)
        XCTAssertNil(silence(lastActivity: pinged, now: 102))
        XCTAssertNil(silence(lastActivity: pinged, now: 129))
        XCTAssertNotNil(silence(lastActivity: pinged, now: 131),
            "traffic that stopped must eventually be reclaimed too")
    }

    /// The watchdog only governs a live streaming session on a connected transport. Teardown and
    /// reconnection are driven by the connection observer and the disconnect-grace timer instead,
    /// so this rule must stay out of their way.
    func testWatchdogStaysOutOfOtherStates() {
        for phase: HostSessionCoordinator.SessionPhase in [.idle, .awaitingClient, .negotiating, .pipelineStarting] {
            XCTAssertNil(silence(phase: phase, lastActivity: nil, now: 600), "\(phase)")
        }
        for state: ConnectionState in [.idle, .connecting, .disconnected, .failed, .reconnecting] {
            XCTAssertNil(silence(connectionState: state, lastActivity: nil, now: 600), "\(state)")
        }
    }

    /// A stale stamp from a *previous* session must not be treated as current activity. The
    /// coordinator resets `lastClientActivityAt` at session start and the watchdog baselines on
    /// the session start date, so silence is always measured against this session.
    func testStaleActivityStampCannotKeepASessionAlive() {
        let previousSession = start.addingTimeInterval(-3_600)
        XCTAssertNotNil(silence(lastActivity: previousSession, now: 10),
            "activity from an hour ago is silence, not liveness")
    }
}

