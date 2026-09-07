import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum PR {
    static let bg = Color(uiColor: .systemGroupedBackground)
    static let bg2 = Color(uiColor: .secondarySystemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardHi = Color(uiColor: .tertiarySystemGroupedBackground)

    static let border = Color.primary.opacity(0.08)
    static let borderHi = Color.primary.opacity(0.14)

    static let fg = Color.primary
    static let fg2 = Color.secondary
    static let dim = Color.secondary.opacity(0.68)

    /// Accent is resolved fresh from the palette manager on every access.
    /// `static let` here would cache the first environment-resolved value and
    /// freeze the app on the launch color — the original palette bug.
    static var accent: Color { PaletteManager.shared.selected.color }
    static var accent2: Color { PaletteManager.shared.selected.color }
    // The Vamp surfaces are intentionally monochrome. Severity is conveyed by
    // iconography and copy so warning/error controls never revive the legacy
    // warm accent palette.
    static let warn = Color.primary
    static let err = Color.primary

    static let r6: CGFloat = 6
    static let r8: CGFloat = 8
    static let r12: CGFloat = 16
}

/// User-selectable accent palette. `glass` (colorless) is the default;
/// picking any palette repaints the accent app-wide without a restart.
enum PRPalette: String, CaseIterable, Identifiable {
    case glass
    case blood
    case rose
    case coral
    case amber
    case gold
    case lime
    case green
    case mint
    case ice
    case sky
    case blue
    case indigo
    case violet
    case purple
    case fuchsia
    case pink

    var id: String { rawValue }

    var title: String { rawValue }

    var hex: UInt32 {
        switch self {
        case .glass:  return 0xF5F5F7
        case .blood:  return 0xE5484D
        case .rose:   return 0xF43F5E
        case .coral:  return 0xF9703E
        case .amber:  return 0xF59E0B
        case .gold:   return 0xEAB308
        case .lime:   return 0x84CC16
        case .green:  return 0x22C55E
        case .mint:   return 0x2DD4BF
        case .ice:    return 0x35C6D3
        case .sky:    return 0x38BDF8
        case .blue:   return 0x3B82F6
        case .indigo: return 0x6366F1
        case .violet: return 0x8B5CF6
        case .purple: return 0xA855F7
        case .fuchsia: return 0xD946EF
        case .pink:   return 0xEC4899
        }
    }

    /// The colorless option adapts to the active scheme: near-black on light,
    /// bright neutral on dark — reads as untinted Liquid Glass.
    var color: Color {
        switch self {
        case .glass:
            return Color.dynamic(light: 0x1A1A1A, dark: 0xF5F5F7)
        default:
            return Color(hex: hex)
        }
    }

    static let storageKey = "client.ui.palette"
}

/// Single source of truth for the selected palette. Published so every view
/// that renders `PR.accent` (and the root `.tint`) repaints when it changes.
final class PaletteManager: ObservableObject {
    static let shared = PaletteManager()

    @Published var selected: PRPalette {
        didSet {
            UserDefaults.standard.set(selected.rawValue, forKey: PRPalette.storageKey)
        }
    }

    init() {
        selected = PRPalette(
            rawValue: UserDefaults.standard.string(forKey: PRPalette.storageKey) ?? ""
        ) ?? .glass
    }
}

/// A restrained, neutral canvas behind every system-rendered glass surface.
///
/// Clear Liquid Glass needs real spatial detail behind it to refract. The grid
/// and broad luminance fields are backdrop content only: cards remain untinted
/// `.clear` system glass and Apple owns their blur, refraction, edge light, and
/// scrolling response.
struct PRAppBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
#if canImport(UIKit)
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .systemGroupedBackground)

                if !reduceTransparency {
                    // Brand wallpaper backdrop (shared by both iOS apps). Its explicit
                    // geometry prevents the source image's intrinsic width from widening
                    // a root ZStack and clipping the leading edge on compact iPhones.
                    // Held below the scrim so the artwork stays recognizable but
                    // subordinate to the interface instead of competing with labels.
                    Image("AppBackdrop")
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .opacity(colorScheme == .dark ? 0.72 : 0.44)

                // Legibility scrim keeps glass cards readable over the art. The light-scheme
                // value used to be so faint (0.04) that bright artwork washed out row labels,
                // metadata, and helper text; it is now a real scrim in both schemes.
                Color.black.opacity(colorScheme == .dark ? 0.26 : 0.12)

                LinearGradient(
                    colors: [
                        Color(uiColor: .systemGroupedBackground),
                        Color(uiColor: .secondarySystemGroupedBackground)
                            .opacity(colorScheme == .dark ? 0.40 : 0.34),
                        Color(uiColor: .systemGroupedBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.075 : 0.42),
                                Color.white.opacity(0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 230
                        )
                    )
                    .frame(width: 500, height: 410)
                    .blur(radius: 38)
                    .offset(x: 155, y: -235)

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.black.opacity(colorScheme == .dark ? 0.20 : 0.055),
                                Color.black.opacity(0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 245
                        )
                    )
                    .frame(width: 520, height: 430)
                    .blur(radius: 44)
                    .offset(x: -180, y: 235)

                PRBackdropGrid()

                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.025 : 0.075),
                            Color.clear,
                            Color.black.opacity(colorScheme == .dark ? 0.075 : 0.022)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // iOS may keep light status-bar glyphs while the launch splash
                    // hands off to a light canvas. A short, continuous luminance veil
                    // keeps those glyphs readable without creating a header band or seam.
                    LinearGradient(
                        colors: [
                            Color.black.opacity(colorScheme == .dark ? 0.08 : 0.34),
                            Color.black.opacity(colorScheme == .dark ? 0.025 : 0.08),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 132)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
#else
        PR.bg.ignoresSafeArea()
#endif
    }
}

