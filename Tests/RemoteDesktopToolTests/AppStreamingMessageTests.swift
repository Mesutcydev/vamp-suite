import XCTest
@testable import TransportWebRTC
@testable import SharedModels
@testable import SharedProtocol
import InputControl

final class AppStreamingMessageTests: XCTestCase {

    func testRequestCorrelationAndLegacyCompatibility() throws {
        let id = UUID()
        let request = StreamTargetSwitchRequestMessage(sessionID: UUID(), target: .window("42"), senderDeviceID: UUID(), requestID: id)
        let decoded = try DataChannelEnvelope.streamTargetSwitch(request).decodeStreamTargetSwitchRequest()
        XCTAssertEqual(decoded.requestID, id)
        let legacy = StreamTargetSwitchRequestMessage(sessionID: UUID(), target: .window("42"), senderDeviceID: UUID())
        XCTAssertNil(try DataChannelEnvelope.streamTargetSwitch(legacy).decodeStreamTargetSwitchRequest().requestID)
        let response = StreamTargetSwitchResultMessage(sessionID: request.sessionID, resolvedTarget: .window("42"),
            senderDeviceID: request.senderDeviceID, status: .completed, startedAt: Date(), requestID: id)
        XCTAssertEqual(try DataChannelEnvelope.streamTargetSwitchResult(response).decodeStreamTargetSwitchResult().requestID, id)
    }

    func testApplicationListSnapshotRoundTrip() throws {
        let sessionID = UUID()
        let snapshot = ApplicationListSnapshotMessage(
            sessionID: sessionID,
            senderDeviceID: UUID(),
            applications: [
                RemoteApplication(
                    bundleIdentifier: "com.apple.dt.Xcode",
                    name: "Xcode",
                    isRunning: true,
                    isActive: true,
                    iconPNGBase64: nil,
                    windowIDs: ["1024", "1025"]
                ),
                RemoteApplication(
                    bundleIdentifier: "com.apple.Terminal",
                    name: "Terminal",
                    isRunning: false,
                    isActive: false
                )
            ]
        )

        let decoded = try DataChannelEnvelope
            .wireDecode(try DataChannelEnvelope.applicationListSnapshot(snapshot).wireEncode())
        XCTAssertEqual(decoded.kind, .applicationList)
        XCTAssertEqual(decoded.sessionID, sessionID)

        let payload = try decoded.decodeApplicationListSnapshot()
        XCTAssertEqual(payload.applications.count, 2)
        XCTAssertEqual(payload.applications[0].id, "com.apple.dt.Xcode")
        XCTAssertEqual(payload.applications[0].windowIDs, ["1024", "1025"])
        XCTAssertFalse(payload.applications[1].isRunning)
    }

    func testStreamTargetSwitchRequestRoundTrip() throws {
        let request = StreamTargetSwitchRequestMessage(
            sessionID: UUID(),
            target: .application("com.apple.Safari"),
            senderDeviceID: UUID()
        )
        let decoded = try DataChannelEnvelope
            .wireDecode(try DataChannelEnvelope.streamTargetSwitch(request).wireEncode())
            .decodeStreamTargetSwitchRequest()
        XCTAssertEqual(decoded.target.kind, .application)
        XCTAssertEqual(decoded.target.identifier, "com.apple.Safari")
        XCTAssertTrue(decoded.launchIfNeeded)
    }

