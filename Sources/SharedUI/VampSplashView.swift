import SwiftUI

// Shared Vamp splash for the Mac client and host.

// Self-contained color helper because this module is shared by both Mac apps.
private func vsHex(_ hex: UInt32, _ a: Double = 1) -> Color {
    Color(.sRGB,
          red: Double((hex >> 16) & 0xFF) / 255,
          green: Double((hex >> 8) & 0xFF) / 255,
          blue: Double(hex & 0xFF) / 255,
          opacity: a)
}

public struct VampSplashConfig {
    enum Layout { case iosFullScreen, macPanel }
    enum VisualStyle { case classic, streamGlass }

    var layout: Layout
    var visualStyle: VisualStyle = .classic
    var iconAssetName: String
    var iconSize: CGFloat
    var wordmarkLead: String            // "Vamp"
    var wordmarkAccent: String          // " Remote Control" / " Host"
    var accentColor: Color
    var wordmarkSize: CGFloat
    var taglineSize: CGFloat
    var taglines: [String]              // rotating; single element = static line
    var statusText: String?             // host status pill; nil for clients
    var version: String?                // "Version 1.3.7"; nil for iOS
    var progressWidth: CGFloat

    // palette
    var backgroundStops: [Color]        // 3-stop radial, top → bottom
    var auroraInner: Color
    var auroraMid: Color
    var glowPeakAlpha: Double           // magenta glow behind the icon
    var progressStops: [Color]          // 4-stop shimmer bar

    // per-target loop timings
    var floatPeriod: Double
    var winkPeriod: Double
    var gleamPeriod: Double
    var twinklePeriod: Double
    var taglinePeriod: Double

    public static func iosClient() -> VampSplashConfig {
        // Periods are front-loaded so gleam / wink / twinkle land inside the ~2s
        // launch window. Wall-clock looping periods (3.6–6s) miss those beats entirely
        // before the Vamp splash dismisses the overlay.
        VampSplashConfig(
            layout: .iosFullScreen, iconAssetName: "SplashIcon", iconSize: 116,
            wordmarkLead: "Vamp", wordmarkAccent: " Remote Control", accentColor: vsHex(0x35C6D3),
            wordmarkSize: 29, taglineSize: 14,
            taglines: ["Your Mac, anywhere.", "Private by design.", "Ready when you are."],
            statusText: nil, version: nil, progressWidth: 132,
            backgroundStops: [vsHex(0x171733), vsHex(0x0C0B1A), vsHex(0x07060E)],
            auroraInner: vsHex(0x2E7BFF, 0.30), auroraMid: vsHex(0xF01E63, 0.15), glowPeakAlpha: 0.42,
            progressStops: [vsHex(0x7FB0FF, 0.12), vsHex(0x7FB0FF, 0.9), vsHex(0xFF5A7D, 0.9), vsHex(0x7FB0FF, 0.12)],
            floatPeriod: 2.8, winkPeriod: 2.0, gleamPeriod: 1.8, twinklePeriod: 1.6, taglinePeriod: 2.4)
    }

    /// Vamp Stream has its own product name and launch copy while reusing the
    /// shared splash animation and icon asset.
    public static func vampStream() -> VampSplashConfig {
        var config = VampSplashConfig(
            layout: .iosFullScreen, iconAssetName: "VampStreamSplashIcon", iconSize: 116,
            wordmarkLead: "Vamp", wordmarkAccent: " Stream", accentColor: vsHex(0x000000),
            wordmarkSize: 29, taglineSize: 14,
            taglines: ["Use a Mac App on your iPhone.", "Private by design.", "Ready to connect."],
            statusText: nil, version: nil, progressWidth: 132,
            backgroundStops: [vsHex(0x1B213A), vsHex(0x0C101B), vsHex(0x07080D)],
            auroraInner: vsHex(0x3E8BFF, 0.30), auroraMid: vsHex(0xFF8A38, 0.16), glowPeakAlpha: 0.42,
            progressStops: [vsHex(0x82B8FF, 0.12), vsHex(0x82B8FF, 0.9), vsHex(0xFF9A3D, 0.9), vsHex(0x82B8FF, 0.12)],
            floatPeriod: 2.8, winkPeriod: 2.0, gleamPeriod: 1.8, twinklePeriod: 1.6, taglinePeriod: 2.4)
        config.visualStyle = .streamGlass
        return config
    }

