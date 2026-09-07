#if os(macOS)
import XCTest
@testable import HostApp
import SharedModels
import SharedProtocol
import TransportWebRTC

final class HostApplicationRegistryTests: XCTestCase {

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> DesktopRect {
        DesktopRect(origin: DesktopPoint(x: x, y: y), size: DesktopSize(width: w, height: h))
    }

    private func app(
        _ bundleID: String,
        name: String,
        running: Bool = true,
        active: Bool = false,
        windows: [String] = []
    ) -> RemoteApplication {
        RemoteApplication(
            bundleIdentifier: bundleID,
            name: name,
            isRunning: running,
            isActive: active,
            windowIDs: windows
        )
    }

    /// A Mac with a full /Applications encodes to several hundred KB with icons attached,
    /// which the control channel silently drops. The snapshot must still arrive.
    func testApplicationListEnvelopeStaysUnderTheControlChannelBudget() throws {
        let icon = String(repeating: "A", count: 3_000) // ~ one 32x32 PNG, base64
        let applications = (0..<200).map { index in
            RemoteApplication(
                bundleIdentifier: "com.example.app\(index)",
                name: "Application \(index)",
                isRunning: index < 10,
                isActive: false,
                iconPNGBase64: icon,
                windowIDs: []
            )
        }
        let envelope = try XCTUnwrap(HostSessionCoordinator.applicationListEnvelope(
            applications: applications,
            sessionID: UUID(),
            senderDeviceID: UUID(),
            preservesIconsAcrossPages: false
        ))
        let wire = try envelope.wireEncode()
        XCTAssertLessThanOrEqual(wire.count, HostSessionCoordinator.applicationListByteBudget)
        // Shedding icons must never shed applications.
        let decoded = try DataChannelEnvelope.wireDecode(wire).decodeApplicationListSnapshot()
        XCTAssertEqual(decoded.applications.count, 200)
        XCTAssertTrue(decoded.applications.contains { $0.iconPNGBase64 != nil })
    }

    func testPagedInventoryPreservesInstalledApplicationIcons() throws {
        let icon = String(repeating: "A", count: 3_000)
        let apps = (0..<200).map {
            RemoteApplication(bundleIdentifier: "example.\($0)", name: "App \($0)",
                isRunning: false, isActive: false, iconPNGBase64: icon)
        }
        var offset = 0
        var received: [RemoteApplication] = []
        repeat {
            let envelope = try XCTUnwrap(HostSessionCoordinator.applicationListEnvelope(
                applications: apps, sessionID: UUID(), senderDeviceID: UUID(), offset: offset))
            XCTAssertLessThanOrEqual(try envelope.wireEncode().count, HostSessionCoordinator.applicationListByteBudget)
            let page = try envelope.decodeApplicationListSnapshot()
            received += page.applications
            guard let next = page.nextOffset else { break }
            XCTAssertGreaterThan(next, offset)
            offset = next
        } while true
        XCTAssertEqual(received, apps)
    }

    func testApplicationListEnvelopeKeepsEveryIconWhenItAlreadyFits() throws {
        let applications = [
            RemoteApplication(bundleIdentifier: "com.example.a", name: "A", isRunning: true,
                              isActive: true, iconPNGBase64: String(repeating: "A", count: 3_000)),
            RemoteApplication(bundleIdentifier: "com.example.b", name: "B", isRunning: false,
                              isActive: false, iconPNGBase64: String(repeating: "B", count: 3_000)),
        ]
        let envelope = try XCTUnwrap(HostSessionCoordinator.applicationListEnvelope(
            applications: applications,
            sessionID: UUID(),
            senderDeviceID: UUID()
        ))
        let decoded = try envelope.decodeApplicationListSnapshot()
        XCTAssertTrue(decoded.applications.allSatisfy { $0.iconPNGBase64 != nil })
    }

    func testOversizedInventoryIsPagedWithoutDroppingApps() throws {
        let apps = (0..<1200).map {
            RemoteApplication(bundleIdentifier: "com.example.app\($0)",
                name: String(repeating: "Long name ", count: 80) + String($0),
                isRunning: false, isActive: false)
        }
        var offset = 0
        var received: [RemoteApplication] = []
        repeat {
            let envelope = try XCTUnwrap(HostSessionCoordinator.applicationListEnvelope(
                applications: apps, sessionID: UUID(), senderDeviceID: UUID(), offset: offset))
            XCTAssertLessThanOrEqual(try envelope.wireEncode().count, HostSessionCoordinator.applicationListByteBudget)
            let page = try envelope.decodeApplicationListSnapshot()
            XCTAssertEqual(page.offset, offset)
            received += page.applications
            guard let next = page.nextOffset else { break }
            XCTAssertGreaterThan(next, offset)
            offset = next
        } while offset < apps.count
        XCTAssertEqual(received.map(\.id), apps.map(\.id))
    }

