import SwiftUI
import SharedModels
import SharedUtilities
#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

/// Dedicated trackpad input surface for the "modern" streaming theme. Drives the Mac pointer in
/// RELATIVE mode (like a laptop trackpad) by feeding raw gesture deltas to `RemoteInteractionViewModel`
/// — it reuses the existing command plumbing rather than reinventing it. Visual: a dark glass card
/// with a pulsing neon-green dot (`PR.accent`) to match the app's design language.
///
/// Gestures: 1-finger drag = move · tap = left click · double-tap = double click ·
/// 2-finger tap = right click · 3-finger tap = middle click · 2-finger drag = scroll ·
/// long-press = drag-lock toggle.
struct TrackpadSurfaceView: View {
    @ObservedObject var interactionVM: RemoteInteractionViewModel
    /// Optional hook for the local cursor overlay owned by the video surface.
    var onRelativeMove: ((Double, Double) -> Void)? = nil
    /// Multiplies each raw finger delta before it's sent as a relative pointer move. A phone-sized
    /// pad mapped to a large Mac display needs gain > 1 to feel responsive; the view model then
    /// layers its own speed-based acceleration on top.
    ///
    /// This MUST be applied here: the VM's relative path (`sendRelativePointerMove`) does not apply
    /// `pointerSensitivity` — it only adds acceleration — so the surface scales the deltas itself,
    /// mirroring the Bluetooth-mouse hover path. Setting `pointerSensitivity` here would be a no-op.
    var sensitivity: Double = 2.0

    @State private var priorMode: ViewportCoordinateMapper.InteractionMode = .absolute
    @State private var isTouching = false
    @State private var pulse = false

    /// Fixed colors so the surface is always dark, regardless of system light/white mode (the stream
    /// chrome is meant to read as a dark "control deck", like the marketing design).
    private static let dotGreen = Color(red: 0.20, green: 0.84, blue: 0.45)
    private static let surface = Color(red: 0.07, green: 0.075, blue: 0.085)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Self.surface)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    isTouching ? Self.dotGreen.opacity(0.45) : Color.white.opacity(0.07),
                    lineWidth: isTouching ? 1.4 : 1
                )

            // Soft radial glow + pulsing dot in the center.
            Circle()
                .fill(Self.dotGreen.opacity(0.18))
                .frame(width: pulse ? 84 : 60, height: pulse ? 84 : 60)
                .blur(radius: 18)
            Circle()
                .fill(Self.dotGreen)
                .frame(width: 18, height: 18)
                .shadow(color: Self.dotGreen.opacity(0.9), radius: pulse ? 22 : 9)
                .scaleEffect(pulse ? 1.3 : 0.9)
                .opacity(isTouching ? 1.0 : 0.9)

            VStack {
                Spacer()
                Text("trackpad")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.30))
                    .padding(.bottom, 14)
            }

            #if canImport(UIKit) && !os(macOS)
            TrackpadGestureSurface(
                onMove: { dx, dy in
                    let scaledX = dx * sensitivity
                    let scaledY = dy * sensitivity
                    interactionVM.sendRelativePointerMove(deltaX: scaledX, deltaY: scaledY)
                    onRelativeMove?(scaledX, scaledY)
                },
                onClick: { interactionVM.sendPointerButton(.left, action: .click) },
                onDoubleClick: { interactionVM.sendPointerButton(.left, action: .doubleClick) },
                onRightClick: { interactionVM.sendPointerButton(.right, action: .click) },
                onMiddleClick: { interactionVM.sendPointerButton(.middle, action: .click) },
                onScroll: { dx, dy in interactionVM.sendScrollInput(deltaX: dx, deltaY: dy) },
                onDragLockToggle: { interactionVM.toggleDragLock(at: DesktopPoint(x: 0, y: 0)) },
                onTouchActive: { active in isTouching = active }
            )
            #endif
        }
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onAppear {
            // Switch to relative (trackpad) input while the surface is on screen; restore on exit so
            // the classic / direct-touch paths keep their absolute behavior. Gain is applied to the
            // deltas directly (see `onMove`), so we deliberately leave `pointerSensitivity` alone —
            // it's shared with the Bluetooth-mouse path and unused by the relative pipeline anyway.
            //
            // Defensive: never capture `.relative` as the restore target. If a prior cycle's
            // onDisappear failed to fire, the VM could already be in our trackpad state; capturing it
            // would "restore" to relative forever and break the classic on-video gestures. The app's
            // only non-trackpad mode is `.absolute`, so fall back to that.
            priorMode = interactionVM.interactionMode == .relative ? .absolute : interactionVM.interactionMode
            interactionVM.interactionMode = .relative
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onDisappear {
            interactionVM.interactionMode = priorMode
            if interactionVM.isDragLocked {
                interactionVM.toggleDragLock(at: DesktopPoint(x: 0, y: 0))
            }
        }
    }
}

