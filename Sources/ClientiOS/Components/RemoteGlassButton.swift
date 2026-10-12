import SwiftUI

/// Floating overlay button used for stream controls.
/// Glass pill — no colored badge box, icon tinted by `tint`, text in SF Rounded.
struct RemoteGlassButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
    var isIconOnly: Bool = false
    var isActive: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                if !isIconOnly {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppColor.textPrimary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, isIconOnly ? 13 : 15)
            .frame(height: 42)
            .prGlassSurface(
                in: Capsule(style: .continuous),
                isInteractive: true
            )
            .overlay(alignment: .bottom) {
                if isActive {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                        .padding(.bottom, -3)
                }
            }
        }
        .buttonStyle(StreamControlButtonStyle())
    }
}

private struct StreamControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.24, dampingFraction: 0.9), value: configuration.isPressed)
    }
}
