import SwiftUI
#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isLoading: Bool = false
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: AppSpacing.xs) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppColor.textPrimary)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(AppTypography.bodyEmphasis)
            }
            .foregroundStyle(AppColor.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .prGlassSurface(
                in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous),
                isInteractive: true
            )
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .disabled(isLoading)
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

enum Haptics {
    static func selection() {
        #if canImport(UIKit) && !os(macOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}
