import SwiftUI

enum SplashTheme {
    static let background = Color(.sRGB, red: 0x08 / 255, green: 0x08 / 255, blue: 0x06 / 255)
    static let secondaryBlack = Color(.sRGB, red: 0x10 / 255, green: 0x10 / 255, blue: 0x0E / 255)
    static let ivory = Color(.sRGB, red: 0xF1 / 255, green: 0xEB / 255, blue: 0xDD / 255)
    static let ivoryDim = ivory.opacity(0.35)
    static let grid = ivory.opacity(0.18)
    static let portal = Color(.sRGB, red: 0xFF / 255, green: 0xF8 / 255, blue: 0xE7 / 255)
}

/// The splash schedule.
///
/// The `*Start` values are absolute offsets from the first frame and `AnimatedSplashView`
/// sleeps until each one, so this table is the schedule rather than a description of it.
/// It previously listed marks the code did not use — the code slept fixed intervals, and the
/// two had drifted (`portalStart` said 450 ms; the portal actually appeared at 370 ms).
enum SplashTiming {
    static let titleStart: Duration = .milliseconds(100)
    static let gridStart: Duration = .milliseconds(220)
    static let portalStart: Duration = .milliseconds(450)
    static let mountainStart: Duration = .milliseconds(600)
    static let signalStart: Duration = .milliseconds(850)
    static let exitStart: Duration = .milliseconds(1600)
    static let finishStart: Duration = .milliseconds(1900)
    static let titleDuration: TimeInterval = 0.35
    static let gridDuration: TimeInterval = 0.65
    static let portalDuration: TimeInterval = 0.45
    static let mountainDuration: TimeInterval = 0.50
    static let signalDuration: TimeInterval = 1.05
    static let exitDuration: TimeInterval = 0.30
    static let gridCycleDuration: Double = 2.5
    static let gridCycleCount: Double = 14

    /// How long a skip (tap) or a Reduce Motion launch takes to clear the screen.
    static let skipDuration: TimeInterval = 0.18

    /// Reduce Motion shows the finished artwork and leaves immediately. It used to remove the
    /// moving pieces but keep the full 1.7 s wait, which is the opposite of what the setting
    /// asks for: the point is less motion *and* less time spent watching it.
    static let reducedMotionHold: Duration = .milliseconds(350)
}

struct SplashGeometry {
    let size: CGSize

    var isValid: Bool {
        size.width > 1
            && size.height > 1
            && size.width.isFinite
            && size.height.isFinite
    }

    var vanishingPoint: CGPoint {
        CGPoint(x: size.width * 0.50, y: size.height * 0.50 + artworkHeight * (0.482 - 0.5))
    }

    // Match the master image's aspect-fill transform on phones and tablets.
    var artworkWidth: CGFloat { max(size.width, size.height * 941 / 1672) }
    var artworkHeight: CGFloat { artworkWidth * 1672 / 941 }
    var portalHalfWidth: CGFloat { artworkWidth * 0.19 }
    var portalHalfHeight: CGFloat { artworkHeight * 0.198 }
    var outerHalfWidth: CGFloat { max(size.width * 0.95, portalHalfWidth * 2) }
    var outerHalfHeight: CGFloat { max(size.height * 0.65, portalHalfHeight * 2) }

    var portalRect: CGRect {
        let center = vanishingPoint
        return CGRect(
            x: center.x - portalHalfWidth,
            y: center.y - portalHalfHeight,
            width: portalHalfWidth * 2,
            height: portalHalfHeight * 2)
    }

    var outerRect: CGRect {
        let center = vanishingPoint
        return CGRect(
            x: center.x - outerHalfWidth,
            y: center.y - outerHalfHeight,
            width: outerHalfWidth * 2,
            height: outerHalfHeight * 2)
    }

    func crossSection(for depth: Double) -> CGRect {
        let clamped = min(max(depth, 0), 1)
        let perspective = pow(clamped, 2.2)
        let halfWidth = portalHalfWidth + CGFloat(perspective) * (outerHalfWidth - portalHalfWidth)
        let halfHeight = portalHalfHeight + CGFloat(perspective) * (outerHalfHeight - portalHalfHeight)
        let center = vanishingPoint
        return CGRect(
            x: center.x - halfWidth,
            y: center.y - halfHeight,
            width: halfWidth * 2,
            height: halfHeight * 2)
    }
}
