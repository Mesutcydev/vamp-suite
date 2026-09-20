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

    private var surface: RoundedRectangle {
        RoundedRectangle(cornerRadius: VampPairingCardMetrics.radius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                content()
                    .padding(.horizontal, VampPairingCardMetrics.contentPadding)
                    .padding(.top, AppSpacing.sm)
                    .padding(.bottom, VampPairingCardMetrics.contentPadding)
                    .transition(.opacity)
            }
        }
            // A stable reading surface keeps the bright portal from washing out labels.
            .background {
                surface.fill(StreamReading.surface)
            }
        .prGlassSurface(
            in: surface,
            role: .card
        )
        .overlay {
            surface
                .strokeBorder(PR.border, lineWidth: 1)
        }
            .overlay {
                surface
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.08),
                                Color.white.opacity(0),
                                Color.white.opacity(0.03)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
        .clipShape(surface)
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
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Text(isExpanded ? detail : collapsedDetail)
                        .font(.footnote)
                        .foregroundStyle(StreamReading.secondary)
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
                        .foregroundStyle(StreamReading.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(headerStatus)
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PR.fg2.opacity(0.88))
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, VampPairingCardMetrics.contentPadding)
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

private enum VampPairingCardMetrics {
    static let radius: CGFloat = 28
    static let contentPadding: CGFloat = AppSpacing.xl
}

/// Press feedback for the engineered primary action. Brightness moves instead of scale, so the
/// control's geometry and the tunnel behind it stay visually stable.
struct VampStreamEngineeredButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.10 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