    func testStreamTargetSwitchResultRoundTripCarriesResolvedSurface() throws {
        let result = StreamTargetSwitchResultMessage(
            sessionID: UUID(),
            resolvedTarget: .window("2048"),
            senderDeviceID: UUID(),
            status: .completed,
            width: 1440,
            height: 900,
            scaleFactor: 2.0,
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        let decoded = try DataChannelEnvelope
            .wireDecode(try DataChannelEnvelope.streamTargetSwitchResult(result).wireEncode())
            .decodeStreamTargetSwitchResult()
        XCTAssertEqual(decoded.resolvedTarget, .window("2048"))
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertEqual(decoded.width, 1440)
        XCTAssertEqual(decoded.scaleFactor, 2.0)
    }

    func testAppStreamingKindsRequireControlChannelAuthentication() {
        // These mutate host state / reveal the app inventory — must be MACed like input.
        XCTAssertTrue(DataChannelMessageKind.applicationList.requiresControlChannelAuthentication)
        XCTAssertTrue(DataChannelMessageKind.streamTargetSwitch.requiresControlChannelAuthentication)
        XCTAssertTrue(DataChannelMessageKind.applicationClose.requiresControlChannelAuthentication)
    }

    func testApplicationCloseRequestRoundTrip() throws {
        let request = ApplicationCloseRequestMessage(
            sessionID: UUID(),
            bundleIdentifier: "com.apple.Safari",
            senderDeviceID: UUID(),
            requestID: UUID()
        )
        let decoded = try DataChannelEnvelope
            .wireDecode(try DataChannelEnvelope.applicationCloseRequest(request).wireEncode())
            .decodeApplicationCloseRequest()
        XCTAssertEqual(decoded.bundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(decoded.requestID, request.requestID)
    }

    func testApplicationClosePolicyRejectsHostsAndShells() {
        XCTAssertTrue(ApplicationClosePolicy.canClose("com.apple.Safari"))
        XCTAssertFalse(ApplicationClosePolicy.canClose("com.mesutcy.remotedesktop.minhost"))
        XCTAssertFalse(ApplicationClosePolicy.canClose("com.apple.finder"))
        XCTAssertFalse(ApplicationClosePolicy.canClose("not-a-bundle"))
        XCTAssertFalse(ApplicationClosePolicy.canClose("com.example.App", hostBundleIdentifier: "com.example.App"))
    }

    func testAppStreamingCapabilityFlagSurvivesStableNameRoundTrip() {
        let flags: HostCapabilityFlags = [.supportsH264, .supportsAppStreaming]
        let rebuilt = HostCapabilityFlags(stableNames: flags.stableNames)
        XCTAssertTrue(rebuilt.contains(.supportsAppStreaming))
        XCTAssertEqual(rebuilt, flags)
    }

    func testTargetLostResultIsAFailedStreamTargetSwitchResult() throws {
        // Window loss reuses the switch-result message (unsolicited, status .failed) — no
        // separate error type — while carrying which target was lost.
        let lost = StreamTargetSwitchResultMessage(
            sessionID: UUID(),
            resolvedTarget: .window("2048"),
            senderDeviceID: UUID(),
            status: .failed,
            reason: "The application window is no longer available.",
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        let decoded = try DataChannelEnvelope
            .wireDecode(try DataChannelEnvelope.streamTargetSwitchResult(lost).wireEncode())
            .decodeStreamTargetSwitchResult()
        XCTAssertEqual(decoded.status, .failed)
        XCTAssertEqual(decoded.resolvedTarget, .window("2048"))
        XCTAssertNotNil(decoded.reason)
        XCTAssertNil(decoded.width) // a loss result carries no resolved surface
    }

    // MARK: - Window input coordinate mapping (Step 8)

    /// The whole window-input approach: a window is streamed as a synthetic single-"display"
    /// layout, so the existing translator maps a window-local point to global by adding the
    /// window's screen origin — no separate coordinate abstraction.
    func testWindowLocalPointMapsToWindowOriginPlusLocal() {
        let windowID = "4242"
        let windowDescriptor = DisplayDescriptor(
            id: windowID,
            name: "Xcode",
            frame: DesktopRect(origin: DesktopPoint(x: 100, y: 50), size: DesktopSize(width: 1440, height: 900)),
            pixelSize: DesktopSize(width: 2880, height: 1800), // Retina: points × 2
            scaleFactor: 2.0,
            isPrimary: false
        )
        let layout = DisplayLayout(
            displays: [windowDescriptor],
            primaryDisplayID: windowID,
            virtualBounds: windowDescriptor.frame
        )
        let command = InputCommand.pointerMove(
            PointerMoveCommand(location: DesktopPoint(x: 10, y: 20), displayID: windowID, isAbsolute: true)
        )
        guard case .success(let translated) = InputCoordinateTranslator.translateToGlobal(command, layout: layout),
              case .pointerMove(let move) = translated else {
            return XCTFail("window-local translation failed")
        }
        XCTAssertEqual(move.location.x, 110, "x = windowOriginX(100) + localX(10)")
        XCTAssertEqual(move.location.y, 70, "y = windowOriginY(50) + localY(20)")
    }

    func testWindowLocalClickMapsToWindowOriginPlusLocal() {
        let windowID = "4242"
        let descriptor = DisplayDescriptor(
            id: windowID,
            name: "Xcode",
            frame: DesktopRect(
                origin: DesktopPoint(x: 100, y: 50),
                size: DesktopSize(width: 1440, height: 900)
            ),
            pixelSize: DesktopSize(width: 2880, height: 1800),
            scaleFactor: 2,
            isPrimary: false
        )
        let layout = DisplayLayout(
            displays: [descriptor],
            primaryDisplayID: windowID,
            virtualBounds: descriptor.frame
        )
        let command = InputCommand.pointerButton(PointerButtonCommand(
            button: .left,
            action: .click,
            location: DesktopPoint(x: 10, y: 20),
            displayID: windowID
        ))

        guard case .success(.pointerButton(let click)) = InputCoordinateTranslator.translateToGlobal(
            command,
            layout: layout
        ) else {
            return XCTFail("window-local click translation failed")
        }
        XCTAssertEqual(click.location?.x, 110)
        XCTAssertEqual(click.location?.y, 70)
        XCTAssertEqual(click.action, .click)
    }
}
