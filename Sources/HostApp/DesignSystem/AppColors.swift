import SwiftUI

/// Appearance-adaptive palette for the native, system-rendered dashboard.
enum AppColor {
    // Backgrounds — system window/control colors (adapt to light/dark).
    static let backgroundPrimary    = Color(nsColor: .windowBackgroundColor)
    static let backgroundSecondary  = Color(nsColor: .underPageBackgroundColor)
    static let surface              = Color(nsColor: .controlBackgroundColor)
    static let surfaceElevated      = Color(nsColor: .controlBackgroundColor)
    static let glassSurface         = Color.primary.opacity(0.05)

    // Accent + status — system accent for primary, conventional semantics for status.
    static let mint     = Color.accentColor
    static let mintDim  = Color.accentColor.opacity(0.65)
    static let cyan     = Color.accentColor
    static let amber    = Color.orange
    static let red      = Color.red

    static let primaryAccent    = Color.accentColor
    static let secondaryAccent  = Color.accentColor
    static let relayAccent      = Color.orange
    static let lanAccent        = Color.green
    static let success          = Color.green
    static let warning          = Color.orange
    static let error            = Color.red
    static let disconnected     = Color.secondary

    static let textPrimary      = Color.primary
    static let textSecondary    = Color.secondary
    static let textTertiary     = Color.secondary.opacity(0.55)
    static let borderSubtle     = Color.primary.opacity(0.08)

    // Flat system accent retained for source compatibility with existing call sites.
    static let accentGradient = LinearGradient(
        colors: [Color.accentColor, Color.accentColor],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let card   = Color(nsColor: .controlBackgroundColor)
    static let cardHi = Color(nsColor: .controlBackgroundColor)
}

/// The shared architectural backdrop for both host products. The source art is
/// deliberately quieted for interface use; the adaptive veil below supplies a
/// predictable contrast floor so glass cards and text remain legible in either
/// appearance without hiding the engraving at the edges.
struct AppBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .windowBackgroundColor)

                Image("HostBackdrop")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .saturation(colorScheme == .dark ? 0.82 : 0.96)
                    .contrast(colorScheme == .dark ? 1.04 : 1.02)
                    .opacity(reduceTransparency ? 0.44 : (colorScheme == .dark ? 0.78 : 0.88))

                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color.black.opacity(0.18), Color.black.opacity(0.36)]
                        : [Color.white.opacity(0.08), Color(nsColor: .windowBackgroundColor).opacity(0.20)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: colorScheme == .dark
                        ? [Color.black.opacity(0.18), .clear]
                        : [Color.white.opacity(0.14), .clear],
                    center: .center,
                    startRadius: 10,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                )

                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor).opacity(0.32)
                }
            }
            .accessibilityHidden(true)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
