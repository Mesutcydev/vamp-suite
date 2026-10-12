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
        case .connected, .secure: return .green
        case .disconnected: return .secondary
        case .pairing, .warning: return .orange
        case .relay, .lan: return .accentColor
        case .error: return .red
        }
    }
}
struct StatusPill: View {
    let title: String
    let kind: AppStatusKind

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(kind.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(kind.color.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(kind.color.opacity(0.20), lineWidth: 0.5))
    }
}
