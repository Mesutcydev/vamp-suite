import SwiftUI

/// Quiet glass empty / no-match hint used by Stream app lists.
struct VampStreamAppListEmptyHint: View {
    let title: LocalizedStringKey
    var isLoading = false
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView()
                    .tint(PR.fg)
                    .padding(.top, 8)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(PR.fg2)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PR.fg2)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                VampGlassActionButton(title: actionTitle, action: action)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.rCard, style: .continuous))
    }
}
