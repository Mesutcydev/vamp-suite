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
                    .tint(StreamDesign.accent)
                    .padding(.top, 8)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(StreamDesign.secondary)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StreamDesign.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                VampGlassActionButton(title: actionTitle, action: action)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .appQuietSurface()
    }
}
