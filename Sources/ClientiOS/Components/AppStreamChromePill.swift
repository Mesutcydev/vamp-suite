import SwiftUI

/// The one bottom control deck Stream and its Assistant sibling share.
///
/// Every app-streaming surface draws the same capsule of icon controls at the bottom of the
/// video: close, annotate, keyboard, window sizing, fit, and hide. It is deliberately one
/// implementation rather than a copy per host path — a second copy is how the Sync path and the
/// Assistant path drift into looking like different apps.
///
/// The remote image can be nearly white or highly detailed. Native clear glass alone inherits
/// too much of that content and makes the controls disappear, so the deck keeps a colorless
/// glass with a neutral legibility backing and a stable edge.
struct AppStreamChromePill<Content: View>: View {
    /// Vertical padding inside the capsule, above and below the controls.
    static var verticalPadding: CGFloat { 6 }
    /// Gap between the capsule and the bottom safe area.
    static var bottomMargin: CGFloat { AppSpacing.sm }

    /// How much of the stream surface this deck occupies, so the picture is never laid out
    /// underneath it.
    ///
    /// It lives here, with the deck, because both host paths used to keep their own copy of
    /// the number — and when the controls grew from 30 pt to a 44 pt touch target, two
    /// separate constants would have had to be found and changed together.
    static func reservedBand(safeAreaBottom: CGFloat) -> CGFloat {
        AppHostMetrics.iconControlTarget
            + verticalPadding * 2
            + bottomMargin
            + max(safeAreaBottom, 0)
    }

    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, AppSpacing.xs)
        .padding(.vertical, Self.verticalPadding)
        .background(Color.black.opacity(0.62), in: Capsule(style: .continuous))
        .prGlassSurface(in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// One icon button inside `AppStreamChromePill`. Each control takes an equal share of the
/// capsule so the deck keeps a steady rhythm as options appear and disappear.
struct AppStreamChromeButton: View {
    let systemName: String
    var isActive: Bool = false
    var isDimmed: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AppStreamChromeLabel(
                systemName: systemName,
                isActive: isActive,
                isDimmed: isDimmed,
                isDestructive: isDestructive)
        }
        .buttonStyle(.plain)
    }
}

/// A menu entry styled exactly like a deck button, for controls that expand into choices
/// (window sizing, displays, fit/fill).
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
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
    }
}

struct AppStreamChromeLabel: View {
    let systemName: String
    var isActive: Bool = false
    var isDimmed: Bool = false
    var isDestructive: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(
                isDestructive ? Color.red.opacity(0.86)
                    : (isActive ? Color.white : Color.white.opacity(isDimmed ? 0.42 : 0.82)))
            // The glyph stays small and quiet, but the hit area is a full 44 pt: this deck
            // floats over video with nothing forgiving around it, so an under-sized target
            // means taps land on the streamed Mac instead of the control.
            .frame(maxWidth: .infinity, minHeight: AppHostMetrics.iconControlTarget)
            .contentShape(Rectangle())
    }
}

/// Shown in place of the deck once the user hides the controls: a single quiet eye that brings
/// the deck back, so a hidden deck is never a dead end.
struct AppStreamChromeRevealButton: View {
    let bottomInset: CGFloat
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                Image(systemName: "eye")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.58), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8))
                    // Visually a small disc; a full-size target underneath it. This is the
                    // only way back from hidden controls, so it must not be a 32 pt dot.
                    .frame(
                        width: AppHostMetrics.iconControlTarget,
                        height: AppHostMetrics.iconControlTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show remote controls")
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.bottom, max(bottomInset, 0) + AppSpacing.sm)
    }
}
