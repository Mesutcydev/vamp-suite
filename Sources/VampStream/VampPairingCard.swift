import SwiftUI

/// The collapsible shell shared by both pairing cards on Stream's connect home.
///
/// One reusable surface, provider content supplied by the caller, expansion owned by the caller so
/// each provider persists independently. Collapsed means header only: the body leaves layout and
/// the accessibility tree entirely rather than being hidden behind opacity or a fixed height.
///
/// The whole header is a single disclosure button and the chevron is part of its label — not a
/// second nested button — so tapping the corner, the title, or the icon all toggle the same state.
/// Actions live in the expanded body, where their gestures cannot accidentally collapse the card.
struct VampPairingCard<Body: View>: View {
    let icon: AnyView
    let title: String
    let detail: String
    let collapsedDetail: String
    let isExpanded: Bool
    let onToggle: () -> Void
    /// Trailing status shown in the header, e.g. a discreet "Needs attention" while collapsed.
    var headerStatus: String?
    var showsProgress: Bool = false
    let accessibilityCollapseLabel: String
    let accessibilityExpandLabel: String
    /// The expanded form body. Named `content` rather than `body`, which `View` already owns.
    @ViewBuilder let content: () -> Body

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.22)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                content()
                    .padding(.horizontal, AppHostMetrics.cardPadding)
                    .padding(.top, AppSpacing.sm)
                    .padding(.bottom, AppHostMetrics.cardPadding)
                    .transition(.opacity)
            }
        }
        .background {
            // A quiet, more opaque content surface. Rows and forms are content, not floating
            // controls, so they do not carry the conspicuous glass treatment.
            RoundedRectangle(cornerRadius: AppHostMetrics.cardRadius, style: .continuous)
                .fill(PR.card.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: AppHostMetrics.cardRadius, style: .continuous)
                        .strokeBorder(PR.border, lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppHostMetrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .animation(animation, value: isExpanded)
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                icon
                    .frame(width: AppHostMetrics.providerIcon, height: AppHostMetrics.providerIcon)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PR.fg)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(isExpanded ? detail : collapsedDetail)
                        .font(.footnote)
                        .foregroundStyle(PR.fg2)
                        .lineLimit(isExpanded ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Trailing status and chevron are reserved space, so a long title or
                // accessibility-sized text can never run underneath them.
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PR.fg2)
                        .accessibilityLabel("Working")
                } else if let headerStatus {
                    Text(headerStatus)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PR.fg2)
                        .lineLimit(1)
                        .accessibilityLabel(headerStatus)
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PR.fg2)
                    .frame(
                        width: AppHostMetrics.chevronVisual,
                        height: AppHostMetrics.chevronVisual)
                    .background {
                        Circle().fill(PR.fg.opacity(0.08))
                    }
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, AppHostMetrics.cardPadding)
            .frame(minHeight: AppHostMetrics.collapsedHeaderHeight)
            .padding(.vertical, AppSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed"))
        .accessibilityHint(Text(isExpanded ? accessibilityCollapseLabel : accessibilityExpandLabel))
        .accessibilityAddTraits(.isButton)
    }
}
