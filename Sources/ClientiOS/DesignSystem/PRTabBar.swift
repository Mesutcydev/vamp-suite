import SwiftUI

enum PRAppTab: String, CaseIterable, Identifiable {
    case mirror
    case hosts
    case keys
    case screens
    case config

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .mirror: "display"
        case .hosts: "network"
        case .keys: "command"
        case .screens: "rectangle.3.group"
        case .config: "slider.horizontal.3"
        }
    }
}

struct PRTabBar: View {
    @Binding var active: PRAppTab
    @Namespace private var cursor

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PRAppTab.allCases) { tab in
                let isOn = tab == active
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                        active = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14))
                        Text(tab.rawValue)
                            .font(.caption2.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundColor(isOn ? PR.fg : PR.dim)
                    .background {
                        if isOn {
                            RoundedRectangle(cornerRadius: PR.r8)
                                .fill(PR.fg.opacity(0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: PR.r8)
                                        .strokeBorder(PR.fg.opacity(0.12), lineWidth: 0.5)
                                )
                                .matchedGeometryEffect(id: "cursor", in: cursor)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: PR.r8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tab \(tab.rawValue)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 22)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

#Preview("PRTabBar") {
    PreviewPRTabBar()
}

private struct PreviewPRTabBar: View {
    @State private var tab: PRAppTab = .mirror

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            PRTabBar(active: $tab)
        }
        .background(PR.bg)
    }
}
