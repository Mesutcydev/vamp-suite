import SharedModels
import SharedUtilities
import XCTest

/// Pointer feel must be identical across Vamp Control, Vamp Stream (Sync path), and Vamp Stream
/// (Assistant path). All three used to inline the same acceleration formula; that is exactly how a
/// paired Bluetooth mouse drifts into feeling different per app. These tests pin the curve.
final class PointerDynamicsTests: XCTestCase {

    func testZeroDeltaIsAFixedPoint() {
        XCTAssertEqual(PointerDynamics.accelerate(.zero), .zero)
        XCTAssertEqual(PointerDynamics.apply(.zero, sensitivity: 2.5), .zero)
    }

    /// Slow movement must stay precise — no gain creep that makes fine corrections impossible.
    func testLowSpeedMovementIsEssentiallyOneToOne() {
        let slow = DesktopPoint(x: 1, y: 0)
        let result = PointerDynamics.accelerate(slow)
        // speed = 1 → factor = 1 + 1/50 = 1.02
        XCTAssertEqual(result.x, 1.02, accuracy: 0.0001)
        XCTAssertEqual(result.y, 0, accuracy: 0.0001)
    }

    /// Acceleration must saturate rather than grow without bound, so a violent flick cannot
    /// throw the cursor across several screens.
    func testAccelerationSaturatesAtTheCeiling() {
        let ceiling = 1.0 + PointerDynamics.accelerationMaxGain   // 2.5
        for speed in [100.0, 500.0, 5_000.0, 1_000_000.0] {
            let result = PointerDynamics.accelerate(DesktopPoint(x: speed, y: 0))
            XCTAssertEqual(result.x / speed, ceiling, accuracy: 0.0001,
                "speed \(speed) should hit the \(ceiling)x ceiling")
        }
    }

    func testDisablingAccelerationIsIdentity() {
        let delta = DesktopPoint(x: 40, y: -25)
        XCTAssertEqual(PointerDynamics.accelerate(delta, enabled: false), delta)
        XCTAssertEqual(
            PointerDynamics.apply(delta, sensitivity: 1, accelerationEnabled: false), delta)
    }

    /// Gain depends only on speed, applied equally to both axes, so direction is preserved. This
    /// is what keeps diagonal drags straight instead of curving toward an axis.
    func testDirectionIsPreserved() {
        for delta in [
            DesktopPoint(x: 3, y: 4),
            DesktopPoint(x: -12, y: 9),
            DesktopPoint(x: 300, y: -400),
            DesktopPoint(x: -1, y: -1),
        ] {
            let result = PointerDynamics.accelerate(delta)
            let inputAngle = atan2(delta.y, delta.x)
            let outputAngle = atan2(result.y, result.x)
            XCTAssertEqual(inputAngle, outputAngle, accuracy: 0.0001,
                "\(delta) changed direction")
            // And magnitude only ever grows (gain >= 1).
            let inputSpeed = hypot(delta.x, delta.y)
            let outputSpeed = hypot(result.x, result.y)
            XCTAssertGreaterThanOrEqual(outputSpeed, inputSpeed - 0.0001)
            XCTAssertLessThanOrEqual(outputSpeed, inputSpeed * 2.5 + 0.0001)
        }
    }

    /// Sensitivity is applied before acceleration, so the curve sees the gain the user asked for.
    func testSensitivityIsAppliedBeforeAcceleration() {
        let delta = DesktopPoint(x: 10, y: 0)
        let scaled = PointerDynamics.apply(delta, sensitivity: 2)
        let manual = PointerDynamics.accelerate(DesktopPoint(x: 20, y: 0))
        XCTAssertEqual(scaled, manual)
    }

    /// With acceleration off, sensitivity is a pure linear gain. With acceleration on it is not
    /// exactly proportional — and must not be — because sensitivity is applied *before* the
    /// curve, so a higher sensitivity also raises the speed the acceleration sees. Asserting
    /// proportionality here would lock in the wrong ordering.
    func testSensitivityIsLinearOnlyWhenAccelerationIsDisabled() {
        let delta = DesktopPoint(x: 1, y: 0)
        let base = PointerDynamics.apply(delta, sensitivity: 1, accelerationEnabled: false)
        let doubled = PointerDynamics.apply(delta, sensitivity: 2, accelerationEnabled: false)
        XCTAssertEqual(doubled.x, base.x * 2, accuracy: 0.0001)

        // With acceleration on the result still grows, but super-linearly at low speed.
        let acceleratedBase = PointerDynamics.apply(delta, sensitivity: 1)
        let acceleratedDouble = PointerDynamics.apply(delta, sensitivity: 2)
        XCTAssertGreaterThan(acceleratedDouble.x, acceleratedBase.x * 2,
            "higher sensitivity should also reach a higher acceleration factor")
        XCTAssertEqual(acceleratedBase.x, 1.02, accuracy: 0.0001)   // speed 1 → 1 + 1/50
        XCTAssertEqual(acceleratedDouble.x, 2.08, accuracy: 0.0001) // speed 2 → 2 + 2·(2/50)
    }

    /// A nonsensical stored preference must not invert or freeze the pointer.
    func testInvalidSensitivityFallsBackToOne() {
        let delta = DesktopPoint(x: 8, y: 6)
        let expected = PointerDynamics.accelerate(delta)
        for bad in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(PointerDynamics.apply(delta, sensitivity: bad), expected,
                "sensitivity \(bad) must fall back to 1x")
        }
    }

    /// Both axes respond independently: motion on one axis must not leak into the other.
    func testAxesAreIndependent() {
        let horizontal = PointerDynamics.accelerate(DesktopPoint(x: 50, y: 0))
        XCTAssertEqual(horizontal.y, 0, accuracy: 0.0001)
        let vertical = PointerDynamics.accelerate(DesktopPoint(x: 0, y: 50))
        XCTAssertEqual(vertical.x, 0, accuracy: 0.0001)
    }

    func testMonotonicallyFasterMovementCoversMoreDistance() {
        var previous = 0.0
        for speed in stride(from: 0.0, through: 400.0, by: 10.0) {
            let result = PointerDynamics.accelerate(DesktopPoint(x: speed, y: 0)).x
            XCTAssertGreaterThanOrEqual(result, previous, "gain must not decrease as speed rises")
            previous = result
        }
    }
}
