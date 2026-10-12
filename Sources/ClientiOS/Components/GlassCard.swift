import SwiftUI

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        cornerRadius: CGFloat = AppRadius.large,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.content = content
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content()
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .prGlassSurface(in: shape)
    }
}

extension View {
    func appGlassCard(cornerRadius: CGFloat = AppRadius.large) -> some View {
        GlassCard(cornerRadius: cornerRadius) { self }
    }
}
