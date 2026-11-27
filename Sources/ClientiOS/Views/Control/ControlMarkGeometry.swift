import CoreGraphics

/// The same 64-point master is used by SwiftUI and the app-icon exporter.
/// An open desktop frame makes room for the smaller, connected window.
enum ControlMarkGeometry {
    static let strokeWidth: CGFloat = 6

    static func desktop() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 49, y: 21))
        path.addLine(to: CGPoint(x: 49, y: 19))
        path.addCurve(to: CGPoint(x: 39, y: 9), control1: CGPoint(x: 49, y: 13.477), control2: CGPoint(x: 44.523, y: 9))
        path.addLine(to: CGPoint(x: 17, y: 9))
        path.addCurve(to: CGPoint(x: 7, y: 19), control1: CGPoint(x: 11.477, y: 9), control2: CGPoint(x: 7, y: 13.477))
        path.addLine(to: CGPoint(x: 7, y: 33))
        path.addCurve(to: CGPoint(x: 17, y: 43), control1: CGPoint(x: 7, y: 38.523), control2: CGPoint(x: 11.477, y: 43))
        path.addLine(to: CGPoint(x: 25, y: 43))
        return path
    }

    static func handheld() -> CGPath {
        CGPath(roundedRect: CGRect(x: 33, y: 28, width: 24, height: 29),
               cornerWidth: 7, cornerHeight: 7, transform: nil)
    }

    static func silhouette() -> CGPath {
        let path = CGMutablePath()
        for contour in [desktop(), handheld()] {
            path.addPath(contour.copy(strokingWithWidth: strokeWidth, lineCap: .round,
                                      lineJoin: .round, miterLimit: 2))
        }
        return path
    }
}
