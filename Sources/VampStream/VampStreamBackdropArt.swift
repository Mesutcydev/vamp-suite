import SwiftUI

/// Stream's look, chosen in Settings. Dark is the default because it is what every existing
/// install has always shown; the video surface stays dark in every mode, like any player.
enum VampStreamAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "vampstream.appearance"
    /// Whether the background artwork sits behind the UI. Off gives a plain system background.
    static let backgroundArtKey = "vampstream.showsBackgroundArt"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Stream's artwork follows the appearance: warm white waves in Light, the supplied photo in Dark.
/// With the artwork turned off it is the plain grouped background that solid cards sit on.
struct VampStreamEnvironmentBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var readingContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(VampStreamAppearance.backgroundArtKey) private var showsArt = true

    var body: some View {
        Group {
            if showsArt {
                GeometryReader { proxy in
                    if colorScheme == .light {
                        VampStreamLightArtwork()
                            .overlay(Color.white.opacity(readingContrast == .increased || reduceTransparency ? 0.55 : 0))
                    } else {
                        VampStreamArtwork(size: proxy.size)
                            .overlay(PR.bg.opacity(readingContrast == .increased || reduceTransparency ? 0.35 : 0))
                            .overlay {
                                LinearGradient(
                                    stops: [
                                        .init(color: PR.bg.opacity(0.12), location: 0),
                                        .init(color: PR.bg.opacity(0.10), location: 0.35),
                                        .init(color: PR.bg.opacity(0.18), location: 0.70),
                                        .init(color: PR.bg.opacity(0.28), location: 1)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                    }
                }
            } else {
                PR.bg
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

}

/// A quiet canvas keeps black text crisp without bleaching the dark wallpaper to grey.
/// Vector ribbons fill any iPhone/iPad aspect ratio and leave the heading area nearly white.
private struct VampStreamLightArtwork: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0xFFFDFC), Color(hex: 0xFFF5F0)],
                startPoint: .top, endPoint: .bottom)
            VampStreamLightWave(offset: 0)
                .fill(LinearGradient(
                    colors: [Color(hex: 0xFFE7D8), Color(hex: 0xFFCAB5)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            VampStreamLightWave(offset: 0.10)
                .fill(LinearGradient(
                    colors: [Color(hex: 0xFFDDD7), Color(hex: 0xFFB6A7)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            VampStreamLightWave(offset: 0.20)
                .fill(LinearGradient(
                    colors: [Color(hex: 0xFFE0E2), Color(hex: 0xFFC1CA)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .clipped()
    }
}

private struct VampStreamLightWave: Shape {
    let offset: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let depth: CGFloat = 0.092
        var path = Path()
        path.move(to: CGPoint(x: -0.08 * w, y: (0.47 + offset) * h))
        path.addCurve(
            to: CGPoint(x: 1.08 * w, y: (0.68 + offset) * h),
            control1: CGPoint(x: 0.24 * w, y: (0.59 + offset) * h),
            control2: CGPoint(x: 0.73 * w, y: (0.64 + offset) * h))
        path.addLine(to: CGPoint(x: 1.08 * w, y: (0.68 + offset + depth) * h))
        path.addCurve(
            to: CGPoint(x: -0.08 * w, y: (0.47 + offset + depth) * h),
            control1: CGPoint(x: 0.73 * w, y: (0.64 + offset + depth) * h),
            control2: CGPoint(x: 0.24 * w, y: (0.59 + offset + depth) * h))
        path.closeSubpath()
        return path
    }
}

struct VampStreamArtwork: View {
    let size: CGSize

    var body: some View {
        Image("VampStreamBackdrop")
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: max(size.width, 1), height: max(size.height, 1))
            .clipped()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// Stream's artwork surfaces share readable foreground states in both schemes.
enum StreamReading {
    static let primary = Color.primary
    static let secondary = Color.primary.opacity(0.82)
    static let disabled = Color.primary.opacity(0.60)
    /// The plate under every glass surface while the artwork is on (`prGlassBacking`), so labels
    /// never sit on the artwork's bright curves.
    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x000000, lightAlpha: 0.90, darkAlpha: 0.90)
}
