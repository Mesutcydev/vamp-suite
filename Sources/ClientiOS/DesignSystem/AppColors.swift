import Foundation
import SwiftUI

enum AppColor {
    // Structural chrome is deliberately neutral and appearance-adaptive.
    // Accent color communicates selection; green/orange/red communicate state.
    static let backgroundPrimary = Color(uiColor: .systemGroupedBackground)
    static let backgroundSecondary = Color(uiColor: .secondarySystemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let surfaceElevated = Color(uiColor: .tertiarySystemGroupedBackground)
    static let glassSurface = Color.primary.opacity(0.045)
    static let primaryAccent = Color.accentColor
    static let secondaryAccent = Color.accentColor
    static let relayAccent = Color.orange
    static let lanAccent = Color.green
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    static let disconnected = Color.secondary
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color.secondary.opacity(0.72)
    static let borderSubtle = Color.primary.opacity(0.10)

    static let accentGradient = LinearGradient(
        colors: [primaryAccent, primaryAccent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let commandGradient = LinearGradient(
        colors: [
            primaryAccent,
            primaryAccent
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

enum HostNameColor {
    /// Host identity is carried by its name and endpoint, not an arbitrary
    /// rainbow color. Keeping names primary makes discovery, saved-host, and
    /// connection screens match the neutral Vamp host and terminal clients.
    static func color(for id: UUID) -> Color {
        _ = id
        return .primary
    }
}

struct AppBackground: View {
    var body: some View {
        PRAppBackground()
    }
}
