import SwiftUI
import Discovery

struct DeviceCard: View {
    let title: String
    let subtitle: String
    let isOnline: Bool
    var connectionType: String = "LAN"
    var isTrusted: Bool = true
    var lastSeen: Date?
    var isLoading: Bool = false
    /// Extra capability badges shown below the name row (e.g. "H.264", "HEVC", "Multi-display")
    var capabilities: [String] = []
    var connect: () -> Void

    private var isRelay: Bool { connectionType.lowercased().contains("relay") }

    private var deviceSystemImage: String {
        let lower = title.lowercased()
        if lower.contains("macbook air") { return "macbook.air" }
        if lower.contains("macbook pro") { return "macbook" }
        if lower.contains("macbook") { return "laptopcomputer" }
        if lower.contains("mac mini") { return "macmini" }
        if lower.contains("mac studio") { return "macstudio" }
        if lower.contains("mac pro") { return "macpro.gen3" }
        if lower.contains("imac") { return "desktopcomputer" }
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("ipad") { return "ipad" }
        return "desktopcomputer"
    }

    var body: some View {
        GlassCard(cornerRadius: AppRadius.extraLarge) {
            VStack(spacing: 14) {
                // Header row: icon + name/subtitle + status pills
                HStack(alignment: .top, spacing: 14) {
                    // Icon badge
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill((isOnline ? AppColor.primaryAccent : AppColor.disconnected).opacity(0.10))
                            .frame(width: 52, height: 52)
                        Image(systemName: deviceSystemImage)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(isOnline ? AppColor.primaryAccent : AppColor.disconnected)
                    }

                    // Name + subtitle
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppColor.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Status pills (right column)
                    VStack(alignment: .trailing, spacing: 5) {
                        StatusPill(title: isOnline ? "Online" : "Offline", kind: isOnline ? .connected : .disconnected)
                        if isTrusted {
                            StatusPill(title: "Secure", kind: .secure)
                        }
                    }
                }

                // Meta row: connection type + capabilities + last seen
                HStack(alignment: .center, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            StatusPill(title: connectionType, kind: isRelay ? .relay : .lan)
                            ForEach(capabilities, id: \.self) { cap in
                                StatusPill(title: cap, kind: .lan)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let lastSeen {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption2.weight(.medium))
                            Text(lastSeen.formatted(date: .omitted, time: .shortened))
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(AppColor.textTertiary)
                        .fixedSize()
                    }
                }

                // Connect button
                PrimaryButton(
                    title: isLoading ? "Connecting…" : (isOnline ? "Connect" : "Unavailable"),
                    systemImage: isLoading ? nil : "link",
                    isLoading: isLoading,
                    action: connect
                )
                .disabled(!isOnline || isLoading)
                .opacity(isOnline ? 1 : 0.45)
            }
        }
    }
}
