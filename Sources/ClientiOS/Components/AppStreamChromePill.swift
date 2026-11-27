import SwiftUI

/// Layout metrics for the floating glass dock, shared by the deck and the surfaces that reserve
/// space for it. Deliberately non-generic: `AppStreamChromePill` itself is generic over its
/// content, so call sites should not have to name `EmptyView` just to read a number.
enum AppStreamChromeBar {
    /// 44 pt controls with breathing room inside the 60 pt lens.
    static var height: CGFloat { 60 }
    /// Vamp Control's dock: a caption under each control, so the bar says what it does.
    static var labelledHeight: CGFloat { 72 }
    static var labelledControlWidth: CGFloat { 60 }
    static var labelledControlHeight: CGFloat { 56 }
    /// Gap between the housing and the bottom edge, on top of the safe-area floor below.
    static var bottomMargin: CGFloat { 8 }
    /// Horizontal inset of the housing from the screen edges.
    static var edgeInset: CGFloat { 18 }
    /// Smallest bottom gap used when the surface sits inside an ignored safe area (where the
    /// inset can read as zero). The Assistant bar uses the same 10 pt floor.
    static var bottomFloor: CGFloat { 10 }

    /// How much of the stream surface the deck occupies, so the picture is never laid out
    /// underneath it. It lives here, with the deck, because both host paths used to keep
    /// their own copy of the number — and when the controls change size, two separate
    /// constants would have to be found and changed together.
    static func reservedBand(safeAreaBottom: CGFloat, height: CGFloat = AppStreamChromeBar.height) -> CGFloat {
        height + bottomMargin + max(safeAreaBottom, bottomFloor)
    }
}

/// One glass dock for both providers. The hide control stays pinned outside the scroll
/// region; less-used and destructive actions live in the options menu.
struct AppStreamChromePill<Content: View, Trailing: View>: View {
    var height: CGFloat = AppStreamChromeBar.height
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    content()
                }
                .padding(.vertical, 4)
                .padding(.leading, 2)
            }
            .scrollIndicators(.hidden)
            trailing()
        }
        .padding(.trailing, 2)
        .frame(height: height)
        .frame(maxWidth: 520)
        .streamGlass(radius: 30, elevated: true)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// The way back to the app list, labelled, so it can't be mistaken for a menu. The grid glyph it
/// replaces was easy to miss and scrolled away with the other controls.
struct AppStreamChromeBackButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.selection()
            action()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12)
            .frame(height: AppHostMetrics.iconControlTarget)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityHint("Returns to the Mac's app list")
    }
}

/// One icon button inside `AppStreamChromePill`, rendered as a glass dock control.
struct AppStreamChromeButton: View {
    let systemName: String
    var isActive: Bool = false
    var isDimmed: Bool = false
    var isDestructive: Bool = false
    var accessibilityLabel: String? = nil
    var accessibilityValue: String? = nil
    var title: LocalizedStringKey? = nil
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.selection()
            action()
        } label: {
            AppStreamChromeLabel(
                systemName: systemName,
                isActive: isActive,
                isDimmed: isDimmed,
                isDestructive: isDestructive,
                title: title)
        }
        .buttonStyle(AppStreamChromeKeyStyle(prominent: isDestructive, isSelected: isActive))
        .modifier(AppStreamChromeAccessibility(label: accessibilityLabel, value: accessibilityValue))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// A circular dock menu for controls that expand into choices
/// (window sizing, displays, stream options).
struct AppStreamChromeMenu<MenuContent: View>: View {
    let systemName: String
    var isActive: Bool = false
    var isDimmed: Bool = false
    let accessibilityLabel: String
    var accessibilityValue: String? = nil
    var title: LocalizedStringKey? = nil
    @ViewBuilder var menuContent: () -> MenuContent

    var body: some View {
        Menu {
            menuContent()
        } label: {
            AppStreamChromeLabel(
                systemName: systemName,
                isActive: isActive,
                isDimmed: isDimmed,
                isDestructive: false,
                title: title)
        }
        .buttonStyle(AppStreamChromeKeyStyle(isSelected: isActive))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// The hairline between the option cluster and the trailing hide control, matching the
/// Assistant bar's divider.
struct AppStreamChromeDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }
}

/// Fixed-size symbols inside generous 44 pt touch targets.
struct AppStreamChromeLabel: View {
    let systemName: String
    var isActive: Bool = false
    var isDimmed: Bool = false
    var isDestructive: Bool = false
    /// Caption under the glyph. Nil keeps the compact, icon-only control.
    var title: LocalizedStringKey? = nil

    var body: some View {
        Group {
            if let title {
                VStack(spacing: 2) {
                    Image(systemName: systemName)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(height: 20)
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: AppStreamChromeBar.labelledControlWidth, height: AppStreamChromeBar.labelledControlHeight)
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .semibold))
                    // A missed dock tap must never land on the streamed Mac.
                    .frame(width: AppHostMetrics.iconControlTarget, height: AppHostMetrics.iconControlTarget)
            }
        }
        .foregroundStyle(glyph)
        .contentShape(Rectangle())
    }

    private var glyph: Color {
        if isDestructive { return StreamDesign.coral }
        if isActive { return StreamDesign.ink }
        return .white.opacity(isDimmed ? 0.5 : 0.9)
    }
}

/// The selected control is an ivory lens; inactive controls stay clear within the dock.
struct AppStreamChromeKey: ViewModifier {
    var isPressed = false
    var isSelected = false
    var prominent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .background {
                Circle()
                    .fill(isSelected ? Color(hex: 0xF1DED5) : Color.white.opacity(isPressed ? 0.14 : 0))
                    .padding(2)
            }
            .scaleEffect(isPressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : StreamDesign.spring, value: isPressed)
            .animation(reduceMotion ? nil : StreamDesign.spring, value: isSelected)
    }
}

struct AppStreamChromeKeyStyle: ButtonStyle {
    var prominent = false
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(AppStreamChromeKey(
                isPressed: configuration.isPressed,
                isSelected: isSelected,
                prominent: prominent))
    }
}

/// Shown in place of the deck once the user hides the controls: a single quiet eye, drawn
/// exactly like the Assistant control surface's reveal button, so a hidden deck is never a
/// dead end.
struct AppStreamChromeRevealButton: View {
    let bottomInset: CGFloat
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(
                        width: AppHostMetrics.iconControlTarget,
                        height: AppHostMetrics.iconControlTarget)
                    .background(Color.black.opacity(0.22), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show remote controls")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, max(bottomInset, 0) + 14)
    }
}

private struct AppStreamChromeAccessibility: ViewModifier {
    let label: String?
    let value: String?

    func body(content: Content) -> some View {
        if let label {
            if let value {
                content.accessibilityLabel(label).accessibilityValue(value)
            } else {
                content.accessibilityLabel(label)
            }
        } else {
            content
        }
    }
}