    public static func macClient(version: String) -> VampSplashConfig {
        VampSplashConfig(
            layout: .macPanel, iconAssetName: "SplashIcon", iconSize: 92,
            wordmarkLead: "Vamp", wordmarkAccent: " Remote Control", accentColor: vsHex(0x35C6D3),
            wordmarkSize: 26, taglineSize: 13.5,
            taglines: ["Your Mac, anywhere.", "Private by design."],
            statusText: nil, version: version, progressWidth: 150,
            backgroundStops: [vsHex(0x191835), vsHex(0x0D0C1C), vsHex(0x08070F)],
            auroraInner: vsHex(0x2E7BFF, 0.28), auroraMid: vsHex(0xF01E63, 0.14), glowPeakAlpha: 0.40,
            progressStops: [vsHex(0x7FB0FF, 0.12), vsHex(0x7FB0FF, 0.9), vsHex(0xFF5A7D, 0.9), vsHex(0x7FB0FF, 0.12)],
            floatPeriod: 4.6, winkPeriod: 6.0, gleamPeriod: 3.6, twinklePeriod: 3.6, taglinePeriod: 8.0)
    }

    public static func host(version: String, statusText: String) -> VampSplashConfig {
        VampSplashConfig(
            layout: .macPanel, iconAssetName: "SplashIcon", iconSize: 92,
            wordmarkLead: "Vamp", wordmarkAccent: " Host", accentColor: vsHex(0x35C6D3),
            wordmarkSize: 26, taglineSize: 13.5,
            taglines: ["Sharing this Mac."],
            statusText: statusText, version: version, progressWidth: 150,
            backgroundStops: [vsHex(0x1C1330), vsHex(0x120B1C), vsHex(0x0A060F)],
            auroraInner: vsHex(0xF01E63, 0.30), auroraMid: vsHex(0xB428C8, 0.12), glowPeakAlpha: 0.45,
            progressStops: [vsHex(0xFF5A7D, 0.12), vsHex(0xFF5A7D, 0.9), vsHex(0xC83CDC, 0.9), vsHex(0xFF5A7D, 0.12)],
            floatPeriod: 4.8, winkPeriod: 6.4, gleamPeriod: 4.0, twinklePeriod: 4.0, taglinePeriod: 9.0)
    }
}

// MARK: - Animation math

/// Piecewise-linear track over a normalized phase [0,1). `stops` must span 0…1.
private func track(_ phase: Double, _ stops: [(Double, Double)]) -> Double {
    for i in 1..<stops.count {
        if phase <= stops[i].0 {
            let (p0, v0) = stops[i - 1]
            let (p1, v1) = stops[i]
            let span = p1 - p0
            let f = span <= 0 ? 0 : (phase - p0) / span
            return v0 + (v1 - v0) * f
        }
    }
    return stops.last?.1 ?? 0
}

/// Smooth (raised-cosine) oscillation `a → b → a` over one period. Reads as ease-in-out.
private func wave(_ phase: Double, _ a: Double, _ b: Double) -> Double {
    a + (b - a) * (1 - cos(2 * .pi * phase)) / 2
}

private func phase(_ t: Double, _ period: Double) -> Double {
    (t.truncatingRemainder(dividingBy: period)) / period
}

// MARK: - View

struct VampSplashView: View {
    let config: VampSplashConfig
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Elapsed-time origin so gleam/wink/twinkle always start at phase 0 when the
    /// splash appears. Wall-clock `timeIntervalSinceReferenceDate` lands at a random
    /// phase, which often skips the short "punch" beats during a ~2s launch splash.
    @State private var startedAt = Date()

    var body: some View {
        Group {
            if reduceMotion {
                composition(t: 0, motion: false)
            } else {
                TimelineView(.animation) { context in
                    composition(t: context.date.timeIntervalSince(startedAt), motion: true)
                }
            }
        }
    }

