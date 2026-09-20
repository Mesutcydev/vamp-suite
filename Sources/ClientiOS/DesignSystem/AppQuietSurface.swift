import SwiftUI

/// The shared quiet card surface. It is still native colorless glass, but uses the calmer list
/// density so repeated rows do not compete with controls.
///
/// Lives in the shared DesignSystem because both app pickers (Vamp Sync in `ClientiOS`, Vamp
/// Assistant in `VampStream`) and the connect home use it, and `Sources/ClientiOS` is compiled by
/// app targets that never see `Sources/VampStream`.
struct AppQuietSurface: ViewModifier {
    var cornerRadius: CGFloat = AppHostMetrics.cardRadius
    /// Slightly stronger fill for an interactive surface so it still reads as tappable.
    var isInteractive: Bool = false

    func body(content: Content) -> some View {
        content
            .prGlassSurface(
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                isInteractive: isInteractive,
                role: .listRow
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(PR.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func appQuietSurface(
        cornerRadius: CGFloat = AppHostMetrics.cardRadius,
        isInteractive: Bool = false
    ) -> some View {
        modifier(AppQuietSurface(cornerRadius: cornerRadius, isInteractive: isInteractive))
    }
}