#if canImport(UIKit) && !os(macOS)
/// UIKit gesture surface for the trackpad. Mirrors the proven `RemoteGestureView` coordinator pattern
/// (SwiftUI's simultaneous multi-finger composition is unreliable) but trackpad-flavored: raw point
/// deltas, no viewport zoom/pan. Callbacks map 1:1 onto `RemoteInteractionViewModel` methods.
private struct TrackpadGestureSurface: UIViewRepresentable {
    var onMove: (Double, Double) -> Void
    var onClick: () -> Void
    var onDoubleClick: () -> Void
    var onRightClick: () -> Void
    var onMiddleClick: () -> Void
    var onScroll: (Double, Double) -> Void
    var onDragLockToggle: () -> Void
    var onTouchActive: (Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.isMultipleTouchEnabled = true
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.callbacks = makeCallbacks()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach(from: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(makeCallbacks()) }

    private func makeCallbacks() -> Coordinator.Callbacks {
        Coordinator.Callbacks(
            onMove: onMove,
            onClick: onClick,
            onDoubleClick: onDoubleClick,
            onRightClick: onRightClick,
            onMiddleClick: onMiddleClick,
            onScroll: onScroll,
            onDragLockToggle: onDragLockToggle,
            onTouchActive: onTouchActive
        )
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        struct Callbacks {
            var onMove: (Double, Double) -> Void
            var onClick: () -> Void
            var onDoubleClick: () -> Void
            var onRightClick: () -> Void
            var onMiddleClick: () -> Void
            var onScroll: (Double, Double) -> Void
            var onDragLockToggle: () -> Void
            var onTouchActive: (Bool) -> Void
        }

        var callbacks: Callbacks
        private var lastPan: CGPoint = .zero
        private var lastTwoFinger: CGPoint = .zero

        init(_ callbacks: Callbacks) { self.callbacks = callbacks }

        func attach(to view: UIView) {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.numberOfTouchesRequired = 1
            doubleTap.delegate = self

            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            singleTap.numberOfTapsRequired = 1
            singleTap.numberOfTouchesRequired = 1
            singleTap.require(toFail: doubleTap)
            singleTap.delegate = self

            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
            twoFingerTap.numberOfTapsRequired = 1
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.delegate = self

            let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
            threeFingerTap.numberOfTapsRequired = 1
            threeFingerTap.numberOfTouchesRequired = 3
            threeFingerTap.delegate = self

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = 1
            pan.delegate = self

            let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            twoFingerPan.delegate = self

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.5
            longPress.numberOfTouchesRequired = 1
            longPress.delegate = self

            for recognizer in [singleTap, doubleTap, twoFingerTap, threeFingerTap, pan, twoFingerPan, longPress] {
                view.addGestureRecognizer(recognizer)
            }
        }

        func detach(from view: UIView) {
            for recognizer in view.gestureRecognizers ?? [] {
                recognizer.delegate = nil
                view.removeGestureRecognizer(recognizer)
            }
        }

        @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
            if g.state == .ended { callbacks.onClick() }
        }

        @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
            if g.state == .ended { callbacks.onDoubleClick() }
        }

        @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
            if g.state == .ended { callbacks.onRightClick() }
        }

        @objc private func handleThreeFingerTap(_ g: UITapGestureRecognizer) {
            if g.state == .ended { callbacks.onMiddleClick() }
        }

        @objc private func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            switch g.state {
            case .began:
                lastPan = g.translation(in: view)
                callbacks.onTouchActive(true)
            case .changed:
                let t = g.translation(in: view)
                // Raw point deltas — `TrackpadSurfaceView` applies the sensitivity gain and the view
                // model adds speed-based acceleration, so don't pre-scale here.
                callbacks.onMove(Double(t.x - lastPan.x), Double(t.y - lastPan.y))
                lastPan = t
            case .ended, .cancelled, .failed:
                callbacks.onTouchActive(false)
            default:
                break
            }
        }

        @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            switch g.state {
            case .began:
                lastTwoFinger = g.translation(in: view)
            case .changed:
                let t = g.translation(in: view)
                let dx = t.x - lastTwoFinger.x
                let dy = t.y - lastTwoFinger.y
                lastTwoFinger = t
                // Trackpad scroll bypasses the viewport mapper (relative path sends
                // raw pixels to the host), so apply the gain here — a phone-sized pad
                // driving a large Mac display needs > 1× to feel responsive. The old
                // /3 divisor made scrolling feel stuck.
                callbacks.onScroll(Double(-dx) * 2.0, Double(dy) * 2.0)
            default:
                break
            }
        }

        @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
            if g.state == .began { callbacks.onDragLockToggle() }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Keep the one-finger move and two-finger scroll from firing together.
            if gestureRecognizer is UIPanGestureRecognizer && other is UIPanGestureRecognizer {
                return false
            }
            return true
        }
    }
}
#endif
