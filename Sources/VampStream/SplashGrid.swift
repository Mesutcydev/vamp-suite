import SwiftUI

struct SplashGrid: View {
    let geometry: SplashGeometry
    let showGrid: Bool
    let reduceMotion: Bool

    @State private var gridPhase: Double = 0

    var body: some View {
        if geometry.isValid {
            ZStack {
                TunnelRailsShape(geometry: geometry)
                    .trim(from: 0, to: showGrid ? 1 : 0)
                    .stroke(
                        SplashTheme.grid,
                        style: StrokeStyle(lineWidth: 0.8, lineCap: .round)
                    )

                CrossLinesShape(geometry: geometry, phase: reduceMotion ? 0 : gridPhase)
                    .trim(from: 0, to: showGrid ? 1 : 0)
                    .stroke(
                        SplashTheme.ivory.opacity(0.22),
                        style: StrokeStyle(lineWidth: 0.6, lineCap: .round)
                    )
            }
            .animation(.easeOut(duration: SplashTiming.gridDuration), value: showGrid)
            .animation(
                .linear(duration: SplashTiming.gridCycleDuration)
                    .repeatForever(autoreverses: false),
                value: gridPhase
            )
        } else {
            Color.clear
        }
    }

    func startTravel() {
        guard !reduceMotion else { return }
        withAnimation(
            .linear(duration: SplashTiming.gridCycleDuration)
                .repeatForever(autoreverses: false)
        ) {
            gridPhase = 1
        }
    }
}

private struct TunnelRailsShape: Shape {
    let geometry: SplashGeometry

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard geometry.isValid else { return path }

        let portal = geometry.portalRect
        let outer = geometry.outerRect
        let railCount = 11
        for index in 0..<railCount {
            let lateral = -1 + 2 * Double(index) / Double(railCount - 1)
            let offset = CGFloat(lateral)
            path.move(to: CGPoint(x: portal.midX + offset * portal.width / 2, y: portal.minY))
            path.addLine(to: CGPoint(x: outer.midX + offset * outer.width / 2, y: outer.minY))
            path.move(to: CGPoint(x: portal.midX + offset * portal.width / 2, y: portal.maxY))
            path.addLine(to: CGPoint(x: outer.midX + offset * outer.width / 2, y: outer.maxY))
        }
        return path
    }
}

private struct CrossLinesShape: Shape {
    let geometry: SplashGeometry
    var phase: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard geometry.isValid else { return path }

        let planeCount = 14
        for index in 0..<planeCount {
            let rawDepth = Double(index) / Double(planeCount) + phase
            let depth = rawDepth.truncatingRemainder(dividingBy: 1)
            let normalizedDepth = depth < 0 ? depth + 1 : depth
            let section = geometry.crossSection(for: normalizedDepth)
            path.move(to: CGPoint(x: section.minX, y: section.minY))
            path.addLine(to: CGPoint(x: section.maxX, y: section.minY))
            path.move(to: CGPoint(x: section.minX, y: section.maxY))
            path.addLine(to: CGPoint(x: section.maxX, y: section.maxY))
        }
        return path
    }
}
