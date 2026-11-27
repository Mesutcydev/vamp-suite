import SwiftUI

struct VampStreamSplashLayout {
    let size: CGSize
    let isValid: Bool
    let markSize: CGSize
    let titleSize: CGFloat
    let tracking: CGFloat
    let settledCenter: CGPoint
    let titleCenterY: CGFloat
    let entranceCenter: CGPoint
    let exitCenter: CGPoint
    let settleDistance: CGFloat

    init(size: CGSize, safeArea: EdgeInsets = EdgeInsets()) {
        self.size = size
        isValid = size.width.isFinite && size.height.isFinite && size.width > 1 && size.height > 1
        let width = isValid ? size.width : 1
        let height = isValid ? size.height : 1
        let shorter = min(width, height)
        titleSize = min(24, max(14, shorter * 28 / 720))
        tracking = min(1.45, shorter * 1.45 / 720)
        let gap = max(8, shorter * 34 / 720)
        let availableWidth = max(1, width - safeArea.leading - safeArea.trailing - 24)
        let availableHeight = max(1, height - safeArea.top - safeArea.bottom - titleSize * 1.5 - gap - 24)
        let markWidth = min(min(440, max(120, shorter * 484 / 720)), min(availableWidth, availableHeight * 1.5))
        markSize = CGSize(width: markWidth, height: markWidth / 1.5)
        let minY = safeArea.top + markSize.height / 2 + 12
        let maxY = max(minY, height - safeArea.bottom - markSize.height / 2 - gap - titleSize * 1.5 - 12)
        settledCenter = CGPoint(
            x: safeArea.leading + (width - safeArea.leading - safeArea.trailing) / 2,
            y: min(maxY, max(minY, height * 0.42))
        )
        titleCenterY = settledCenter.y + markSize.height / 2 + gap + titleSize * 0.65
        let margin = max(16, shorter * 0.03)
        entranceCenter = CGPoint(x: settledCenter.x, y: height + markSize.height / 2 + margin)
        exitCenter = CGPoint(x: width + markSize.width / 2 + margin, y: -markSize.height / 2 - margin)
        settleDistance = shorter * 8 / 720
    }
}

enum VampStreamSplashMotion {
    struct Frame {
        let center: CGPoint
        let scale: CGFloat
        let titleOpacity: Double
        let backgroundOpacity: Double
        let echoOpacity: Double
    }

    static func frame(at elapsed: TimeInterval, layout: VampStreamSplashLayout, reduceMotion: Bool) -> Frame {
        let center: CGPoint
        if reduceMotion {
            center = layout.settledCenter
        } else if elapsed < 0.55 {
            let target = CGPoint(x: layout.settledCenter.x, y: layout.settledCenter.y - layout.settleDistance)
            center = interpolate(layout.entranceCenter, target, easeOut(clamp(elapsed / 0.55)))
        } else if elapsed < 0.80 {
            center = CGPoint(
                x: layout.settledCenter.x,
                y: layout.settledCenter.y - layout.settleDistance * CGFloat(1 - easeOut(clamp((elapsed - 0.55) / 0.15)))
            )
        } else {
            let progress = clamp((elapsed - 0.80) / 0.55)
            center = interpolate(layout.settledCenter, layout.exitCenter, progress * progress)
        }
        let exitProgress = clamp((elapsed - 0.80) / 0.55)
        return Frame(
            center: center,
            scale: reduceMotion ? 1 : CGFloat(0.88 + 0.12 * easeOut(clamp(elapsed / 0.55))),
            titleOpacity: reduceMotion ? 1 : clamp((elapsed - 0.38) / 0.24) * (1 - clamp((elapsed - 0.80) / 0.18)),
            backgroundOpacity: reduceMotion ? 1 : 1 - clamp((elapsed - 1.05) / 0.30),
            echoOpacity: reduceMotion || elapsed < 0.80 ? 0 : 0.14 * clamp(exitProgress / 0.15) * (1 - exitProgress)
        )
    }

    static func echoCenter(at elapsed: TimeInterval, delay: TimeInterval, layout: VampStreamSplashLayout) -> CGPoint {
        frame(at: max(0.80, elapsed - delay), layout: layout, reduceMotion: false).center
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    private static func easeOut(_ value: Double) -> Double { 1 - pow(1 - value, 3) }
    private static func interpolate(_ from: CGPoint, _ to: CGPoint, _ fraction: Double) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * CGFloat(fraction), y: from.y + (to.y - from.y) * CGFloat(fraction))
    }
}
