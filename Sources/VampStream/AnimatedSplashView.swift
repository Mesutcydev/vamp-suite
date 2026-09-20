import SwiftUI

struct AnimatedSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onFinish: () -> Void

    @State private var showTitle = false
    @State private var showGrid = false
    @State private var showPortal = false
    @State private var showMountains = false
    @State private var showSignal = false
    @State private var showExit = false
    @State private var hasStarted = false
    @State private var didFinish = false

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width > 1, proxy.size.height > 1,
               proxy.size.width.isFinite, proxy.size.height.isFinite {
                artwork(size: proxy.size)
                    .opacity(showExit ? 0 : 1)
                    .scaleEffect(showExit ? 1.04 : 1, anchor: .center)
                    .animation(.easeOut(duration: SplashTiming.exitDuration), value: showExit)
            }
        }
        .background(SplashTheme.background.ignoresSafeArea())
        // The splash already swallowed taps to protect the UI underneath; it just did nothing
        // with them. Now a tap skips — a launch animation that cannot be dismissed is a toll
        // on every single cold start.
        .contentShape(Rectangle())
        .onTapGesture { skip() }
        .accessibilityElement()
        .accessibilityLabel("Vamp Stream")
        .accessibilityHint("Double-tap to skip the intro")
        .accessibilityAddTraits(.isButton)
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            await runSplash()
        }
    }

    /// Leave now, on a short fade. Safe to call repeatedly and safe to race with `runSplash`.
    private func skip() {
        guard !didFinish else { return }
        didFinish = true
        withAnimation(.easeOut(duration: SplashTiming.skipDuration)) { showExit = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(SplashTiming.skipDuration))
            onFinish()
        }
    }

    @ViewBuilder
    private func artwork(size: CGSize) -> some View {
        let geometry = SplashGeometry(size: size)
        let grid = SplashGrid(geometry: geometry, showGrid: showGrid, reduceMotion: reduceMotion)

        ZStack {
            // Reveal the full illustration in the existing grid / mountain stages.
            VampStreamArtwork(size: size)
                .mask {
                    Rectangle()
                        .overlay {
                            Rectangle()
                                .frame(width: geometry.portalRect.width, height: geometry.portalRect.height)
                                .position(x: geometry.portalRect.midX, y: geometry.portalRect.midY)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
                .opacity(showGrid ? 1 : 0)
                .animation(.easeOut(duration: SplashTiming.gridDuration), value: showGrid)

            VampStreamArtwork(size: size)
                .mask {
                    Rectangle()
                        .frame(width: geometry.portalRect.width, height: geometry.portalRect.height)
                        .position(x: geometry.portalRect.midX, y: geometry.portalRect.midY)
                }
                .opacity(showMountains ? 1 : 0)
                .animation(.easeOut(duration: SplashTiming.mountainDuration), value: showMountains)

            grid
                .opacity(0.30)
                .onAppear {
                    grid.startTravel()
                }
            SplashPortal(geometry: geometry, showPortal: showPortal, reduceMotion: reduceMotion)
            SplashMountains(geometry: geometry, showMountains: showMountains, reduceMotion: reduceMotion)
            SplashSignalPulse(geometry: geometry, showSignal: showSignal, reduceMotion: reduceMotion)
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            CRTOverlay()
                .opacity(0.25)
        }
        .overlay {
            // Keep moving grid lines out of the title and footer's reading zones.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.94), location: 0),
                    .init(color: .black.opacity(0.90), location: 0.18),
                    .init(color: .clear, location: 0.32),
                    .init(color: .clear, location: 0.74),
                    .init(color: .black.opacity(0.90), location: 0.86),
                    .init(color: .black.opacity(0.94), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .overlay {
            SplashTypography(
                showTitle: showTitle,
                showSubtitle: showTitle,
                showBottomLabel: showPortal,
                size: size,
                reduceMotion: reduceMotion
            )
        }
    }

    @MainActor
    private func runSplash() async {
        guard !reduceMotion else {
            // Everything already in its final state, no motion, out almost immediately.
            showTitle = true
            showGrid = true
            showPortal = true
            showMountains = true
            try? await Task.sleep(for: SplashTiming.reducedMotionHold)
            guard !Task.isCancelled else { return }
            skip()
            return
        }

        let start = ContinuousClock.now

        guard await hold(until: SplashTiming.titleStart, from: start) else { return }
        withAnimation(.easeOut(duration: SplashTiming.titleDuration)) { showTitle = true }

        guard await hold(until: SplashTiming.gridStart, from: start) else { return }
        withAnimation(.easeOut(duration: SplashTiming.gridDuration)) { showGrid = true }

        guard await hold(until: SplashTiming.portalStart, from: start) else { return }
        withAnimation(.easeOut(duration: SplashTiming.portalDuration)) { showPortal = true }

        guard await hold(until: SplashTiming.mountainStart, from: start) else { return }
        withAnimation(.easeOut(duration: SplashTiming.mountainDuration)) { showMountains = true }

        guard await hold(until: SplashTiming.signalStart, from: start) else { return }
        withAnimation(.easeInOut(duration: SplashTiming.signalDuration)) { showSignal = true }

        guard await hold(until: SplashTiming.exitStart, from: start) else { return }
        withAnimation(.easeOut(duration: SplashTiming.exitDuration)) { showExit = true }

        guard await hold(until: SplashTiming.finishStart, from: start) else { return }
        didFinish = true
        onFinish()
    }

    /// Sleep until an absolute mark on the schedule. Returns false if the view went away or
    /// the user skipped, so each stage is a single `guard` rather than a drifting interval.
    @MainActor
    private func hold(until mark: Duration, from start: ContinuousClock.Instant) async -> Bool {
        do {
            try await Task.sleep(until: start.advanced(by: mark), clock: .continuous)
        } catch {
            return false
        }
        return !Task.isCancelled && !didFinish
    }
}

private struct VampStreamSplashPresenter: ViewModifier {
    @State private var visible = true

    func body(content: Content) -> some View {
        content.overlay {
            if visible {
                AnimatedSplashView {
                    withAnimation(.easeOut(duration: 0.02)) {
                        visible = false
                    }
                }
                .allowsHitTesting(true)
                .zIndex(1000)
                .transition(.opacity)
            }
        }
    }
}

extension View {
    func vampStreamAnimatedSplash() -> some View {
        modifier(VampStreamSplashPresenter())
    }
}
