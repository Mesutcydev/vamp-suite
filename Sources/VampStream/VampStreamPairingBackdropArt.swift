import SwiftUI

/// A quieter architectural variant of Stream's perspective-grid language.
///
/// The pairing page keeps the converging-line vocabulary but intentionally omits the portal and
/// mountains: those are focal elements, and they must not read as focus rings behind the address,
/// code, and pairing controls.
struct VampStreamPairingGridBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            let geometry = PairingBackdropGeometry(size: proxy.size)

            ZStack {
                Color.black

                if geometry.isValid {
                    PairingRailShape(geometry: geometry)
                        .stroke(SplashTheme.ivory.opacity(0.058), style: StrokeStyle(lineWidth: 0.65, lineCap: .round))
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .black.opacity(0.12), location: 0),
                                    .init(color: .black.opacity(0.18), location: 0.16),
                                    .init(color: .black, location: 0.46),
                                    .init(color: .black.opacity(0.34), location: 0.72),
                                    .init(color: .black.opacity(0.08), location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }

                    PairingCrossLineShape(geometry: geometry)
                        .stroke(SplashTheme.ivory.opacity(0.040), style: StrokeStyle(lineWidth: 0.50, lineCap: .round))
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .black.opacity(0.06), location: 0),
                                    .init(color: .black.opacity(0.12), location: 0.20),
                                    .init(color: .black.opacity(0.80), location: 0.48),
                                    .init(color: .black.opacity(0.20), location: 0.78),
                                    .init(color: .black.opacity(0.04), location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                }

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.44), location: 0),
                        .init(color: .black.opacity(0.10), location: 0.10),
                        .init(color: .black.opacity(0.02), location: 0.32),
                        .init(color: .black.opacity(0.28), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // A broad, soft reading zone. This is not a per-control spotlight; it simply keeps
                // the faint geometry from accumulating bright intersections under form fields.
                RadialGradient(
                    colors: [
                        .black.opacity(0.42),
                        .black.opacity(0.18),
                        .black.opacity(0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: max(geometry.size.height * 0.38, 120)
                )
                .frame(width: max(geometry.size.width, 1), height: max(geometry.size.height * 0.62, 1))
                .position(x: geometry.size.width * 0.50, y: geometry.size.height * 0.38)
                .blur(radius: 18)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }
}

private struct PairingBackdropGeometry {
    let size: CGSize

    var isValid: Bool {
        size.width > 1
            && size.height > 1
            && size.width.isFinite
            && size.height.isFinite
    }

    var vanishingPoint: CGPoint {
        CGPoint(x: size.width * 0.50, y: size.height * 0.62)
    }

    var outerRect: CGRect {
        let margin = max(size.width * -0.18, 0)
        return CGRect(
            x: margin,
            y: -size.height * 0.14,
            width: size.width + margin * 2,
            height: size.height * 1.28)
    }
}

private struct PairingRailShape: Shape {
    let geometry: PairingBackdropGeometry

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard geometry.isValid else { return path }

        let outer = geometry.outerRect
        let center = geometry.vanishingPoint
        let railCount = 11
        for index in 0..<railCount {
            let fraction = Double(index) / Double(railCount - 1)
            let lateral = -1 + 2 * fraction
            let targetX = outer.midX + CGFloat(lateral) * outer.width / 2

            // Rails fan outward from the center to both horizontal edges. A vertical line is
            // included at the middle, giving the grid its architectural axis without a rectangle.
            let direction = targetX - center.x
            let topY = abs(direction) < 0.5 ? outer.minY : center.y - (center.y - outer.minY) * 0.72
            let bottomY = abs(direction) < 0.5 ? outer.maxY : center.y + (outer.maxY - center.y) * 0.72
            path.move(to: CGPoint(x: targetX, y: topY))
            path.addLine(to: center)
            path.addLine(to: CGPoint(x: targetX, y: bottomY))
        }
        return path
    }
}

private struct PairingCrossLineShape: Shape {
    let geometry: PairingBackdropGeometry

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard geometry.isValid else { return path }

        let planeCount = 10
        for index in 0..<planeCount {
            let depth = Double(index) / Double(planeCount - 1)
            let perspective = pow(depth, 2.1)
            let height = geometry.size.height * (0.08 + CGFloat(perspective) * 0.76)
            let y = geometry.vanishingPoint.y - height
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: geometry.size.width, y: y))

            let mirroredY = geometry.vanishingPoint.y + height
            path.move(to: CGPoint(x: 0, y: mirroredY))
            path.addLine(to: CGPoint(x: geometry.size.width, y: mirroredY))
        }
        return path
    }
}
