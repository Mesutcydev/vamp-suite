import SwiftUI

/// Layout targets for host and app rows, shared by Vamp Control, Vamp Stream, Vamp Terminal, and
/// the Mac client.
///
/// These live in the shared DesignSystem rather than in a single app target because
/// `Sources/ClientiOS` is compiled by five app specs and only one of them also sees
/// `Sources/VampStream` — tokens referenced from ClientiOS must be visible to all of them.
///
/// Values are design targets at the default text size, not rigid accessibility constraints:
/// surfaces grow at larger Dynamic Type sizes rather than shrinking text to fit these numbers.
/// Spacing itself comes from the existing `AppSpacing` scale and radii from `AppRadius`.
enum AppHostMetrics {
    /// Collapsed pairing-card header: icon, title, one secondary line, chevron.
    static let collapsedHeaderHeight: CGFloat = 68
    /// Row baseline for a host or app entry.
    static let rowMinHeight: CGFloat = 72
    /// Minimum standard control height.
    static let controlHeight: CGFloat = 48
    /// Minimum touch target for an icon-only control.
    static let iconControlTarget: CGFloat = 44
    /// App icon inside a row.
    static let appIcon: CGFloat = 42
    /// Device/provider icon inside a row or card header.
    static let deviceIcon: CGFloat = 32
    static let providerIcon: CGFloat = 34
    /// Visible chevron disc; the surrounding hit area stays at `iconControlTarget`.
    static let chevronVisual: CGFloat = 30
    // The spacing and radius numbers are aliases into the existing scales rather than a second
    // set of literals, so there is one place to change them.
    /// Horizontal screen inset shared by the header, sections, rows, and the search field.
    static let screenInset: CGFloat = AppSpacing.lg
    /// Gap between related rows/cards in a section.
    static let cardGap: CGFloat = AppSpacing.sm
    /// Gap between major sections.
    static let sectionGap: CGFloat = AppSpacing.xl
    /// Interior padding of a card.
    static let cardPadding: CGFloat = AppSpacing.md
    /// Outer card radius.
    static let cardRadius: CGFloat = AppRadius.extraLarge
    /// Text-field radius.
    static let fieldRadius: CGFloat = AppRadius.medium
    /// Minimum grid tile width; narrower layouts fall back to one column.
    static let gridTileMinimum: CGFloat = 160
}
