import SwiftUI

/// The quiet content surface that rows, sections, and forms sit on.
///
/// Rows are content, not floating controls, so they get a more opaque fill with a hairline border
/// instead of the conspicuous glass treatment that made every row feel equally important. Native
/// glass stays reserved for navigation bars and genuinely floating controls, per Apple's material
/// guidance.
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
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(PR.card.opacity(isInteractive ? 0.80 : 0.72))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(PR.border, lineWidth: 1)
                    }
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
