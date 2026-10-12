import SwiftUI

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: AppSpacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(AppTypography.bodyEmphasis)
            .foregroundStyle(AppColor.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .prGlassSurface(
                in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous),
                isInteractive: true
            )
        }
        .buttonStyle(PRGlassPressButtonStyle())
    }
}