    @ViewBuilder
    private func composition(t: Double, motion: Bool) -> some View {
        switch config.layout {
        case .iosFullScreen:
            if config.visualStyle == .streamGlass {
                streamGlassContent(t: t, motion: motion)
                    .ignoresSafeArea()
            } else {
                panelContent(t: t, motion: motion)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(background)
                    .ignoresSafeArea()
            }
        case .macPanel:
            // Full-bleed: the splash fills its whole window (see the splash window, which sizes
            // that window to cover the app window). A small fixed card floating in the large app
            // window read as tiny and let the shell's focus rings/toolbar bleed around it.
            panelContent(t: t, motion: motion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(background)
                // Top highlight line, matching the design's panel edge.
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(0.14), .white.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 1)
                }
        }
    }

    private var background: some View {
        RadialGradient(colors: config.backgroundStops,
                       center: .top, startRadius: 0, endRadius: 640)
    }

    private func streamGlassContent(t: Double, motion: Bool) -> some View {
        StreamConnectionSplash(t: t, motion: motion)
    }

    // MARK: composition layers

    @ViewBuilder
    private func panelContent(t: Double, motion: Bool) -> some View {
        ZStack {
            aurora(t: t, motion: motion)

            VStack(spacing: 0) {
                iconGroup(t: t, motion: motion)
                wordmark
                    .padding(.top, config.layout == .iosFullScreen ? 32 : 22)
                taglineArea(t: t, motion: motion)
                    .padding(.top, config.layout == .iosFullScreen ? 11 : 8)
                if let statusText = config.statusText {
                    statusPill(statusText, t: t, motion: motion)
                        .padding(.top, 16)
                }
            }
            .offset(y: config.layout == .iosFullScreen ? -24 : -14)

            VStack(spacing: 12) {
                Spacer()
                progressBar(t: t, motion: motion)
                if let version = config.version {
                    Text(version)
                        .font(.system(size: 11, weight: .regular))
                        .tracking(0.06 * 11)
                        .foregroundColor(vsHex(0x5F5E78))
                }
            }
            .padding(.bottom, config.layout == .iosFullScreen ? 50 : 40)
        }
    }

    private var wordmark: some View {
        (Text(config.wordmarkLead).foregroundColor(.white)
            + Text(config.wordmarkAccent).foregroundColor(config.accentColor))
            .font(.system(size: config.wordmarkSize, weight: .heavy))
            .tracking(-0.01 * config.wordmarkSize)
    }

    private func iconGroup(t: Double, motion: Bool) -> some View {
        let size = config.iconSize
        let radius = size * 0.225

        let floatY = motion ? wave(phase(t, config.floatPeriod), 0, -7) : 0
        let floatRot = motion ? wave(phase(t, config.floatPeriod), 0, 0.5) : 0
        let winkRot = motion ? track(phase(t, config.winkPeriod),
                                     [(0, 0), (0.66, 0), (0.74, -8), (0.84, 5), (0.92, 0), (1, 0)]) : 0

        let gp = phase(t, config.gleamPeriod)
        let gleamX = motion ? track(gp, [(0, -0.7), (0.24, 1.2), (1, 1.2)]) : -0.7
        let gleamOpacity = motion ? track(gp, [(0, 0), (0.08, 0.85), (0.24, 0), (1, 0)]) : 0

        let tp = phase(t, config.twinklePeriod)
        let twinkleOpacity = motion ? track(tp, [(0, 0), (0.55, 0), (0.68, 1), (0.80, 0.35), (0.90, 0.9), (1, 0)]) : 0
        let twinkleScale = motion ? track(tp, [(0, 0.3), (0.55, 0.3), (0.68, 1), (0.80, 0.6), (0.90, 0.85), (1, 0.3)]) : 0.85
        let twinkleRot = motion ? track(tp, [(0, 0), (0.68, 25), (0.90, 45), (1, 0)]) : 0

        let glowOpacity = motion ? wave(phase(t, 4.5), 0.45, 0.9) : 0.7
        let glowScale = motion ? wave(phase(t, 4.5), 0.9, 1.12) : 1.0

        return ZStack {
            // magenta glow behind the icon
            Circle()
                .fill(RadialGradient(
                    colors: [vsHex(0xF01E63, config.glowPeakAlpha), vsHex(0xF01E63, 0)],
                    center: .center, startRadius: 0, endRadius: size * 1.25))
                .frame(width: size * 2.5, height: size * 2.5)
                .scaleEffect(glowScale)
                .opacity(glowOpacity)

            ZStack {
                Image(config.iconAssetName)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .overlay(
                        // diagonal gleam sweep, clipped to the squircle
                        Rectangle()
                            .fill(LinearGradient(
                                colors: [.white.opacity(0), .white.opacity(0.6), .white.opacity(0)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: size * 0.4)
                            .rotationEffect(.degrees(22))
                            .offset(x: gleamX * size)
                            .opacity(gleamOpacity))
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .shadow(color: vsHex(0xF01E63, 0.6), radius: 19, x: 0, y: 15)

                // sparkle at a fang tip (~76% x / 58% y of the icon box)
                Text("✦")
                    .font(.system(size: size * 0.14))
                    .foregroundColor(.white)
                    .shadow(color: .white.opacity(0.9), radius: 4)
                    .scaleEffect(twinkleScale)
                    .rotationEffect(.degrees(twinkleRot))
                    .opacity(twinkleOpacity)
                    .offset(x: size * (0.76 - 0.5), y: size * (0.58 - 0.5))
            }
            .rotationEffect(.degrees(winkRot), anchor: UnitPoint(x: 0.5, y: 0.6))
        }
        .rotationEffect(.degrees(floatRot))
        .offset(y: floatY)
    }

    @ViewBuilder
    private func taglineArea(t: Double, motion: Bool) -> some View {
        let lines = config.taglines
        if lines.count <= 1 {
            Text(lines.first ?? "")
                .font(.system(size: config.taglineSize, weight: .medium))
                .foregroundColor(vsHex(0x9EA6C6))
                .frame(height: 22)
        } else {
            let p = motion ? phase(t, config.taglinePeriod) : 0
            ZStack {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    let (opacity, dy) = motion ? taglineState(p, index, lines.count)
                                                : (index == 0 ? 1 : 0, 0)
                    Text(line)
                        .font(.system(size: config.taglineSize, weight: .medium))
                        .foregroundColor(vsHex(0x9EA6C6))
                        .opacity(opacity)
                        .offset(y: dy)
                }
            }
            .frame(width: 320, height: 22)
        }
    }

    /// One tagline is on screen at a time: slides up + fades in, holds, fades up + out.
    private func taglineState(_ phase: Double, _ index: Int, _ count: Int) -> (Double, CGFloat) {
        let f = phase * Double(count) - Double(index)
        guard f >= 0, f < 1 else { return (0, 0) }
        let opacity = track(f, [(0, 0), (0.12, 1), (0.82, 1), (1, 0)])
        let dy = track(f, [(0, 9), (0.12, 0), (0.82, 0), (1, -9)])
        return (opacity, dy)
    }

    private func statusPill(_ text: String, t: Double, motion: Bool) -> some View {
        let dotOpacity = motion ? wave(phase(t, 1.8), 0.5, 1.0) : 0.9
        let dotScale = motion ? wave(phase(t, 1.8), 0.85, 1.1) : 1.0
        return HStack(spacing: 8) {
            Circle()
                .fill(vsHex(0x33D17A))
                .frame(width: 8, height: 8)
                .shadow(color: vsHex(0x33D17A), radius: 4)
                .scaleEffect(dotScale)
                .opacity(dotOpacity)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(vsHex(0x8FE0B4))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
        .background(vsHex(0x2EC878, 0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(vsHex(0x2EC878, 0.25), lineWidth: 1))
    }

    private func progressBar(t: Double, motion: Bool) -> some View {
        // Shimmer: a wide gradient (2× the bar) slides right → left, background-position 200% → -200%.
        let width = config.progressWidth
        let travel = motion ? (0.5 - phase(t, 2.4)) * 2 * width * 2 : 0
        return LinearGradient(colors: config.progressStops, startPoint: .leading, endPoint: .trailing)
            .frame(width: width * 2, height: 4)
            .offset(x: travel)
            .frame(width: width, height: 4)
            .clipShape(Capsule())
    }

    private func aurora(t: Double, motion: Bool) -> some View {
        let big = config.layout == .iosFullScreen ? CGFloat(360) : 420
        let dx = motion ? wave(phase(t, 9), 0, 22) : 11
        let dy = motion ? wave(phase(t, 9), 0, 18) : 9
        let scale = motion ? wave(phase(t, 9), 1.0, 1.18) : 1.09
        return Circle()
            .fill(RadialGradient(
                colors: [config.auroraInner, config.auroraMid, .clear],
                center: UnitPoint(x: 0.42, y: 0.42), startRadius: 0, endRadius: big * 0.35))
            .frame(width: big, height: big)
            .scaleEffect(scale)
            .offset(x: dx, y: -big * 0.28 + dy)
    }
}

private struct StreamConnectionSplash: View {
    let t: Double
    let motion: Bool

    private var reveal: Double {
        guard motion else { return 1 }
        let value = min(max(t / 0.62, 0), 1)
        return value * value * (3 - 2 * value)
    }

    private var pulse: Double {
        guard motion else { return 0.58 }
        return t.truncatingRemainder(dividingBy: 1.15) / 1.15
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                StreamSplashBackdrop(size: geometry.size, reveal: reveal)
                StreamSplashBrand()
                    .padding(.top, max(geometry.safeAreaInsets.top, 54) + 12)
                    .frame(maxHeight: .infinity, alignment: .top)

                StreamSplashConnection(pulse: pulse, reveal: reveal)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.43)

                StreamSplashCopy(reveal: reveal)
                    .padding(.horizontal, 28)
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom, 18) + 34)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color.black)
        }
    }
}

