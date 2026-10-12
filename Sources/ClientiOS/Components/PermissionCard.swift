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
        GlassCard(cornerRadius: AppRadius.large) {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(kind.color)
                    .frame(width: 44, height: 44)
                    .background(kind.color.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    HStack {
                        Text(title)
                            .font(AppTypography.cardTitle)
                        Spacer()
                        StatusPill(title: status, kind: kind)
                    }
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(AppColor.textSecondary)
                    if let actionTitle, let action {
                        SecondaryButton(title: actionTitle, systemImage: "arrow.up.forward.app", action: action)
                            .padding(.top, AppSpacing.xs)
                    }
                }
            }
        }
    }
}
