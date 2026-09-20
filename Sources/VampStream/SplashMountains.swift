import SwiftUI

struct SplashMountains: View {
    let geometry: SplashGeometry
    let showMountains: Bool
    let reduceMotion: Bool

    private static let ridges: [[CGPoint]] = [
        [
            CGPoint(x: 0.06, y: 0.70), CGPoint(x: 0.16, y: 0.60),
            CGPoint(x: 0.24, y: 0.66), CGPoint(x: 0.34, y: 0.47),
            CGPoint(x: 0.43, y: 0.59), CGPoint(x: 0.52, y: 0.52),
            CGPoint(x: 0.63, y: 0.64), CGPoint(x: 0.72, y: 0.56),
            CGPoint(x: 0.83, y: 0.69), CGPoint(x: 0.94, y: 0.62)
        ],
        [
            CGPoint(x: 0.08, y: 0.79), CGPoint(x: 0.18, y: 0.71),
            CGPoint(x: 0.29, y: 0.78), CGPoint(x: 0.39, y: 0.68),
            CGPoint(x: 0.51, y: 0.76), CGPoint(x: 0.63, y: 0.69),
            CGPoint(x: 0.74, y: 0.78), CGPoint(x: 0.89, y: 0.74)
        ],
        [
            CGPoint(x: 0.11, y: 0.88), CGPoint(x: 0.22, y: 0.82),
            CGPoint(x: 0.35, y: 0.88), CGPoint(x: 0.47, y: 0.81),
            CGPoint(x: 0.60, y: 0.87), CGPoint(x: 0.73, y: 0.83),
            CGPoint(x: 0.89, y: 0.89)
        ]
    ]

    var body: some View {
        if geometry.isValid {
            MountainShape(points: Self.ridges, geometry: geometry)
                .trim(from: 0, to: showMountains ? 1 : 0)
                .stroke(
                    SplashTheme.ivory.opacity(0.20),
                    style: StrokeStyle(lineWidth: 0.7, lineCap: .round, lineJoin: .round)
                )
                .animation(.easeOut(duration: SplashTiming.mountainDuration), value: showMountains)
        }
    }
}

private struct MountainShape: Shape {
    let points: [[CGPoint]]
    let geometry: SplashGeometry

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard geometry.isValid else { return path }

        let portal = geometry.portalRect
        for ridge in points where ridge.count > 1 {
            path.move(to: portal.point(at: ridge[0]))
            for point in ridge.dropFirst() {
                path.addLine(to: portal.point(at: point))
            }
        }
        return path
    }
}

private extension CGRect {
    func point(at normalizedPoint: CGPoint) -> CGPoint {
        CGPoint(x: minX + normalizedPoint.x * width, y: minY + (normalizedPoint.y * 0.77 + 0.003) * height)
    }
}