private struct StreamSplashBackdrop: View {
    let size: CGSize
    let reveal: Double

    var body: some View {
        Image("VampStreamBackdrop")
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .scaleEffect(1.035 + (0.015 * (1 - reveal)))
            .clipped()
            .overlay {
                LinearGradient(
                    colors: [
                        .black.opacity(0.42),
                        .black.opacity(0.06),
                        .clear,
                        .black.opacity(0.12),
                        .black.opacity(0.62)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }
}

private struct StreamSplashBrand: View {
    var body: some View {
        VStack(spacing: 5) {
            Text("VAMP STREAM")
                .font(.system(size: 13, weight: .semibold))
                .tracking(3.2)
                .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.90).opacity(0.92))
            Text("STREAM MAC APPS TO YOUR iPHONE")
                .font(.system(size: 10, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.90).opacity(0.65))
        }
    }
}

private struct StreamSplashConnection: View {
    let pulse: Double
    let reveal: Double

    var body: some View {
        HStack(spacing: 18) {
            device(systemName: "macbook", label: "Mac")
            ZStack {
                Capsule()
                    .fill(Color(red: 0.96, green: 0.94, blue: 0.90).opacity(0.25))
                    .frame(width: 92, height: 1.5)
                Circle()
                    .fill(Color(red: 0.96, green: 0.94, blue: 0.90))
                    .frame(width: 6.5, height: 6.5)
                    .shadow(color: Color(red: 0.96, green: 0.94, blue: 0.90).opacity(0.85), radius: 8)
                    .offset(x: -43 + (86 * pulse))
            }
            .frame(width: 92, height: 24)
            device(systemName: "iphone", label: "iPhone")
        }
        .offset(y: 12 * (1 - reveal))
        .opacity(reveal)
    }

