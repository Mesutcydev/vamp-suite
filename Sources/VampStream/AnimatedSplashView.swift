import SwiftUI

struct AnimatedSplashView: View {
    let lifecycle: VampStreamSplashLifecycle
    let reduceMotion: Bool
    let safeArea: EdgeInsets
    let onResize: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = VampStreamSplashLayout(size: proxy.size, safeArea: safeArea)
            if layout.isValid {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                    let now = ProcessInfo.processInfo.systemUptime
                    VampStreamSplashArtwork(
                        layout: layout,
                        elapsed: lifecycle.elapsed(at: now),
                        reduceMotion: reduceMotion
                    )
                    .opacity(lifecycle.opacity(at: now))
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { oldSize, newSize in
            if oldSize.width > 1, oldSize.height > 1, oldSize != newSize {
                onResize()
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct VampStreamSplashArtwork: View {
    let layout: VampStreamSplashLayout
    let elapsed: TimeInterval
    let reduceMotion: Bool

    private var frame: VampStreamSplashMotion.Frame {
        VampStreamSplashMotion.frame(at: elapsed, layout: layout, reduceMotion: reduceMotion)
    }

    var body: some View {
        ZStack {
            background
            echoes
            Image("VampStreamSplashMark")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: layout.markSize.width, height: layout.markSize.height)
                .scaleEffect(frame.scale)
                .position(frame.center)

            Text(verbatim: "Vamp Stream")
                .font(.system(size: layout.titleSize, weight: .regular))
                .tracking(layout.tracking)
                .foregroundStyle(Color(red: 247.0 / 255, green: 235.0 / 255, blue: 219.0 / 255))
                .lineLimit(1)
                .frame(width: max(1, layout.size.width - 24))
                .position(x: layout.settledCenter.x, y: layout.titleCenterY)
                .opacity(frame.titleOpacity)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .allowsHitTesting(false)
    }

    private var background: some View {
        Image("VampStreamBackground")
            .renderingMode(.original)
            .resizable()
            .scaledToFill()
            .frame(width: layout.size.width, height: layout.size.height)
            .clipped()
            .background(Color("VampStreamLaunchBackground"))
            .opacity(frame.backgroundOpacity)
    }

    @ViewBuilder
    private var echoes: some View {
        if frame.echoOpacity > 0 {
            VampStreamSplashEcho(
                size: layout.markSize,
                center: VampStreamSplashMotion.echoCenter(at: elapsed, delay: 0.055, layout: layout),
                opacity: frame.echoOpacity * 0.5
            )
            VampStreamSplashEcho(
                size: layout.markSize,
                center: VampStreamSplashMotion.echoCenter(at: elapsed, delay: 0.025, layout: layout),
                opacity: frame.echoOpacity
            )
        }
    }
}

private struct VampStreamSplashEcho: View {
    let size: CGSize
    let center: CGPoint
    let opacity: Double

    var body: some View {
        Image("VampStreamSplashMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color(red: 1, green: 0.29, blue: 0.24))
            .frame(width: size.width, height: size.height)
            .position(center)
            .opacity(opacity)
    }
}

private struct VampStreamSplashPresenter: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowID = UUID()
    let lifecycle: VampStreamSplashLifecycle

    func body(content: Content) -> some View {
        content
            // Appearance is local-shell readiness, independent of discovery, pairing or network.
            .onAppear {
                lifecycle.prepare(owner: windowID)
                lifecycle.rootBecameUsable(at: now)
            }
            .overlay {
                if lifecycle.coversRoot(for: windowID) {
                    GeometryReader { proxy in
                        AnimatedSplashView(
                            lifecycle: lifecycle,
                            reduceMotion: reduceMotion,
                            safeArea: proxy.safeAreaInsets,
                            onResize: { lifecycle.dismiss(at: now) }
                        )
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { lifecycle.dismiss(at: now) }
                    }
                    .zIndex(1000)
                }
            }
            .onChange(of: scenePhase, initial: true) { previousPhase, phase in
                if phase == .active {
                    lifecycle.begin(owner: windowID, at: now, isActive: true, reduceMotion: reduceMotion)
                } else if lifecycle.owner == windowID,
                          previousPhase != phase || phase == .background {
                    lifecycle.becameInactive()
                }
            }
            .onChange(of: reduceMotion) { _, enabled in
                if enabled { lifecycle.dismiss(at: now) }
            }
            .task(id: lifecycle.phase) {
                guard lifecycle.owner == windowID else { return }
                do {
                    while let deadline = lifecycle.deadline {
                        try await Task.sleep(for: .seconds(max(0, deadline - now)))
                        try Task.checkCancellation()
                        lifecycle.advance(to: now)
                    }
                } catch {
                    // SwiftUI cancels the timer when the phase changes or this presenter disappears.
                }
            }
            .onDisappear { lifecycle.cancel(owner: windowID) }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

extension View {
    func vampStreamAnimatedSplash(lifecycle: VampStreamSplashLifecycle) -> some View {
        modifier(VampStreamSplashPresenter(lifecycle: lifecycle))
    }
}
