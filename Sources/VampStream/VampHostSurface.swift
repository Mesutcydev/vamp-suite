import SwiftUI

/// The one status vocabulary both providers share, so "online" means the same thing whether the
/// Mac was found by Vamp Sync discovery or reported by a Vamp Assistant workspace.
enum VampHostAvailability: Equatable {
    case online
    case offline
    case checking
    /// The Mac refused because another device holds its single session. Per-host, not page-wide:
    /// the other Macs stay usable.
    case busy

    /// Colour is always paired with a word. A dot alone is not accessible, and dimming the whole
    /// card until it is unreadable is not a status.
    var tint: Color {
        switch self {
        case .online: return .green
        case .busy: return .orange
        case .offline: return .gray
        case .checking: return .gray
        }
    }

    var label: String {
        switch self {
        case .online: return "Online"
        case .busy: return "In use"
        case .offline: return "Offline"
        case .checking: return "Checking"
        }
    }

    var isPulsing: Bool { self == .checking }

    /// A terminal-only host cannot serve Stream's app browser at all, which is a capability
    /// statement rather than a reachability one.
    static func terminalOnly() -> VampHostAvailability { .offline }
}

/// Compact status: a dot plus a word, sized for a row's trailing slot.
struct VampHostStatusLabel: View {
    let availability: VampHostAvailability

    var body: some View {
        HStack(spacing: AppSpacing.xxs + 1) {
            Circle()
                .fill(availability.tint)
                .frame(width: 7, height: 7)
                .vampHomeLivePulse(
                    isActive: availability.isPulsing, period: 0.9, trough: 0.42)
            Text(availability.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(PR.fg2)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(availability.label)")
    }
}

/// Correct device symbol from real metadata, with a neutral Mac fallback. Guessing a phone or
/// laptop glyph from a name would mislabel the host.
enum VampHostDeviceSymbol {
    static func symbol(isTerminalOnly: Bool) -> String {
        isTerminalOnly ? "terminal" : "macbook"
    }
}