    private func device(systemName: String, label: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 38, weight: .light))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.90))
                .frame(width: 58, height: 58)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.90).opacity(0.65))
        }
    }
}

private struct StreamSplashCopy: View {
    let reveal: Double

    var body: some View {
        VStack(spacing: 8) {
            Text("Vamp Stream")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .tracking(-0.5)
                .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.90))
            Text("Stream Mac Apps to Your iPhone")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.90).opacity(0.72))
            Text("WORK  •  CREATE  •  PLAY  •  ANYWHERE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(2.2)
                .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.90).opacity(0.48))
                .padding(.top, 4)
        }
        .offset(y: 10 * (1 - reveal))
        .opacity(reveal)
    }
}

// MARK: - Presentation

public extension View {
    /// Overlays the Vamp splash on launch, then cross-fades it out after `minimumDuration`.
    /// Pass `enabled: false` when the window won't actually be shown to the user — e.g. the
    /// host launches straight into the menu bar when its desktop widget is installed, which
    /// order-outs the window and would otherwise make the splash flash for a frame and vanish.
    func vampSplash(_ config: VampSplashConfig, minimumDuration: Double = 1.9, enabled: Bool = true) -> some View {
        modifier(VampSplashPresenter(config: config, minimumDuration: minimumDuration, enabled: enabled))
    }
}