    /// A drag-resize on the Mac changes the frame on every 200ms poll; each reconfigure
    /// rebuilds capture and encode, so only a shape that held still may trigger one.
    func testWindowResizeOnlyRestartsCaptureOnceTheShapeHoldsStill() {
        let a = HostSessionCoordinator.WindowGeometrySample(
            size: DesktopSize(width: 800, height: 600), scale: 2)
        let b = HostSessionCoordinator.WindowGeometrySample(
            size: DesktopSize(width: 700, height: 600), scale: 2)

        XCTAssertFalse(HostSessionCoordinator.hasSettled(previous: nil, current: a),
                       "the first poll of a resize must never restart capture")
        XCTAssertFalse(HostSessionCoordinator.hasSettled(previous: a, current: b),
                       "a size still changing must not restart capture")
        XCTAssertTrue(HostSessionCoordinator.hasSettled(previous: b, current: b))
        // A Retina backing factor is floating point; ignore noise below the tolerance.
        XCTAssertTrue(HostSessionCoordinator.hasSettled(
            previous: b,
            current: HostSessionCoordinator.WindowGeometrySample(size: b.size, scale: 2.005)))
        XCTAssertFalse(HostSessionCoordinator.hasSettled(
            previous: b,
            current: HostSessionCoordinator.WindowGeometrySample(size: b.size, scale: 1)),
            "moving to a differently-scaled screen is a real change")
    }

    func testDedupPrefersActiveInstance() {
        let deduped = HostApplicationRegistry.dedupedByBundleID([
            app("com.apple.Terminal", name: "Terminal", active: false, windows: ["1"]),
            app("com.apple.Terminal", name: "Terminal", active: true, windows: [])
        ])
        XCTAssertEqual(deduped.count, 1)
        XCTAssertTrue(deduped[0].isActive)
    }

