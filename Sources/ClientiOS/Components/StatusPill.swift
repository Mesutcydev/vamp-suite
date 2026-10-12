import SwiftUI

enum AppStatusKind {
    case connected
    case disconnected
    case pairing
    case relay
    case lan
    case secure
    case warning
    case error

    var color: Color {
        switch self {
        case .connected, .secure: return AppColor.success
        case .disconnected: return AppColor.disconnected
        case .pairing, .warning: return AppColor.warning
        case .relay: return AppColor.relayAccent
        case .lan: return AppColor.lanAccent
        case .error: return AppColor.error
        }
    }
}
struct StatusPill: View {
    let title: String
    let kind: AppStatusKind

    var body: some View {
        Text(title)
            .font(AppTypography.label)
            .foregroundStyle(kind.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(kind.color.opacity(0.13), in: Capsule())
            .overlay(Capsule().strokeBorder(kind.color.opacity(0.22), lineWidth: 0.8))
            .accessibilityLabel(title)
    }
}
