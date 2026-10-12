import SwiftUI

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        GlassCard(cornerRadius: AppRadius.extraLarge) {
            VStack(spacing: AppSpacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(AppColor.primaryAccent)
                    .frame(width: 84, height: 84)
                    .background(AppColor.primaryAccent.opacity(0.10), in: Circle())
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .multilineTextAlignment(.center)
                if let actionTitle, let action {
                    PrimaryButton(title: actionTitle, systemImage: "arrow.right", action: action)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.lg)
        }
    }
}
