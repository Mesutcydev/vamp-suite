import SwiftUI

/// Full-width glass or filled action used on Stream lists and empty states.
struct VampGlassActionButton: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    var isProminent = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isProminent ? PR.bg : PR.fg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                if isProminent {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(PR.fg)
                }
            }
            .modifier(VampGlassActionChrome(isProminent: isProminent))
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .accessibilityAddTraits(.isButton)
    }
}

private struct VampGlassActionChrome: ViewModifier {
    let isProminent: Bool

    func body(content: Content) -> some View {
        if isProminent {
            content
        } else {
            content.prGlassSurface(
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                isInteractive: true
            )
        }
    }
}
