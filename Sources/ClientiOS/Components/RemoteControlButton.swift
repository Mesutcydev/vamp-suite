import SwiftUI

struct RemoteControlButton: View {
    let title: String
    let systemImage: String
    var tint: Color = AppColor.primaryAccent
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            VStack(spacing: AppSpacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                Text(title)
                    .font(AppTypography.caption)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 74)
            .prGlassSurface(
                in: RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous),
                isInteractive: true
            )
        }
        .buttonStyle(PRGlassPressButtonStyle())
    }
}
