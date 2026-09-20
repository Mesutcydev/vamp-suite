import SwiftUI

/// Layout metrics for the machined bar, shared by the deck and the surfaces that reserve
/// space for it. Deliberately non-generic: `AppStreamChromePill` itself is generic over its
/// content, so call sites should not have to name `EmptyView` just to read a number.
enum AppStreamChromeBar {
    /// Height of the machined housing. Matches the Assistant bar's 54 pt frame: one 44 pt
    /// keycap row, the housing's own 4 pt inside padding, and the keycap's press settle.
    static var height: CGFloat { 54 }
    /// Gap between the housing and the bottom edge, on top of the safe-area floor below.
    static var bottomMargin: CGFloat { 8 }
    /// Horizontal inset of the housing from the screen edges.
    static var edgeInset: CGFloat { 10 }
    /// Smallest bottom gap used when the surface sits inside an ignored safe area (where the
    /// inset can read as zero). The Assistant bar uses the same 10 pt floor.
    static var bottomFloor: CGFloat { 10 }

    /// How much of the stream surface the deck occupies, so the picture is never laid out
    /// underneath it. It lives here, with the deck, because both host paths used to keep
    /// their own copy of the number — and when the controls change size, two separate
    /// constants would have to be found and changed together.
    static func reservedBand(safeAreaBottom: CGFloat) -> CGFloat {
        height + bottomMargin + max(safeAreaBottom, bottomFloor)
    }
}

/// The one bottom control deck Stream and its Assistant sibling share.
///
/// It is drawn as the Vamp Assistant control bar (`classicBottomChrome` on its Remote
/// Control surface): a machined pearl housing of keycap icon controls that scrolls
/// horizontally when the options outgrow the screen, with a divider before the trailing
/// hide control. Both Stream host paths — Vamp Sync and Vamp Assistant — draw this same
/// deck, so a Sync stream and an Assistant stream never look like two different apps.
struct AppStreamChromePill<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                content()
            }
            .padding(4)
        }
        .scrollIndicators(.hidden)
        .frame(height: AppStreamChromeBar.height)
        .frame(maxWidth: 520)
        .background(
            AppStreamChromeStyle.pearl,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppStreamChromeStyle.edge, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.34), radius: 12, y: 6)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// One icon button inside `AppStreamChromePill`, rendered as a machined keycap.
struct AppStreamChromeButton: View {
    let systemName: String
    var isActive: Bool = false
    var isDimmed: Bool = false
    var isDestructive: Bool = false
    var accessibilityLabel: String? = nil
    var accessibilityValue: String? = nil
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
                isDestructive: isDestructive)
        }
        .buttonStyle(AppStreamChromeKeyStyle(prominent: isDestructive, isSelected: isActive))
        .modifier(AppStreamChromeAccessibility(label: accessibilityLabel, value: accessibilityValue))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// A menu entry styled exactly like a deck key cap, for controls that expand into choices
/// (window sizing, displays, stream options).
struct AppStreamChromeMenu<MenuContent: View>: View {
    let systemName: String
    var isActive: Bool = false
    var isDimmed: Bool = false
    let accessibilityLabel: String
    var accessibilityValue: String? = nil
    @ViewBuilder var menuContent: () -> MenuContent

    var body: some View {
        Menu {
            menuContent()
        } label: {
            AppStreamChromeLabel(
                systemName: systemName,
                isActive: isActive,
                isDimmed: isDimmed,
                isDestructive: false)
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

/// The glyph on a keycap. The cap itself is drawn by `AppStreamChromeKey`.
struct AppStreamChromeLabel: View {
    let systemName: String
    var isActive: Bool = false
    var isDimmed: Bool = false
    var isDestructive: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(glyph)
            // The glyph stays small and quiet, but the cap and its hit area are a full
            // 44 pt: this deck floats over video with nothing forgiving around it, so an
            // under-sized target means taps land on the streamed Mac instead of the control.
            .frame(width: AppHostMetrics.iconControlTarget, height: AppHostMetrics.iconControlTarget)
            .contentShape(Rectangle())
    }

    private var glyph: Color {
        if isDestructive || isActive { return .white }
        return isDimmed ? AppStreamChromeStyle.dimmedInk : AppStreamChromeStyle.ink
    }
}

/// A stationary housing underneath a moving face: the same keycap rendering as the Vamp
/// Assistant control surface's hardware keys, so both apps' bars feel identical under the
/// finger.
struct AppStreamChromeKey: ViewModifier {
    var isPressed = false
    var isSelected = false
    var prominent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var engaged: Bool { isSelected || isPressed }
    private var face: Color {
        if prominent || isSelected { return AppStreamChromeStyle.darkInsert }
        return isPressed ? AppStreamChromeStyle.keyFacePressed : AppStreamChromeStyle.keyFace
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        content
            .background {
                shape.fill(face)
                    .overlay {
                        shape.strokeBorder(AppStreamChromeStyle.keySeam.opacity(0.28), lineWidth: 0.5)
                    }
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(AppStreamChromeStyle.keyTopHighlight.opacity(engaged ? 0.12 : 0.65))
                            .frame(height: 0.5)
                            .padding(.horizontal, 6)
                            .padding(.top, 0.5)
                    }
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [Color.black.opacity(engaged ? 0.20 : 0), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 3)
                        .clipShape(shape)
                    }
                    .shadow(
                        color: AppStreamChromeStyle.keyBottomShadow.opacity(engaged ? 0 : 0.28),
                        radius: 0, x: 0, y: engaged ? 0 : 1)
            }
            .offset(y: engaged && !reduceMotion ? 1 : 0)
            .padding(.bottom, 1)
            .background(AppStreamChromeStyle.housingFoot.opacity(0.55), in: shape)
            .animation(reduceMotion ? nil : .easeOut(duration: isPressed ? 0.08 : 0.14), value: isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isSelected)
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

/// Colors and materials for the machined bar. Values are the Vamp Assistant control
/// surface's dark-appearance hardware tokens, so the two apps' bars match surface for
/// surface.
enum AppStreamChromeStyle {
    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255)
    }

    /// The bar housing: pearl gradient, dark appearance.
    static let pearl = LinearGradient(
        colors: [hex(0x383838), hex(0x323232), hex(0x292929)],
        startPoint: .top, endPoint: .bottom)
    /// The housing's perimeter highlight.
    static let edge = LinearGradient(
        colors: [hex(0x595959), hex(0x444444)],
        startPoint: .top, endPoint: .bottom)

    static let keyFace = hex(0x393939)
    static let keyFacePressed = hex(0x222222)
    static let darkInsert = hex(0x090909)
    static let keySeam = hex(0x0E0E0E)
    static let keyTopHighlight = hex(0x515151)
    static let keyBottomShadow = hex(0x0C0C0C)
    static let housingFoot = hex(0x1A1A1A)

    static let ink = hex(0xF0EFEC)
    static let dimmedInk = hex(0xB7B5B1)
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
