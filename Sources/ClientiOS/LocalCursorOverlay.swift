import SwiftUI

/// Local cursor overlay for cursorless-capture streams.
///
/// When the session negotiates `supportsCursorlessCapture`, the host omits the macOS
/// cursor from the encoded video. The client then draws the pointer itself, so cursor
/// and hover feedback are zero-round-trip: the pointer leads and the video follows,
/// instead of every movement waiting ~60–100 ms for a captured frame round trip.
/// (This is the same contract the Mac client already uses; iOS surfaces previously
/// kept the cursor inside the video, which is why hover felt late.)
///
/// Position is in the *video surface's* coordinate space — the same space the input
/// controllers already map touches in — so `AppStreamInputController`,
/// `RemoteInteractionViewModel`, and the Assistant path's controller each update it
/// from the exact points they are about to send.
@MainActor
final class LocalCursorModel: ObservableObject {
    /// Cursor position in view coordinates, or nil when hidden (no stream, cursor
    /// never placed yet, or the surface lost pointer ownership).
    @Published private(set) var position: CGPoint?

    private var clampRect: CGRect = .zero
    private var viewSize: CGSize = .zero

    func setSurface(size: CGSize, contentRect: CGRect) {
        guard contentRect.width > 0, contentRect.height > 0 else { return }
        viewSize = size
        clampRect = contentRect
        // Callers include view builders (a GeometryReader that maps the streamed content rect),
        // so an unconditional write here publishes during a view update: SwiftUI re-runs the
        // body, which calls this again, and the app spins at 100% CPU instead of drawing. An
        // `@Published` setter has no equality check of its own, so compare before assigning —
        // the same value must be a no-op.
        let next = position.map(clampToContent) ?? CGPoint(x: contentRect.midX, y: contentRect.midY)
        if position != next { position = next }
    }
    /// Absolute placement: the exact view point a touch was mapped to. The cursor
    /// jumps there instantly; the video catches up on the next frame.
    func place(at viewPoint: CGPoint) {
        position = clampToContent(viewPoint)
    }

    /// Relative placement: a Bluetooth-mouse or trackpad delta that was already
    /// accelerated by `PointerDynamics`. `viewPointsPerDesktopPoint` converts the
    /// desktop-space delta into this surface's coordinate space.
    func moveRelative(dx: Double, dy: Double, viewPointsPerDesktopPoint: Double) {
        guard let current = position else { return }
        position = clampToContent(CGPoint(
            x: current.x + dx * viewPointsPerDesktopPoint,
            y: current.y + dy * viewPointsPerDesktopPoint))
    }

    /// Hide (e.g. the stream target changed or the surface went interactive-nil).
    func hide() { position = nil }

    private func clampToContent(_ point: CGPoint) -> CGPoint {
        guard clampRect.width > 0, clampRect.height > 0 else { return point }
        return CGPoint(
            x: min(max(point.x, clampRect.minX), clampRect.maxX),
            y: min(max(point.y, clampRect.minY), clampRect.maxY))
    }
}

/// The arrow itself. Solid black body with a hairline white outline and a soft
/// shadow: black reads as the pointer over bright stream content (documents, light
/// app chrome) where the old white body washed out, while the outline keeps it
/// findable over dark terminals and dark-mode apps.
struct LocalCursorOverlay: View {
    @ObservedObject var cursor: LocalCursorModel
    /// The video may be magnified, but the pointer glyph stays a stable screen-space size.
    var contentZoom: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Filler: the stack must fill the whole surface, and the arrow must anchor
            // top-leading — a bare ZStack sizes to the arrow and centers it, which made
            // `offset` measure from the surface's middle and drew the pointer half a
            // screen away from where the input pipeline mapped it.
            Color.clear
            if let position = cursor.position {
                CursorArrowShape()
                    .fill(Color.black)
                    .overlay(CursorArrowShape().stroke(Color.white.opacity(0.9), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0.4, y: 0.8)
                    .frame(width: 12, height: 18, alignment: .topLeading)
                    .scaleEffect(1 / max(contentZoom, 1), anchor: .topLeading)
                    // The hotspot of a macOS arrow is its tip (top-left of the glyph).
                    .offset(x: position.x - 1.5, y: position.y - 1)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        // Purely visual: every touch must keep falling through to the gesture surface.
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.08), value: cursor.position)
    }
}

private struct CursorArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: h * 0.72))
        path.addLine(to: CGPoint(x: w * 0.24, y: h * 0.56))
        path.addLine(to: CGPoint(x: w * 0.37, y: h * 0.87))
        path.addLine(to: CGPoint(x: w * 0.50, y: h * 0.81))
        path.addLine(to: CGPoint(x: w * 0.37, y: h * 0.51))
        path.addLine(to: CGPoint(x: w * 0.60, y: h * 0.49))
        path.closeSubpath()
        return path
    }
}