private struct VampSplashPresenter: ViewModifier {
    let config: VampSplashConfig
    let minimumDuration: Double
    let enabled: Bool
    @State private var visible = true

    func body(content: Content) -> some View {
        content.overlay {
            if enabled && visible {
                VampSplashView(config: config)
                    // Opaque hit target so the home UI can't flash through or steal taps
                    // while the splash is up (especially during the first-run welcome).
                    .allowsHitTesting(true)
                    .zIndex(1000)
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(nanoseconds: UInt64(minimumDuration * 1_000_000_000))
                        withAnimation(.easeOut(duration: 0.5)) { visible = false }
                    }
            }
        }
    }
}

#if os(macOS)
import AppKit

public extension View {
    /// macOS launch splash. Presents the splash in its own borderless window sized to *cover*
    /// the app window, then fades it out after `minimumDuration`. A covering window (not an
    /// in-window overlay) is what makes it look right: it fills the frame so it never reads as a
    /// tiny card, and nothing from the app window — toolbar items, a focused field's blue ring —
    /// can render over or around it. `enabled: false` = no-op (e.g. host launching into the tray).
    func vampSplashWindow(_ config: VampSplashConfig, minimumDuration: Double = 1.9, enabled: Bool = true) -> some View {
        background(VampSplashLauncher(config: config, minimumDuration: minimumDuration, enabled: enabled))
    }
}

private struct VampSplashLauncher: NSViewRepresentable {
    let config: VampSplashConfig
    let minimumDuration: Double
    let enabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        guard enabled else { return probe }
        // Resolve the host window (not attached during makeNSView); retry a few ticks in case
        // it lands late, then give up so we never show the splash without a window to cover.
        resolveWindow(probe: probe, coordinator: context.coordinator, attempt: 0)
        return probe
    }

    private func resolveWindow(probe: NSView?, coordinator: Coordinator, attempt: Int) {
        DispatchQueue.main.async { [weak probe] in
            guard !coordinator.presented else { return }
            if let parent = probe?.window {
                coordinator.presented = true
                coordinator.present(config: config, minimumDuration: minimumDuration, over: parent)
            } else if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    resolveWindow(probe: probe, coordinator: coordinator, attempt: attempt + 1)
                }
            }
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator {
        var presented = false
        private var splash: NSWindow?

        func present(config: VampSplashConfig, minimumDuration: Double, over parent: NSWindow) {
            let window = NSWindow(contentRect: parent.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            // Clip to the window's own corner radius so the covering splash lines up with the
            // app window's rounded corners instead of overhanging them with square corners.
            let root = VampSplashView(config: config)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            window.contentView = NSHostingView(rootView: root)
            window.setFrame(parent.frame, display: true)
            parent.addChildWindow(window, ordered: .above)
            splash = window

            DispatchQueue.main.asyncAfter(deadline: .now() + minimumDuration) { [weak self, weak parent] in
                guard let self, let window = self.splash else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.5
                    window.animator().alphaValue = 0
                }, completionHandler: {
                    parent?.removeChildWindow(window)
                    window.orderOut(nil)
                    self.splash = nil
                })
            }
        }
    }
}
#endif
