import SwiftUI

struct CRTOverlay: View {
    var body: some View {
        ScanlineShape()
            .stroke(Color.white.opacity(0.018), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

private struct ScanlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 1, rect.height > 1, rect.width.isFinite, rect.height.isFinite else {
            return path
        }

        var y = rect.minY
        while y < rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += 4
        }
        return path
    }
}
