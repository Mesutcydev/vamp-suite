import SwiftUI

/// Button role for the host macOS UI — drives fill, border, and label color.
enum HostButtonRole {
    case primary      // filled accent blue
    case secondary    // material + border
    case tertiary     // ghost / accent-tinted
    case destructive  // red tint
}

/// A compact, role-aware button for the MacHost utility UI.
struct HostActionButton: View {
    let title: String
    var systemImage: String? = nil
    var role: HostButtonRole = .secondary
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        role: HostButtonRole = .secondary,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity)
        }
        .modifier(RoleStyle(role: role))
        .controlSize(.regular)
    }

    @ViewBuilder
    private var label: some View {
        if let img = systemImage {
            Label(title, systemImage: img)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        } else {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }
}

/// Maps a `HostButtonRole` onto native SwiftUI button styling.
private struct RoleStyle: ViewModifier {
    let role: HostButtonRole

    func body(content: Content) -> some View {
        switch role {
        case .primary:
            content
                .buttonStyle(.borderedProminent)
                .tint(AppColor.primaryAccent)
        case .secondary:
            content
                .buttonStyle(.bordered)
        case .tertiary:
            content
                .buttonStyle(.plain)
                .foregroundStyle(AppColor.primaryAccent)
        case .destructive:
            content
                .buttonStyle(.borderedProminent)
                .tint(AppColor.error)
        }
    }
}
