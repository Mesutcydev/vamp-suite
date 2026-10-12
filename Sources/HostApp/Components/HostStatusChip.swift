import SwiftUI

/// Compact status capsule for the macOS host UI.
enum HostChipRole {
    case ready       // green — ready, all systems go
    case active      // blue  — connected / active
    case streaming   // blue  — streaming live
    case advertised  // green — LAN discovery running
    case awaiting    // amber — waiting, setup needed
    case stopped     // gray  — idle / stopped
    case error       // red   — error state
}

struct HostStatusChip: View {
    let role: HostChipRole
    var label: String? = nil

    var effectiveLabel: String {
        if let label { return label }
        switch role {
        case .ready:      return "Ready"
        case .active:     return "Active"
        case .streaming:  return "Streaming"
        case .advertised: return "Advertised"
        case .awaiting:   return "Awaiting"
        case .stopped:    return "Stopped"
        case .error:      return "Error"
        }
    }

    var tint: Color {
        switch role {
        case .ready, .advertised: return .green
        case .active, .streaming: return .accentColor
        case .awaiting:           return .orange
        case .stopped:            return .secondary
        case .error:              return .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(effectiveLabel)
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .hostGlassSurface(in: Capsule())
    }
}
