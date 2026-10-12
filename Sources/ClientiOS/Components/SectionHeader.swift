import SwiftUI

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                HStack(spacing: AppSpacing.xs) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(AppColor.primaryAccent)
                    }
                    Text(title)
                        .font(AppTypography.sectionTitle)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(AppTypography.caption)
            }
        }
    }
}
