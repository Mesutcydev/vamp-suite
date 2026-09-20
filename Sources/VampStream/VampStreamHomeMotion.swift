import SwiftUI

/// Slow luminance behind Stream's connect home. The glass stays untinted;
/// this only moves the light the material can catch.
struct VampStreamHomeAtmosphere: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if reduceMotion || reduceTransparency {
            atmosphere(t: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: scenePhase != .active)) { context in
                atmosphere(t: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func atmosphere(t: TimeInterval) -> some View {
        let dark = colorScheme == .dark
        let x1 = CGFloat(sin(t * 0.11)) * 34
        let y1 = CGFloat(cos(t * 0.09)) * 20
        let x2 = CGFloat(cos(t * 0.08)) * 40
        let y2 = CGFloat(sin(t * 0.10)) * 26
        return ZStack {
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(dark ? 0.07 : 0.26),
                            Color.white.opacity(0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 220
                    )
                )
                .frame(width: 480, height: 390)
                .blur(radius: 36)
                .offset(x: 140 + x1, y: -210 + y1)
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.black.opacity(dark ? 0.16 : 0.05),
                            Color.black.opacity(0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 230
                    )
                )
                .frame(width: 500, height: 410)
                .blur(radius: 42)
                .offset(x: -160 + x2, y: 210 + y2)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// A faint highlight that travels across glass so a card reads as catching light.
struct VampStreamHomeSheen: View {
    var phaseOffset: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceMotion || reduceTransparency {
            Color.clear
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 16.0, paused: scenePhase != .active)) { context in
                let t = context.date.timeIntervalSinceReferenceDate + phaseOffset
                let x = 0.5 + CGFloat(sin(t * 0.15)) * 0.52
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.white.opacity(0.07),
                        Color.clear
                    ],
                    startPoint: UnitPoint(x: x - 0.34, y: 0.05),
                    endPoint: UnitPoint(x: x + 0.34, y: 0.95)
                )
            }
        }
    }
}

struct VampStreamLivePulse: ViewModifier {
    var isActive: Bool
    var period: Double = 1.8
    var trough: Double = 0.78
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(shouldPulse ? (dimmed ? trough : 1) : 1)
            .onAppear { startIfNeeded() }
            .onChangeCompat(of: isActive) { _ in startIfNeeded() }
            .onChangeCompat(of: scenePhase) { _ in startIfNeeded() }
            .onChangeCompat(of: reduceMotion) { _ in startIfNeeded() }
            .onChangeCompat(of: reduceTransparency) { _ in startIfNeeded() }
    }

    private var shouldPulse: Bool { isActive && !reduceMotion && !reduceTransparency && scenePhase == .active }

    private func startIfNeeded() {
        guard shouldPulse else {
            dimmed = false
            return
        }
        dimmed = false
        withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
            dimmed = true
        }
    }
}

extension View {
    func vampHomeLiveGlass<S: InsettableShape>(
        in shape: S,
        phaseOffset: Double = 0
    ) -> some View {
        prGlassSurface(in: shape)
            .overlay {
                VampStreamHomeSheen(phaseOffset: phaseOffset)
                    .clipShape(shape)
                    .allowsHitTesting(false)
            }
    }

    func vampHomeLivePulse(isActive: Bool, period: Double = 1.8, trough: Double = 0.78) -> some View {
        modifier(VampStreamLivePulse(isActive: isActive, period: period, trough: trough))
    }
}
