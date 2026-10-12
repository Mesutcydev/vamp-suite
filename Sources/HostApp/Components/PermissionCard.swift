import SwiftUI

struct PermissionCard: View {
    let systemImage: String
    let title: String
    let explanation: String
    let status: String
    let kind: AppStatusKind
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(kind.color)
                .frame(width: 34, height: 34)
                .background(
                    kind.color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                )
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(spacing: AppSpacing.sm) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: AppSpacing.sm)
                    StatusPill(title: status, kind: kind)
                }
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                if let actionTitle, let action {
                    SecondaryButton(title: actionTitle, systemImage: "gearshape", action: action)
                        .padding(.top, 2)
                }
            }
        }
        .padding(AppSpacing.md)
        .hostGlassSurface(
            in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous),
            isInteractive: action != nil
        )
    }
}
