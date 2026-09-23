import SwiftUI

/// Stream's look, chosen in Settings. Dark is the default because it is what every existing
/// install has always shown; the video surface stays dark in every mode, like any player.
enum VampStreamAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "vampstream.appearance"
    /// Whether the corridor artwork sits behind the UI. Off gives a plain system background.
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

/// Full corridor artwork, rendered from the high-resolution master without stretching.
/// With the artwork turned off it is the plain grouped background that solid cards sit on.
struct VampStreamEnvironmentBackdrop: View {
    @Environment(\.colorSchemeContrast) private var readingContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(VampStreamAppearance.backgroundArtKey) private var showsArt = true

    var body: some View {
        Group {
            if showsArt {
                GeometryReader { proxy in
                    // The scrim is the scheme's own background colour, so the same artwork reads
                    // as a dark corridor in Dark and a pale one in Light.
                    VampStreamArtwork(size: proxy.size)
                        .overlay(scrim.opacity(readingContrast == .increased || reduceTransparency ? 0.35 : 0))
                        .overlay {
                            LinearGradient(
                                stops: [
                                    .init(color: scrim.opacity(0.82), location: 0),
                                    .init(color: scrim.opacity(0.72), location: 0.35),
                                    .init(color: scrim.opacity(0.72), location: 0.70),
                                    .init(color: scrim.opacity(0.82), location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
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

    private var scrim: Color { Color(uiColor: .systemBackground) }
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
    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x000000, lightAlpha: 0.90, darkAlpha: 0.90)
}

extension View {
    /// The plate that keeps labels legible over the bright portal artwork. With the artwork off
    /// there is nothing to guard against, and the solid card underneath already is the surface.
    func streamReadingSurface<S: Shape>(in shape: S) -> some View {
        modifier(StreamReadingSurface(shape: shape))
    }
}

private struct StreamReadingSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.prSolidSurfaces) private var solidSurfaces

    func body(content: Content) -> some View {
        content.background {
            if !solidSurfaces { shape.fill(StreamReading.surface) }
        }
    }
}
