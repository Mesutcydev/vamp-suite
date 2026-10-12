import XCTest
@testable import SharedModels

final class DisplayLayoutTests: XCTestCase {

    // MARK: - Helpers

    private func makeDisplay(
        id: String,
        x: Double, y: Double,
        width: Double, height: Double,
        scale: Double = 2.0,
        isPrimary: Bool = false
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id,
            name: "Display \(id)",
            frame: DesktopRect(
                origin: DesktopPoint(x: x, y: y),
                size: DesktopSize(width: width, height: height)
            ),
            pixelSize: DesktopSize(width: width * scale, height: height * scale),
            scaleFactor: scale,
            isPrimary: isPrimary
        )
    }

    // MARK: - Virtual Bounds

    func testComputedLayoutVirtualBoundsSingleDisplay() {
        let primary = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, isPrimary: true)
        let layout = DisplayLayout.computed(from: [primary])

        XCTAssertEqual(layout.virtualBounds.origin.x, 0)
        XCTAssertEqual(layout.virtualBounds.origin.y, 0)
        XCTAssertEqual(layout.virtualBounds.size.width, 1440)
        XCTAssertEqual(layout.virtualBounds.size.height, 900)
        XCTAssertEqual(layout.primaryDisplayID, "1")
    }

    func testComputedLayoutVirtualBoundsTwoDisplaysSideBySide() {
        let primary = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, isPrimary: true)
        let right = makeDisplay(id: "2", x: 1440, y: -100, width: 1920, height: 1080)
        let layout = DisplayLayout.computed(from: [primary, right])

        XCTAssertEqual(layout.virtualBounds.origin.x, 0)
        XCTAssertEqual(layout.virtualBounds.origin.y, -100)
        XCTAssertEqual(layout.virtualBounds.size.width, 3360)
        XCTAssertEqual(layout.virtualBounds.size.height, 1080) // from -100 to 980
    }

    func testComputedLayoutEmptyDisplays() {
        let layout = DisplayLayout.computed(from: [])

        XCTAssertTrue(layout.displays.isEmpty)
        XCTAssertNil(layout.primaryDisplayID)
        XCTAssertEqual(layout.virtualBounds, .zero)
    }

    // MARK: - Global to Local

    func testGlobalToLocalOnPrimaryDisplay() {
        let primary = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, isPrimary: true)
        let layout = DisplayLayout.computed(from: [primary])

        let local = layout.globalToLocal(DesktopPoint(x: 100, y: 200), displayID: "1")
        XCTAssertEqual(local, DesktopPoint(x: 100, y: 200))
    }

    func testGlobalToLocalOnOffsetDisplay() {
        let primary = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, isPrimary: true)
        let secondary = makeDisplay(id: "2", x: 1440, y: 0, width: 1920, height: 1080)
        let layout = DisplayLayout.computed(from: [primary, secondary])

        let local = layout.globalToLocal(DesktopPoint(x: 1500, y: 100), displayID: "2")
        XCTAssertEqual(local, DesktopPoint(x: 60, y: 100))
    }

    func testGlobalToLocalReturnsNilForUnknownDisplay() {
        let primary = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, isPrimary: true)
        let layout = DisplayLayout.computed(from: [primary])

        XCTAssertNil(layout.globalToLocal(DesktopPoint(x: 100, y: 100), displayID: "unknown"))
    }

    // MARK: - Local to Global

    func testLocalToGlobal() {
        let primary = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, isPrimary: true)
        let secondary = makeDisplay(id: "2", x: 1440, y: 0, width: 1920, height: 1080)
        let layout = DisplayLayout.computed(from: [primary, secondary])

        let global = layout.localToGlobal(DesktopPoint(x: 60, y: 100), displayID: "2")
        XCTAssertEqual(global, DesktopPoint(x: 1500, y: 100))
    }

    func testGlobalToLocalAndBackRoundTrip() {
        let primary = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, isPrimary: true)
        let secondary = makeDisplay(id: "2", x: 1440, y: 200, width: 1920, height: 1080)
        let layout = DisplayLayout.computed(from: [primary, secondary])

        let original = DesktopPoint(x: 1600, y: 500)
        let local = layout.globalToLocal(original, displayID: "2")!
        let back = layout.localToGlobal(local, displayID: "2")!
        XCTAssertEqual(back.x, original.x, accuracy: 0.001)
        XCTAssertEqual(back.y, original.y, accuracy: 0.001)
    }

    // MARK: - Negative Origin Mapping

    func testNegativeOriginGlobalToLocal() {
        let primary = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, isPrimary: true)
        let left = makeDisplay(id: "2", x: -1920, y: 0, width: 1920, height: 1080)
        let layout = DisplayLayout.computed(from: [primary, left])

        XCTAssertEqual(layout.virtualBounds.origin.x, -1920)
        XCTAssertEqual(layout.virtualBounds.size.width, 3360)

        let local = layout.globalToLocal(DesktopPoint(x: -1000, y: 500), displayID: "2")
        XCTAssertEqual(local, DesktopPoint(x: 920, y: 500))
    }

    func testNegativeOriginLocalToGlobal() {
        let left = makeDisplay(id: "2", x: -1920, y: 0, width: 1920, height: 1080)
        let layout = DisplayLayout.computed(from: [left])

        let global = layout.localToGlobal(DesktopPoint(x: 100, y: 200), displayID: "2")
        XCTAssertEqual(global, DesktopPoint(x: -1820, y: 200))
    }

    func testDisplayAbovePrimaryHasNegativeY() {
        let primary = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, isPrimary: true)
        let above = makeDisplay(id: "2", x: 0, y: -1080, width: 1920, height: 1080)
        let layout = DisplayLayout.computed(from: [primary, above])

        XCTAssertEqual(layout.virtualBounds.origin.y, -1080)
        XCTAssertEqual(layout.virtualBounds.size.height, 1980) // -1080 to 900

        let local = layout.globalToLocal(DesktopPoint(x: 500, y: -500), displayID: "2")
        XCTAssertEqual(local, DesktopPoint(x: 500, y: 580))
    }

    // MARK: - Retina / Scale Conversions

    func testGlobalToPixelRetinaDisplay() {
        let retina = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, scale: 2.0, isPrimary: true)
        let layout = DisplayLayout.computed(from: [retina])

        let pixel = layout.globalToPixel(DesktopPoint(x: 100, y: 200), displayID: "1")
        XCTAssertEqual(pixel, DesktopPoint(x: 200, y: 400))
    }

    func testPixelToGlobalRetinaDisplay() {
        let retina = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, scale: 2.0, isPrimary: true)
        let layout = DisplayLayout.computed(from: [retina])

        let global = layout.pixelToGlobal(DesktopPoint(x: 200, y: 400), displayID: "1")
        XCTAssertEqual(global, DesktopPoint(x: 100, y: 200))
    }

    func testGlobalToPixelAndBackRoundTrip() {
        let retina = makeDisplay(id: "1", x: 100, y: 200, width: 1440, height: 900, scale: 2.0, isPrimary: true)
        let layout = DisplayLayout.computed(from: [retina])

        let original = DesktopPoint(x: 300, y: 500)
        let pixel = layout.globalToPixel(original, displayID: "1")!
        let back = layout.pixelToGlobal(pixel, displayID: "1")!
        XCTAssertEqual(back.x, original.x, accuracy: 0.001)
        XCTAssertEqual(back.y, original.y, accuracy: 0.001)
    }

    func testMixedScaleDisplays() {
        let retina = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, scale: 2.0, isPrimary: true)
        let standard = makeDisplay(id: "2", x: 1440, y: 0, width: 1920, height: 1080, scale: 1.0)
        let layout = DisplayLayout.computed(from: [retina, standard])

        let retinaPixel = layout.globalToPixel(DesktopPoint(x: 100, y: 100), displayID: "1")
        XCTAssertEqual(retinaPixel, DesktopPoint(x: 200, y: 200))

        let standardPixel = layout.globalToPixel(DesktopPoint(x: 1500, y: 100), displayID: "2")
        XCTAssertEqual(standardPixel, DesktopPoint(x: 60, y: 100))
    }

    func testGlobalToPixelOnOffsetRetinaDisplay() {
        let secondary = makeDisplay(id: "2", x: -1920, y: -200, width: 1920, height: 1080, scale: 2.0)
        let layout = DisplayLayout.computed(from: [secondary])

        let pixel = layout.globalToPixel(DesktopPoint(x: -1820, y: -100), displayID: "2")
        // local = (100, 100), pixel = (200, 200)
        XCTAssertEqual(pixel, DesktopPoint(x: 200, y: 200))
    }

    // MARK: - Normalized Coordinates

    func testNormalizedCoordinates() {
        let display = makeDisplay(id: "1", x: 0, y: 0, width: 1000, height: 500, isPrimary: true)
        let layout = DisplayLayout.computed(from: [display])

        let normalized = layout.normalizedPoint(DesktopPoint(x: 500, y: 250), in: "1")
        XCTAssertNotNil(normalized)
        XCTAssertEqual(normalized!.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(normalized!.y, 0.5, accuracy: 0.001)
    }

    func testNormalizedCornersAreZeroAndOne() {
        let display = makeDisplay(id: "1", x: 0, y: 0, width: 800, height: 600, isPrimary: true)
        let layout = DisplayLayout.computed(from: [display])

        let topLeft = layout.normalizedPoint(DesktopPoint(x: 0, y: 0), in: "1")!
        XCTAssertEqual(topLeft.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 0.0, accuracy: 0.001)

        // Bottom-right is just inside the boundary (exclusive upper bound)
        let nearBottomRight = layout.normalizedPoint(DesktopPoint(x: 799, y: 599), in: "1")!
        XCTAssertEqual(nearBottomRight.x, 799.0 / 800.0, accuracy: 0.001)
        XCTAssertEqual(nearBottomRight.y, 599.0 / 600.0, accuracy: 0.001)
    }

    func testGlobalFromNormalized() {
        let display = makeDisplay(id: "1", x: 100, y: 200, width: 1000, height: 500, isPrimary: true)
        let layout = DisplayLayout.computed(from: [display])

        let global = layout.globalPoint(fromNormalized: DesktopPoint(x: 0.5, y: 0.5), in: "1")
        XCTAssertNotNil(global)
        XCTAssertEqual(global!.x, 600, accuracy: 0.001) // 100 + 500
        XCTAssertEqual(global!.y, 450, accuracy: 0.001) // 200 + 250
    }

    func testNormalizedRoundTrip() {
        let display = makeDisplay(id: "1", x: -500, y: 300, width: 2560, height: 1440, isPrimary: true)
        let layout = DisplayLayout.computed(from: [display])

        let original = DesktopPoint(x: 200, y: 800)
        let normalized = layout.normalizedPoint(original, in: "1")!
        let back = layout.globalPoint(fromNormalized: normalized, in: "1")!
        XCTAssertEqual(back.x, original.x, accuracy: 0.001)
        XCTAssertEqual(back.y, original.y, accuracy: 0.001)
    }

    // MARK: - Display Lookup

    func testDisplayContainingPoint() {
        let primary = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, isPrimary: true)
        let secondary = makeDisplay(id: "2", x: 1440, y: 0, width: 1920, height: 1080)
        let layout = DisplayLayout.computed(from: [primary, secondary])

        XCTAssertEqual(layout.display(containing: DesktopPoint(x: 100, y: 100))?.id, "1")
        XCTAssertEqual(layout.display(containing: DesktopPoint(x: 1500, y: 100))?.id, "2")
        XCTAssertNil(layout.display(containing: DesktopPoint(x: 5000, y: 5000)))
    }

    func testDisplayContainingPointWithNegativeOrigins() {
        let primary = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, isPrimary: true)
        let left = makeDisplay(id: "2", x: -1920, y: 0, width: 1920, height: 1080)
        let layout = DisplayLayout.computed(from: [primary, left])

        XCTAssertEqual(layout.display(containing: DesktopPoint(x: -100, y: 100))?.id, "2")
        XCTAssertEqual(layout.display(containing: DesktopPoint(x: 100, y: 100))?.id, "1")
    }

    func testDisplayContainingPointBoundaryExclusion() {
        let display = makeDisplay(id: "1", x: 0, y: 0, width: 100, height: 100, isPrimary: true)
        let layout = DisplayLayout.computed(from: [display])

        // Right at (100, 100) is outside since contains uses < for maxX/maxY
        XCTAssertNil(layout.display(containing: DesktopPoint(x: 100, y: 100)))
        XCTAssertNotNil(layout.display(containing: DesktopPoint(x: 99, y: 99)))
    }

    func testDisplayWithID() {
        let primary = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, isPrimary: true)
        let secondary = makeDisplay(id: "2", x: 1440, y: 0, width: 1920, height: 1080)
        let layout = DisplayLayout.computed(from: [primary, secondary])

        XCTAssertEqual(layout.display(withID: "1")?.name, "Display 1")
        XCTAssertEqual(layout.display(withID: "2")?.name, "Display 2")
        XCTAssertNil(layout.display(withID: "3"))
    }

    // MARK: - DesktopRect Helpers

    func testDesktopRectContains() {
        let rect = DesktopRect(origin: DesktopPoint(x: -10, y: -20), size: DesktopSize(width: 100, height: 200))
        XCTAssertTrue(rect.contains(DesktopPoint(x: -10, y: -20))) // origin included
        XCTAssertTrue(rect.contains(DesktopPoint(x: 0, y: 0)))
        XCTAssertTrue(rect.contains(DesktopPoint(x: 89, y: 179)))
        XCTAssertFalse(rect.contains(DesktopPoint(x: 90, y: 0)))   // maxX excluded
        XCTAssertFalse(rect.contains(DesktopPoint(x: 0, y: 180)))  // maxY excluded
        XCTAssertFalse(rect.contains(DesktopPoint(x: -11, y: 0)))  // below minX
    }

    func testDesktopRectUnion() {
        let a = DesktopRect(origin: DesktopPoint(x: -100, y: 0), size: DesktopSize(width: 100, height: 50))
        let b = DesktopRect(origin: DesktopPoint(x: 50, y: -30), size: DesktopSize(width: 200, height: 130))
        let result = a.union(b)

        XCTAssertEqual(result.minX, -100)
        XCTAssertEqual(result.minY, -30)
        XCTAssertEqual(result.maxX, 250)
        XCTAssertEqual(result.maxY, 100)
        XCTAssertEqual(result.size.width, 350)
        XCTAssertEqual(result.size.height, 130)
    }

    func testDesktopRectMidpoints() {
        let rect = DesktopRect(origin: DesktopPoint(x: 100, y: 200), size: DesktopSize(width: 400, height: 300))
        XCTAssertEqual(rect.midX, 300)
        XCTAssertEqual(rect.midY, 350)
    }

    // MARK: - DesktopPoint / DesktopSize Helpers

    func testDesktopPointOffset() {
        let point = DesktopPoint(x: 10, y: 20)
        let moved = point.offset(dx: -15, dy: 5)
        XCTAssertEqual(moved, DesktopPoint(x: -5, y: 25))
    }

    func testDesktopPointScaled() {
        let point = DesktopPoint(x: 100, y: 200)
        let scaled = point.scaled(by: 2.0)
        XCTAssertEqual(scaled, DesktopPoint(x: 200, y: 400))
    }

    func testDesktopSizeScaled() {
        let size = DesktopSize(width: 1440, height: 900)
        let scaled = size.scaled(by: 2.0)
        XCTAssertEqual(scaled, DesktopSize(width: 2880, height: 1800))
    }

    // MARK: - VisibleFrame Property

    func testDisplayDescriptorVisibleFrameDefault() {
        let display = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, isPrimary: true)
        XCTAssertNil(display.visibleFrame)
    }

    func testDisplayDescriptorVisibleFrameSet() {
        let display = DisplayDescriptor(
            id: "1",
            name: "Main",
            frame: DesktopRect(origin: DesktopPoint(x: 0, y: 0), size: DesktopSize(width: 1440, height: 900)),
            visibleFrame: DesktopRect(origin: DesktopPoint(x: 0, y: 25), size: DesktopSize(width: 1440, height: 850)),
            pixelSize: DesktopSize(width: 2880, height: 1800),
            scaleFactor: 2.0,
            isPrimary: true
        )
        XCTAssertNotNil(display.visibleFrame)
        XCTAssertEqual(display.visibleFrame!.origin.y, 25)
        XCTAssertEqual(display.visibleFrame!.size.height, 850)
    }

    // MARK: - Three-Display L-Shaped Arrangement

    func testThreeDisplayLShaped() {
        // Primary center, one left, one below-right
        let primary = makeDisplay(id: "1", x: 0, y: 0, width: 1440, height: 900, isPrimary: true)
        let left = makeDisplay(id: "2", x: -1920, y: -100, width: 1920, height: 1080)
        let belowRight = makeDisplay(id: "3", x: 1440, y: 500, width: 1920, height: 1080)
        let layout = DisplayLayout.computed(from: [primary, left, belowRight])

        XCTAssertEqual(layout.virtualBounds.origin.x, -1920)
        XCTAssertEqual(layout.virtualBounds.origin.y, -100)
        XCTAssertEqual(layout.virtualBounds.maxX, 3360)
        XCTAssertEqual(layout.virtualBounds.maxY, 1580)

        // Point on left display
        XCTAssertEqual(layout.display(containing: DesktopPoint(x: -1000, y: 0))?.id, "2")

        // Point on below-right display
        XCTAssertEqual(layout.display(containing: DesktopPoint(x: 2000, y: 800))?.id, "3")

        // Point in gap between displays
        XCTAssertNil(layout.display(containing: DesktopPoint(x: 2000, y: 100)))

        // Coordinate conversion across L-shape
        let pixel = layout.globalToPixel(DesktopPoint(x: -1000, y: 0), displayID: "2")
        XCTAssertEqual(pixel, DesktopPoint(x: 1840, y: 200)) // local=(920,100), scale=2 → (1840,200)
    }
}