    func testDedupPrefersMoreWindowsWhenActivityTies() {
        let deduped = HostApplicationRegistry.dedupedByBundleID([
            app("com.apple.dt.Xcode", name: "Xcode", windows: ["1"]),
            app("com.apple.dt.Xcode", name: "Xcode", windows: ["1", "2", "3"])
        ])
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped[0].windowIDs.count, 3)
    }

    func testDedupPrefersRunningOverInstalledDuplicate() {
        let deduped = HostApplicationRegistry.dedupedByBundleID([
            app("com.apple.Safari", name: "Safari", running: false),
            app("com.apple.Safari", name: "Safari", running: true, windows: ["1"])
        ])
        XCTAssertEqual(deduped.count, 1)
        XCTAssertTrue(deduped[0].isRunning)
    }

    func testBrowserOrderActiveThenRunningThenAlphabetical() {
        let ordered = HostApplicationRegistry.sortedForBrowser([
            app("com.z", name: "Zed", running: true),
            app("com.a", name: "Ada", running: false),
            app("com.m", name: "Music", running: true, active: true),
            app("com.b", name: "Books", running: true)
        ])
        XCTAssertEqual(ordered.map(\.name), ["Music", "Books", "Zed", "Ada"])
    }

    // MARK: - Window selection (Step 5 policy)

    func testChooseWindowPrefersLargestArea() {
        let small = WindowInfo(windowID: 1, ownerPID: 10, bounds: rect(0, 0, 100, 100))
        let large = WindowInfo(windowID: 2, ownerPID: 10, bounds: rect(0, 0, 800, 600))
        XCTAssertEqual(HostApplicationRegistry.chooseWindow(from: [small, large])?.windowID, 2)
    }

    func testChooseWindowTieBreaksToLowerWindowID() {
        let a = WindowInfo(windowID: 7, ownerPID: 10, bounds: rect(0, 0, 400, 300))
        let b = WindowInfo(windowID: 3, ownerPID: 10, bounds: rect(0, 0, 400, 300))
        XCTAssertEqual(HostApplicationRegistry.chooseWindow(from: [a, b])?.windowID, 3)
    }

    func testChooseWindowEmptyIsNil() {
        XCTAssertNil(HostApplicationRegistry.chooseWindow(from: []))
    }

    func testAssistantCompatibleWindowFitStaysOnDisplay() {
        let frame = HostApplicationRegistry.targetWindowFrame(
            current: CGRect(x: 1_500, y: 800, width: 1_200, height: 800),
            display: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            requestedAspect: 390.0 / 844.0
        )

        // A portrait request reshapes the window to the phone aspect and fills the usable
        // display height (1080 - 76), so the phone renders it edge-to-edge without bars.
        XCTAssertEqual(frame.width / frame.height, 390.0 / 844.0, accuracy: 0.005)
        XCTAssertEqual(frame.height, 1_004, accuracy: 1)
        XCTAssertLessThan(frame.width, frame.height, "portrait request must stay portrait")
        XCTAssertGreaterThanOrEqual(frame.minX, 24)
        XCTAssertGreaterThanOrEqual(frame.minY, 52)
        XCTAssertLessThanOrEqual(frame.maxX, 1_896)
        XCTAssertLessThanOrEqual(frame.maxY, 1_056)
    }

    func testAssistantCompatibleWindowFitFillsTheDisplayForWideViewport() {
        let frame = HostApplicationRegistry.targetWindowFrame(
            current: CGRect(x: 100, y: 100, width: 400, height: 800),
            display: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            requestedAspect: 1
        )
        // Square viewport, so the fit is bounded by the usable display height (1080 - 76).
        XCTAssertEqual(frame.width, 1_004, accuracy: 1)
        XCTAssertEqual(frame.height, 1_004, accuracy: 1)
    }

    /// A small source window must grow toward the display instead of staying a postage stamp:
    /// Terminal's ~528x374 default once became ~172x374 (about 31 columns), which the phone
    /// then upscaled ~3x into giant text. The window now scales up to the usable height while
    /// holding the phone aspect, so the capture is large enough to render crisply.
    func testSmallSourceWindowGrowsInsteadOfBecomingAPostageStamp() {
        let frame = HostApplicationRegistry.targetWindowFrame(
            current: CGRect(x: 200, y: 200, width: 528, height: 374),
            display: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            requestedAspect: 390.0 / 844.0
        )
        XCTAssertEqual(frame.height, 824, accuracy: 1, "should fill the usable display height")
        XCTAssertEqual(frame.width / frame.height, 390.0 / 844.0, accuracy: 0.005)
        XCTAssertGreaterThan(frame.width, 370, "grows well past the old ~172pt postage stamp")
        XCTAssertGreaterThan(frame.width * frame.height, 528.0 * 374.0, "capture area must grow")
        XCTAssertLessThanOrEqual(frame.maxY, 876, "must stay inside the usable display area")
    }

    /// Growing must not hand the phone a capture its H.264 decoder will reject.
    func testWindowFitIsCappedOnVeryLargeDisplays() {
        let frame = HostApplicationRegistry.targetWindowFrame(
            current: CGRect(x: 0, y: 0, width: 528, height: 374),
            display: CGRect(x: 0, y: 0, width: 5_120, height: 2_880),
            requestedAspect: 390.0 / 844.0
        )
        XCTAssertLessThanOrEqual(max(frame.width, frame.height), 1_400)
        XCTAssertEqual(frame.width / frame.height, 390.0 / 844.0, accuracy: 0.005)
    }

    func testWindowMatchRejectsMissingAndAmbiguousCandidates() {
        let target = CGRect(x: 100, y: 100, width: 900, height: 700)
        XCTAssertNil(HostApplicationRegistry.matchingWindowIndex(frames: [nil, CGRect(x: 500, y: 200, width: 900, height: 700)], target: target))
        XCTAssertNil(HostApplicationRegistry.matchingWindowIndex(frames: [target, target], target: target))
        XCTAssertEqual(HostApplicationRegistry.matchingWindowIndex(frames: [nil, target], target: target), 1)
    }

    func testAdaptiveSizingAcrossAppsPhonesRotationsAndDisplays() {
        let apps = ["com.openai.codex", "com.todesktop.230313mzl4w4u92", "com.apple.Terminal", "com.apple.Safari", "com.anthropic.claudefordesktop", "unknown.app"]
        let viewports = [(320.0, 568.0), (375, 667), (390, 844), (393, 852), (430, 932), (440, 956), (507, 1024)]
        let displays = [(1366.0, 768.0), (1440, 900), (1920, 1080), (2560, 1440)]
        for app in apps {
            for (vw, vh) in viewports {
                for (dw, dh) in displays {
                    for rotated in [false, true] {
                        let original = DesktopSize(width: app == "com.apple.Terminal" ? 640 : 1100, height: 700)
                        let available = DesktopSize(width: dw - 48, height: dh - 76)
                        let viewport = DesktopSize(width: rotated ? vh : vw, height: rotated ? vw : vh)
                        let size = AdaptiveWindowSizing.size(original: original, available: available, viewport: viewport, bundleIdentifier: app)
                        let context = "\(app) \(Int(vw))x\(Int(vh)) rotated=\(rotated) on \(Int(dw))x\(Int(dh))"
                        // THE regression guard: the window must match the viewport's aspect so an
                        // aspect-fit renderer fills the phone edge-to-edge. Any width floor above
                        // `height * aspect` widens the window and letterboxes it into a strip.
                        let requestedAspect = viewport.width / viewport.height
                        XCTAssertEqual(size.width / size.height, requestedAspect, accuracy: 0.02, context)
                        // Portrait must stay portrait, never get reordered into landscape.
                        XCTAssertEqual(size.width < size.height, viewport.width < viewport.height, context)
                        XCTAssertLessThanOrEqual(size.width, available.width, context)
                        XCTAssertLessThanOrEqual(size.height, min(available.height, AdaptiveWindowSizing.maxEdgePoints), context)
                        XCTAssertGreaterThan(size.height, 0, context)
                        // The window must actually fill the display: growing until it touches a
                        // usable-display edge (or the 1400-point decoder cap), never left small.
                        // For a narrow portrait shape the binding axis is the height, so test the
                        // axis that is actually constrained rather than the longest edge.
                        let cappedHeight = min(available.height, AdaptiveWindowSizing.maxEdgePoints)
                        let cappedWidth = min(available.width, AdaptiveWindowSizing.maxEdgePoints)
                        let fillRatio = max(size.width / cappedWidth, size.height / cappedHeight)
                        XCTAssertGreaterThan(fillRatio, 0.98,
                            "\(context): window should scale into the display, not stay small")
                        // Returning to a prior orientation uses the original baseline, never the
                        // previous resized width (which otherwise grows cumulatively).
                        XCTAssertEqual(size, AdaptiveWindowSizing.size(original: original, available: available, viewport: viewport, bundleIdentifier: app), context)
                    }
                }
            }
        }
    }

    func testAdaptiveSizingRejectsInvalidViewportAndClampsOversizedOriginal() {
        let original = DesktopSize(width: 2000, height: 900)
        let available = DesktopSize(width: 1000, height: 700)
        XCTAssertEqual(AdaptiveWindowSizing.size(original: original, available: available,
            viewport: .zero, bundleIdentifier: "unknown"), original)
        // A portrait phone viewport reshapes the oversized landscape window into a portrait
        // column bounded by the display height, matching the phone aspect exactly.
        let size = AdaptiveWindowSizing.size(original: original, available: available,
            viewport: DesktopSize(width: 390, height: 844), bundleIdentifier: "unknown")
        XCTAssertEqual(size.height, 700)
        XCTAssertEqual(size.width / size.height, 390.0 / 844.0, accuracy: 0.01)
        XCTAssertLessThan(size.width, size.height, "portrait request must produce a portrait window")
    }

    /// The regression this suite guards: a wide desktop app streamed to a portrait phone used to
    /// keep its width floor, so the aspect-fit renderer shrank it into a strip with large black
    /// bars above and below. The window must instead become tall and narrow at the phone's exact
    /// aspect, filling the usable display height.
    func testPortraitViewportReshapesWideAppsIntoFillingColumns() {
        // Real hardware: a 1100x700 editor on a 1440x900 laptop, 390x844 phone viewport.
        let size = AdaptiveWindowSizing.size(
            original: DesktopSize(width: 1100, height: 700),
            available: DesktopSize(width: 1392, height: 824),
            viewport: DesktopSize(width: 390, height: 844),
            bundleIdentifier: "com.openai.codex")
        XCTAssertEqual(size.height, 823, accuracy: 1, "fills the usable display height")
        XCTAssertEqual(size.width, 380, accuracy: 3, "narrows to the phone aspect")
        XCTAssertEqual(size.width / size.height, 390.0 / 844.0, accuracy: 0.01)

        // A landscape viewport must not be narrowed by the portrait rule.
        let landscape = AdaptiveWindowSizing.size(
            original: DesktopSize(width: 1100, height: 700),
            available: DesktopSize(width: 1392, height: 824),
            viewport: DesktopSize(width: 844, height: 390),
            bundleIdentifier: "com.openai.codex")
        XCTAssertEqual(landscape.width / landscape.height, 844.0 / 390.0, accuracy: 0.01)
        XCTAssertGreaterThan(landscape.width, landscape.height)
    }

    /// Sizing is app-agnostic: a per-app width exception is what reintroduced the bars, so Safari
    /// (the historical exception) must now fit exactly like every other app.
    func testSizingIsAppAgnosticAndNeverLetterboxes() {
        let available = DesktopSize(width: 2512, height: 1364)   // 2560x1440 Mac minus chrome
        let viewport = DesktopSize(width: 390, height: 794)      // iPhone 17 Pro Max stream area
        let originals = [
            DesktopSize(width: 1100, height: 700),
            DesktopSize(width: 528, height: 374),                // Terminal default
            DesktopSize(width: 1400, height: 900),               // Safari
            DesktopSize(width: 900, height: 600),
        ]
        for original in originals {
            for app in ["com.apple.Safari", "com.openai.codex", "unknown.app"] {
                let size = AdaptiveWindowSizing.size(
                    original: original, available: available,
                    viewport: viewport, bundleIdentifier: app)
                let aspect = size.width / size.height
                XCTAssertEqual(aspect, viewport.width / viewport.height, accuracy: 0.01,
                    "\(Int(original.width))x\(Int(original.height)) via \(app)")
                // Aspect-fitting this window into the phone viewport must leave no bars.
                let videoArea = CGSize(width: 390, height: 794)
                let fittedHeight = aspect > videoArea.width / videoArea.height
                    ? videoArea.width / aspect : videoArea.height
                XCTAssertEqual(fittedHeight, videoArea.height, accuracy: 8,
                    "letterboxed: \(Int(size.width))x\(Int(size.height)) via \(app)")
            }
        }
    }

    /// A small source window must grow toward the display instead of staying a postage stamp the
    /// phone upscales ~3x (the original pre-regression complaint behind `fitScale`).
    func testSmallWindowGrowsWhileKeepingThePhoneAspect() {
        let size = AdaptiveWindowSizing.size(
            original: DesktopSize(width: 528, height: 374),
            available: DesktopSize(width: 1392, height: 824),
            viewport: DesktopSize(width: 390, height: 844),
            bundleIdentifier: "com.apple.Terminal")
        XCTAssertEqual(size.height, 824, "grows to fill the usable height")
        XCTAssertGreaterThan(size.width, 528 * 0.7, "keeps readable content width")
        XCTAssertEqual(size.width / size.height, 390.0 / 844.0, accuracy: 0.01)
    }

    // MARK: - Capability advertisement (Step 13)

    func testFullHostAdvertisesAppStreamingOnModernMacOS() {
        if #available(macOS 14, *) {
            XCTAssertTrue(HostProductMode.full.advertisedCapabilities.contains(.supportsAppStreaming))
        }
        XCTAssertFalse(HostProductMode.terminalOnly.advertisedCapabilities.contains(.supportsAppStreaming))
    }

    func testMiniHostSupportsStreamingAndUsesItsOwnProductSurface() {
        XCTAssertEqual(HostProductMode.mini.productTitle, "Vamp Sync")
        XCTAssertFalse(HostProductMode.mini.isTerminalOnly)
        XCTAssertTrue(HostProductMode.mini.isAppStreamingOnly)
        XCTAssertEqual(HostProductMode.mini.supportedCodecs, ["h264"])
        XCTAssertFalse(HostProductMode.mini.advertisedCapabilities.isTerminalOnlyHost)
        XCTAssertFalse(HostProductMode.mini.advertisedCapabilities.contains(.supportsMultiDisplay))
        XCTAssertFalse(HostProductMode.mini.advertisedCapabilities.contains(.supportsTerminal))
        if #available(macOS 14, *) {
            XCTAssertTrue(HostProductMode.mini.advertisedCapabilities.contains(.supportsAppStreaming))
        }
    }
}
#endif
