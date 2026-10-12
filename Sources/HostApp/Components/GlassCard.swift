import SwiftUI

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = AppRadius.large
    var tint: Color?
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content()
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hostGlassSurface(in: shape, tint: tint)
    }
}

private struct HostGlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let isInteractive: Bool
    let isFloating: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if reduceTransparency {
            decorated(
                content.background(Color(nsColor: .controlBackgroundColor), in: shape)
            )
        } else if #available(macOS 26.0, *) {
            decorated(
                content.background {
                    GeometryReader { proxy in
                        Color.clear
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            // Apple's regular glass is a neutral, adaptive frost:
                            // enough contrast over a bright desktop without a
                            // custom accent wash behind the content.
                            .glassEffect(.regular.interactive(isInteractive), in: shape)
                            .allowsHitTesting(false)
                    }
                }
            )
        } else {
            decorated(
                content.background(.regularMaterial, in: shape)
            )
        }
#else
        if reduceTransparency {
            decorated(
                content.background(Color(nsColor: .controlBackgroundColor), in: shape)
            )
        } else {
            decorated(
                content.background(.regularMaterial, in: shape)
            )
        }
#endif
    }

    private func decorated<Content: View>(_ content: Content) -> some View {
        content
            .overlay {
                shape.strokeBorder(
                    Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.12),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .shadow(
                color: Color.black.opacity(isFloating ? (colorScheme == .dark ? 0.24 : 0.10) : 0.04),
                radius: isFloating ? 18 : 8,
                y: isFloating ? 8 : 3
            )
    }
}

extension View {
    /// Uses Apple's native Liquid Glass on macOS 26 while retaining a material
    /// fallback for every macOS version supported by Vamp Host.
    ///
    /// `tint` remains source-compatible with existing call sites; surfaces use
    /// the system's neutral regular glass, while semantic color stays in content.
    func hostGlassSurface<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        isInteractive: Bool = false,
        isFloating: Bool = false
    ) -> some View {
        modifier(
            HostGlassSurfaceModifier(
                shape: shape,
                isInteractive: isInteractive,
                isFloating: isFloating
            )
        )
    }
}