/// Fine neutral detail for the native material to sample as it moves.
/// This is deliberately background artwork, never a simulated glass overlay.
private struct PRBackdropGrid: View {
    @Environment(\.colorScheme) private var colorScheme

    private let spacing: CGFloat = 26
    private let majorInterval = 4

    var body: some View {
        Canvas { context, size in
            var minorLines = Path()
            var majorLines = Path()

            addLines(
                through: size.width,
                crossAxisLength: size.height,
                vertical: true,
                minorPath: &minorLines,
                majorPath: &majorLines
            )
            addLines(
                through: size.height,
                crossAxisLength: size.width,
                vertical: false,
                minorPath: &minorLines,
                majorPath: &majorLines
            )

            // Barely perceptible: enough structure for the native glass to refract as it moves,
            // not enough to read as a visible grid competing with content. It is background
            // artwork only, never a simulated glass overlay.
            context.stroke(
                minorLines,
                with: .color(Color.primary.opacity(colorScheme == .dark ? 0.020 : 0.016)),
                lineWidth: 0.5
            )
            context.stroke(
                majorLines,
                with: .color(Color.primary.opacity(colorScheme == .dark ? 0.036 : 0.028)),
                lineWidth: 0.6
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func addLines(
        through length: CGFloat,
        crossAxisLength: CGFloat,
        vertical: Bool,
        minorPath: inout Path,
        majorPath: inout Path
    ) {
        let count = Int(ceil(length / spacing))

        for index in 0...count {
            let position = CGFloat(index) * spacing + 0.25
            let isMajor = index.isMultiple(of: majorInterval)

            if vertical {
                if isMajor {
                    majorPath.move(to: CGPoint(x: position, y: 0))
                    majorPath.addLine(to: CGPoint(x: position, y: crossAxisLength))
                } else {
                    minorPath.move(to: CGPoint(x: position, y: 0))
                    minorPath.addLine(to: CGPoint(x: position, y: crossAxisLength))
                }
            } else if isMajor {
                majorPath.move(to: CGPoint(x: 0, y: position))
                majorPath.addLine(to: CGPoint(x: crossAxisLength, y: position))
            } else {
                minorPath.move(to: CGPoint(x: 0, y: position))
                minorPath.addLine(to: CGPoint(x: crossAxisLength, y: position))
            }
        }
    }
}

extension View {
    /// Native, colorless Liquid Glass on current iOS, with a live material
    /// fallback on earlier releases. The material is geometry-locked behind
    /// the foreground so buttons keep their original first-touch hit target.
    ///
    @ViewBuilder
    func prGlassSurface<S: InsettableShape>(
        in shape: S,
        isInteractive: Bool = false
    ) -> some View {
#if os(iOS) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.background {
                GeometryReader { geometry in
                    Color.clear
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .glassEffect(
                            prNativeGlass(isInteractive: isInteractive),
                            in: shape
                        )
                }
            }
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
        }
#else
        self
            .background(.ultraThinMaterial, in: shape)
#endif
    }

}

#if os(iOS) && compiler(>=6.2)
@available(iOS 26.0, *)
private func prNativeGlass(isInteractive: Bool) -> Glass {
    // Apple's high-transparency, neutral Liquid Glass variant. It remains
    // colorless because no tint is supplied, while the system still owns its
    // blur, refraction, edge light, and interactive response.
    var glass: Glass = .clear
    if isInteractive {
        glass = glass.interactive()
    }
    return glass
}
#endif

struct PRGlassPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.9), value: configuration.isPressed)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
#if canImport(UIKit)
        Color(
            UIColor { traits in
                if traits.userInterfaceStyle == .dark {
                    return UIColor(hex: dark, alpha: darkAlpha)
                }
                return UIColor(hex: light, alpha: lightAlpha)
            }
        )
#else
        Color(hex: dark, alpha: darkAlpha)
#endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
#endif

#Preview("PR Tokens") {
    VStack(spacing: 12) {
        RoundedRectangle(cornerRadius: PR.r8)
            .fill(PR.bg)
            .frame(height: 44)
        RoundedRectangle(cornerRadius: PR.r8)
            .fill(PR.card)
            .frame(height: 44)
        RoundedRectangle(cornerRadius: PR.r8)
            .fill(PR.accent)
            .frame(height: 44)
    }
    .padding()
    .background(PR.bg2)
}
