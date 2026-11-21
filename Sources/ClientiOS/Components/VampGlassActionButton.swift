import SwiftUI

/// Full-width glass or filled action used on Stream lists and empty states.
struct VampGlassActionButton: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    var isProminent = false
    var isDisabled = false
    let action: () -> Void
    @Environment(\.streamDesign) private var streamDesign

    @ViewBuilder
    var body: some View {
        if streamDesign && isProminent {
            StreamPrimaryButton(title: title, symbol: systemImage ?? "arrow.right", isDisabled: isDisabled, action: action)
        } else if streamDesign {
            Button(action: action) {
                HStack(spacing: 10) {
                    if let systemImage { Image(systemName: systemImage) }
                    Text(title)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StreamDesign.text)
                .frame(maxWidth: .infinity, minHeight: 52)
                .streamGlass(radius: 26)
                .contentShape(Capsule())
            }
            .buttonStyle(StreamPressStyle())
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.45 : 1)
        } else {
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
