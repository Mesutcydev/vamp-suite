import Foundation
import SharedModels

/// Pointer feel for relative (trackpad/hover) movement, shared by Vamp Control and Vamp Stream.
///
/// Two clients that each inline this curve drift apart the first time one is tuned, and a paired
/// Bluetooth mouse then moves differently in each app. Keeping it here means one curve, one set of
/// numbers, and it is unit-testable without UIKit.
///
/// Absolute mapping places the cursor directly from a touch coordinate, so dynamics must never be
/// applied to it — doing so would distort where a tap lands.
public enum PointerDynamics {
    /// Speed (points of delta) at which acceleration reaches its ceiling.
    public static let accelerationSpeedDivisor: Double = 50
    /// Ceiling on the extra gain added at high speed. 1.5 → at most ~2.5× the raw delta.
    public static let accelerationMaxGain: Double = 1.5

    /// Velocity-based acceleration: ~1× at low speed so small corrections stay precise, up to
    /// ~2.5× at high speed so one quick flick crosses the screen instead of needing several.
    ///
    /// Gain is a function of speed only and is applied to both axes equally, so direction is
    /// preserved. A zero delta is a fixed point.
    public static func accelerate(
        _ delta: DesktopPoint,
        enabled: Bool = true
    ) -> DesktopPoint {
        guard enabled else { return delta }
        let speed = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        let factor = 1.0 + min(speed / accelerationSpeedDivisor, accelerationMaxGain)
        return DesktopPoint(x: delta.x * factor, y: delta.y * factor)
    }

    /// Sensitivity, then acceleration. Sensitivity is a linear user preference applied first so
    /// the acceleration curve sees the gain the user actually asked for.
    public static func apply(
        _ delta: DesktopPoint,
        sensitivity: Double,
        accelerationEnabled: Bool = true
    ) -> DesktopPoint {
        let gain = sensitivity.isFinite && sensitivity > 0 ? sensitivity : 1
        return accelerate(
            DesktopPoint(x: delta.x * gain, y: delta.y * gain),
            enabled: accelerationEnabled)
    }
}
