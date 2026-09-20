import SwiftUI

struct SplashPortal: View {
    let geometry: SplashGeometry
    let showPortal: Bool
    let reduceMotion: Bool

    var body: some View {
        if geometry.isValid {
            Rectangle()
                .stroke(SplashTheme.portal, lineWidth: 1)
                .frame(width: geometry.portalRect.width, height: geometry.portalRect.height)
                .position(x: geometry.portalRect.midX, y: geometry.portalRect.midY)
                .opacity(showPortal ? 1 : 0)
                .scaleEffect(showPortal ? 1 : 0.97)
                .shadow(color: SplashTheme.portal.opacity(0.18), radius: showPortal ? 4 : 0)
                .animation(.easeOut(duration: SplashTiming.portalDuration), value: showPortal)
        }
    }
}

struct SplashSignalPulse: View {
    let geometry: SplashGeometry
    let showSignal: Bool
    let reduceMotion: Bool

    var body: some View {
        if geometry.isValid, !reduceMotion {
            SignalPulseShape(geometry: geometry)
                .trim(from: 0, to: showSignal ? 1 : 0)
                .stroke(
                    SplashTheme.portal.opacity(0.28),
                    style: StrokeStyle(lineWidth: 0.7, lineCap: .round)
                )
                .animation(.easeInOut(duration: SplashTiming.signalDuration), value: showSignal)
        }
    }
}

private struct SignalPulseShape: Shape {
    let geometry: SplashGeometry

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard geometry.isValid else { return path }

        path.move(to: CGPoint(x: geometry.vanishingPoint.x, y: geometry.portalRect.maxY))
        path.addLine(to: CGPoint(x: geometry.vanishingPoint.x, y: geometry.outerRect.maxY))
        return path
    }
}
