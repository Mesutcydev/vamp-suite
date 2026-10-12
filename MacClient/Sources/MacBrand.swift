import AppKit
import SwiftUI

/// Neutral, appearance-adaptive design tokens for the Mac client.
///
/// Reskinned to match the host's native macOS redesign: the app follows the
/// system appearance (light/dark) and uses the user's system accent color
/// rather than a fixed brand color. Tokens map to system colors so everything
/// adapts for free.
enum MacBrand {
    static let accent = Color.accentColor

    /// Neutral adaptive page backdrop — the native window background, no wash.
    static var pageBackdrop: some View {
        MacWindowBackdrop()
    }

    static let cardCornerRadius: CGFloat = 12

    /// Display face for the "Vamp Control" wordmark.
    ///
    /// Luminari ships with macOS and is the gothic face the Vamp brand leans on.
    /// `Font.custom(_:size:)` falls back to the system font *silently* when a
    /// face is missing, which would leave the wordmark looking like an
    /// accidentally oversized label — so resolve it through AppKit first and
    /// pick the fallback deliberately. Fixed size: this is chrome, and a
    /// wordmark that grows with the text-size setting would break the toolbar.
    static func wordmarkFont(size: CGFloat) -> Font {
        for name in ["Luminari", "Trattatello"] where NSFont(name: name, size: size) != nil {
            return .custom(name, fixedSize: size)
        }
        return .system(size: size, weight: .semibold, design: .serif)
    }
}

/// Centred toolbar wordmark. Replaces the native window title on the host list,
/// which AppKit crams in beside the leading toolbar items.
struct MacBrandWordmark: View {
    var body: some View {
        Text("Vamp Control")
            .font(MacBrand.wordmarkFont(size: 17))
            .foregroundStyle(.primary)
            .kerning(0.5)
            .lineLimit(1)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }
}

/// The shared Vamp architectural backdrop, matching Vamp Host and Vamp Sync.
///
/// This is what makes the glass work. The window used to be genuinely
/// transparent so Liquid Glass could refract the desktop — but that handed the
/// contrast behind every label to whatever wallpaper the user happened to have,
/// and on a dark one in Light Mode the text became unreadable. Painting the
/// product's own artwork instead gives the glass something rich to sample *and*
/// a predictable contrast floor, via the adaptive veil below.
private struct MacWindowBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
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
                    .opacity(reduceTransparency || contrast == .increased ? 0.12 : (colorScheme == .dark ? 0.42 : 0.40))

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

private struct MacGlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let isInteractive: Bool
    let role: MacGlassSurfaceRole

    @ViewBuilder
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.background {
                GeometryReader { proxy in
                    Color.clear
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .glassEffect(nativeGlass, in: shape)
                        .allowsHitTesting(false)
                }
            }
        } else {
            content.background(role == .content ? .thinMaterial : .ultraThinMaterial, in: shape)
        }
#else
        content.background(role == .content ? .thinMaterial : .ultraThinMaterial, in: shape)
#endif
    }

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    private var nativeGlass: Glass {
        // Chrome can stay highly transparent and let the backdrop art read
        // through; rows carrying text use Apple's denser neutral glass so they
        // keep a contrast floor over the busiest part of the artwork. Neither
        // variant applies a tint.
        let glass: Glass = role == .content ? .regular : .clear
        return glass.interactive(isInteractive)
    }
#endif
}

enum MacGlassSurfaceRole {
    /// Highly transparent — for surfaces that are mostly decoration.
    case chrome
    /// Denser neutral glass — for anything carrying text or controls.
    case content
}

extension View {
    /// Native, colorless Liquid Glass over the Vamp backdrop. The effect is
    /// rendered in a geometry-locked background so it never steals the first
    /// click from its controls.
    func macGlassSurface<S: InsettableShape>(
        in shape: S,
        isInteractive: Bool = false,
        contentLegibility: Bool = true
    ) -> some View {
        modifier(
            MacGlassSurfaceModifier(
                shape: shape,
                isInteractive: isInteractive,
                role: contentLegibility ? .content : .chrome
            )
        )
    }

    /// High-contrast session chrome that stays readable over bright remote video.
    func sessionControlSurface<S: InsettableShape>(in shape: S) -> some View {
        self
            .macGlassSurface(in: shape, isInteractive: true)
            .background {
                shape.fill(.black.opacity(0.42))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.38), radius: 10, y: 4)
            .environment(\.colorScheme, .dark)
    }
}

/// A reusable native glass card shared by the hosts and connection screens.
struct BrandCard<Content: View>: View {
    var hovering: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .macGlassSurface(
                in: RoundedRectangle(cornerRadius: MacBrand.cardCornerRadius, style: .continuous),
                isInteractive: true
            )
            .brightness(hovering ? 0.025 : 0)
    }
}
