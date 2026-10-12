#if canImport(UIKit)
import SwiftUI
import UIKit

/// Vamp Stream's multi-touch surface uses the same semantics as Vamp Control:
/// one-finger pan moves the pointer, long press drags until release, two-finger pan scrolls,
/// two-finger tap right-clicks, and three-finger tap middle-clicks.
struct AppStreamGestureView: UIViewRepresentable {
    var allowsViewportAdjustment = false
    var viewportZoom: CGFloat = 1
    var viewportOffset: CGSize = .zero
    var viewSize: CGSize = .zero
    var onTap: (CGPoint) -> Void
    var onDoubleTap: (CGPoint) -> Void
    var onRightClick: (CGPoint) -> Void
    var onMiddleClick: (CGPoint) -> Void
    var onPointerMove: (CGPoint) -> Void
    var onPointerEnded: () -> Void
    var onScroll: (Double, Double) -> Void
    var onViewportPan: (CGSize) -> Void = { _ in }
    var onPinchChanged: (CGFloat, CGPoint) -> Void = { _, _ in }
    var onPinchEnded: () -> Void = {}
    var onLongPress: (CGPoint) -> Void
    var onLongPressEnded: () -> Void = {}
    var onHoverDelta: (Double, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.isMultipleTouchEnabled = true
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(self, in: uiView)
        context.coordinator.viewportZoom = viewportZoom
        context.coordinator.viewportOffset = viewportOffset
        context.coordinator.viewSize = viewSize
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.remove(from: uiView)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: AppStreamGestureView

        var viewportZoom: CGFloat = 1
        var viewportOffset: CGSize = .zero
        var viewSize: CGSize = .zero

        private var lastPointerTranslation: CGPoint = .zero
        private var lastViewportTranslation: CGPoint = .zero
        private var twoFingerPansViewport = false
        private var scrollVelocity: CGSize = .zero
        private var momentumLink: CADisplayLink?
        private weak var pinchRecognizer: UIPinchGestureRecognizer?
        private var lastHoverLocation: CGPoint?
        private var longPressDragging = false

        init(_ parent: AppStreamGestureView) {
            self.parent = parent
        }

        func update(_ parent: AppStreamGestureView, in view: UIView) {
            let modeChanged = self.parent.allowsViewportAdjustment != parent.allowsViewportAdjustment
            self.parent = parent
            guard modeChanged else { return }
            cancelMomentum()
            if longPressDragging {
                parent.onLongPressEnded()
                longPressDragging = false
            }
            // Cancel in-flight gestures so a mode change cannot turn a picture pan
            // into Mac input (or continue remote scroll momentum behind the picture).
            for recognizer in view.gestureRecognizers ?? [] {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
        }

        func install(on view: UIView) {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.numberOfTouchesRequired = 1

            let singleTap = UITapGestureRecognizer(target: self, action: #selector(onSingleTap(_:)))
            singleTap.numberOfTapsRequired = 1
            singleTap.numberOfTouchesRequired = 1
            singleTap.require(toFail: doubleTap)

            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap(_:)))
            twoFingerTap.numberOfTouchesRequired = 2

            let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(onThreeFingerTap(_:)))
            threeFingerTap.numberOfTouchesRequired = 3

            let pointerPan = UIPanGestureRecognizer(target: self, action: #selector(onPointerPan(_:)))
            pointerPan.minimumNumberOfTouches = 1
            pointerPan.maximumNumberOfTouches = 1

            let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(onTwoFingerPan(_:)))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
            pinch.delegate = self
            pinchRecognizer = pinch

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
            longPress.minimumPressDuration = 0.5
            longPress.numberOfTouchesRequired = 1

            let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))

            [singleTap, doubleTap, twoFingerTap, threeFingerTap, pointerPan, twoFingerPan, pinch, longPress, hover]
                .forEach {
                    $0.delegate = self
                    view.addGestureRecognizer($0)
                }
        }

        func remove(from view: UIView) {
            if longPressDragging { parent.onLongPressEnded(); longPressDragging = false }
            momentumLink?.invalidate()
            momentumLink = nil
            for recognizer in view.gestureRecognizers ?? [] {
                recognizer.delegate = nil
                view.removeGestureRecognizer(recognizer)
            }
        }

        @objc private func onSingleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            cancelMomentum()
            parent.onTap(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func onDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            parent.onDoubleTap(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func onTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            parent.onRightClick(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func onThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            parent.onMiddleClick(adjustedPoint(recognizer.location(in: view)))
        }

        @objc func onPointerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                // Do not press on every swipe. Vamp Control reserves mouse-down for drag-lock.
                cancelMomentum()
                lastPointerTranslation = .zero
            case .changed:
                let translation = recognizer.translation(in: view)
                let dx = translation.x - lastPointerTranslation.x
                let dy = translation.y - lastPointerTranslation.y
                lastPointerTranslation = CGPoint(x: translation.x, y: translation.y)
                guard dx != 0 || dy != 0 else { return }
                if parent.allowsViewportAdjustment {
                    parent.onViewportPan(CGSize(width: dx, height: dy))
                } else {
                    parent.onPointerMove(adjustedPoint(recognizer.location(in: view)))
                }
            case .ended, .cancelled, .failed:
                lastPointerTranslation = .zero
                if !parent.allowsViewportAdjustment { parent.onPointerEnded() }
            default:
                break
            }
        }

        @objc private func onTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                cancelMomentum()
                lastViewportTranslation = .zero
                scrollVelocity = .zero
                // Scrolling stays remote at every zoom level. Moving the picture
                // requires the explicit Adjust view mode.
                twoFingerPansViewport = parent.allowsViewportAdjustment
            case .changed:
                let translation = recognizer.translation(in: view)
                let dx = translation.x - lastViewportTranslation.x
                let dy = translation.y - lastViewportTranslation.y
                lastViewportTranslation = translation
                if parent.allowsViewportAdjustment && isPinching { twoFingerPansViewport = true }
                if twoFingerPansViewport {
                    parent.onViewportPan(CGSize(width: dx, height: dy))
                } else {
                    let scrollX = Double(-dx)
                    let scrollY = Double(dy)
                    parent.onScroll(scrollX, scrollY)
                    scrollVelocity = CGSize(width: scrollX, height: scrollY)
                }
            case .ended:
                lastViewportTranslation = .zero
                if !twoFingerPansViewport { startMomentum() }
            case .cancelled, .failed:
                lastViewportTranslation = .zero
            default:
                break
            }
        }

        @objc private func onPinch(_ recognizer: UIPinchGestureRecognizer) {
            guard parent.allowsViewportAdjustment else { return }
            switch recognizer.state {
            case .began:
                cancelMomentum()
                twoFingerPansViewport = true
            case .changed:
                guard let view = recognizer.view else { return }
                parent.onPinchChanged(recognizer.scale, recognizer.location(in: view))
                // Send incremental scale values to the SwiftUI state machine.
                recognizer.scale = 1
            case .ended, .cancelled, .failed:
                parent.onPinchEnded()
            default:
                break
            }
        }

        @objc private func onLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                cancelMomentum()
                longPressDragging = true
                parent.onLongPress(adjustedPoint(recognizer.location(in: view)))
            case .changed:
                if longPressDragging { parent.onPointerMove(adjustedPoint(recognizer.location(in: view))) }
            case .ended, .cancelled, .failed:
                if longPressDragging { parent.onLongPressEnded(); longPressDragging = false }
            default: break
            }
        }

        @objc private func onHover(_ recognizer: UIHoverGestureRecognizer) {
            let location = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began:
                lastHoverLocation = location
            case .changed:
                guard let last = lastHoverLocation else {
                    lastHoverLocation = location
                    return
                }
                let dx = location.x - last.x
                let dy = location.y - last.y
                lastHoverLocation = location
                if dx != 0 || dy != 0 {
                    parent.onHoverDelta(Double(dx), Double(dy))
                }
            case .ended, .cancelled, .failed:
                lastHoverLocation = nil
            default:
                break
            }
        }

        private func adjustedPoint(_ point: CGPoint) -> CGPoint {
            guard viewportZoom != 1 || viewportOffset != .zero else { return point }
            let centerX = viewSize.width / 2
            let centerY = viewSize.height / 2
            return CGPoint(
                x: centerX + (point.x - centerX - viewportOffset.width) / viewportZoom,
                y: centerY + (point.y - centerY - viewportOffset.height) / viewportZoom
            )
        }

        private func startMomentum() {
            let speed = hypot(scrollVelocity.width, scrollVelocity.height)
            guard speed > 1.5 else { return }
            momentumLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(momentumTick))
            link.add(to: .main, forMode: .common)
            momentumLink = link
        }

        private func cancelMomentum() {
            momentumLink?.invalidate()
            momentumLink = nil
            scrollVelocity = .zero
        }

        @objc private func momentumTick() {
            guard !parent.allowsViewportAdjustment else { cancelMomentum(); return }
            parent.onScroll(Double(scrollVelocity.width), Double(scrollVelocity.height))
            scrollVelocity = CGSize(width: scrollVelocity.width * 0.92, height: scrollVelocity.height * 0.92)
            if hypot(scrollVelocity.width, scrollVelocity.height) < 0.4 {
                cancelMomentum()
            }
        }

        private var isPinching: Bool {
            guard let pinchRecognizer else { return false }
            return pinchRecognizer.state == .began || pinchRecognizer.state == .changed
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UIPinchGestureRecognizer {
                return parent.allowsViewportAdjustment
            }
            if parent.allowsViewportAdjustment {
                return gestureRecognizer is UIPanGestureRecognizer
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer is UIHoverGestureRecognizer || other is UIHoverGestureRecognizer {
                return true
            }
            let isPinch = gestureRecognizer is UIPinchGestureRecognizer
            let otherIsPinch = other is UIPinchGestureRecognizer
            let isTwoFingerPan = (gestureRecognizer as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2
            let otherIsTwoFingerPan = (other as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2
            // Keep the recognition policy identical to Vamp Control iOS. In particular, a
            // one-finger tap must win cleanly over pan/long-press instead of remaining in a
            // simultaneous-recognition set where UIKit can promote it to pointer movement.
            return (isPinch && otherIsTwoFingerPan) || (otherIsPinch && isTwoFingerPan)
        }
    }
}
#endif
