import SwiftUI

/// A short, dismissible cold-launch signature. Discovery starts underneath it.
/// Returning from the background never replays the sequence.
struct ControlLaunchView: View {
    let finish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var connected = false
    @State private var typeVisible = false

    var body: some View {
        Button(action: finish) {
            ZStack {
                ControlBackground()
                VStack(spacing: 30) {
                    ControlLaunchMark(connected: connected, reduceMotion: reduceMotion)
                        .frame(width: 132, height: 132)

                    VStack(spacing: 10) {
                        Text(verbatim: "vamp")
                            .font(.system(size: 58, weight: .bold, design: .rounded))
                            .tracking(-3.2)
                            .foregroundStyle(ControlDesign.ink)
                        Text(verbatim: "CONTROL")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(4.5)
                            .foregroundStyle(ControlDesign.secondary)
                    }
                    .opacity(typeVisible ? 1 : 0)
                    .offset(y: reduceMotion || typeVisible ? 0 : 7)
                }
                .offset(y: -24)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Vamp Control")
        .accessibilityIdentifier("control.launch")
        .task {
            // VoiceOver users go straight to the usable, labelled home screen.
            guard !voiceOverEnabled else { finish(); return }
            do {
                // Give the initial drawing a frame before changing its targets.
                // Wait for SwiftUI's actual completion, not a wall-clock timer
                // that can expire while a cold launch is still doing layout.
                try await Task.sleep(for: .milliseconds(60))
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.62),
                                  completionCriteria: .logicallyComplete) {
                        connected = true
                        typeVisible = true
                    } completion: {
                        continuation.resume()
                    }
                }
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(reduceMotion ? 80 : 280))
            } catch { return }
            finish()
        }
    }
}

private struct ControlLaunchMark: View {
    let connected: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            ControlWindowContour(isHandheld: false)
                .trim(from: 0, to: connected || reduceMotion ? 1 : 0.28)
                .stroke(ControlDesign.accent, style: StrokeStyle(lineWidth: 12.375, lineCap: .round, lineJoin: .round))

            ControlWindowContour(isHandheld: true)
                .stroke(ControlDesign.accent, style: StrokeStyle(lineWidth: 12.375, lineCap: .round, lineJoin: .round))
                .opacity(connected ? 1 : 0)
                .offset(x: connected || reduceMotion ? 0 : 20, y: connected || reduceMotion ? 0 : 14)
        }
        .accessibilityHidden(true)
    }
}

private struct ControlWindowContour: Shape {
    let isHandheld: Bool

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 64
        return Path(isHandheld ? ControlMarkGeometry.handheld() : ControlMarkGeometry.desktop())
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .applying(CGAffineTransform(translationX: rect.midX - 32 * scale,
                                       y: rect.midY - 32 * scale))
    }
}

#Preview("Opening · Light") {
    ControlLaunchView(finish: {}).preferredColorScheme(.light)
}

#Preview("Opening · Dark") {
    ControlLaunchView(finish: {}).preferredColorScheme(.dark)
}
