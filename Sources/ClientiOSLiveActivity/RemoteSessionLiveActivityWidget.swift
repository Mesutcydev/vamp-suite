import ActivityKit
import SharedModels
import SwiftUI
import WidgetKit

@main
struct RemoteSessionLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        RemoteSessionLiveActivityWidget()
    }
}

struct RemoteSessionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteSessionActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(accentColor(for: context).opacity(0.16))
                            .frame(width: 50, height: 50)
                        Image(systemName: context.state.isReconnecting ? "arrow.triangle.2.circlepath" : "desktopcomputer")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(accentColor(for: context))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 8) {
                            Text(context.state.hostDisplayName)
                                .font(.headline.weight(.semibold))
                                .lineLimit(1)
                            statusBadge(for: context)
                            Spacer(minLength: 8)
                            liveElapsedText(context.state.startedAt, font: .headline.monospacedDigit())
                        }

                        HStack(spacing: 12) {
                            metricPill(systemImage: "wifi", text: context.state.qualitySummary)
                            metricPill(
                                systemImage: context.state.isReconnecting ? "arrow.clockwise" : "lock.shield",
                                text: context.state.isReconnecting ? "Restoring" : "Secure"
                            )
                        }
                    }
                }

                Text(context.state.isReconnecting ? "Trying to restore your remote session." : "Remote session is active and ready.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.08, green: 0.08, blue: 0.11).opacity(0.96))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.hostDisplayName)
                            .font(.headline)
                            .lineLimit(1)
                        statusBadge(for: context)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 5) {
                        liveElapsedText(context.state.startedAt, font: .headline.monospacedDigit())
                        Label(context.state.qualitySummary, systemImage: "wifi")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(
                            context.state.isReconnecting ? "Reconnecting to host" : "Remote session active",
                            systemImage: context.state.isReconnecting ? "arrow.triangle.2.circlepath" : "display"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(context.state.isReconnecting ? .orange : .primary)
                        Spacer()
                        Text(context.state.isReconnecting ? "Hold tight" : "Secure link")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: context.state.isReconnecting ? "wifi.slash" : "desktopcomputer")
                    Text(compactQualityText(context.state.qualitySummary))
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(accentColor(for: context))
            } compactTrailing: {
                liveElapsedText(context.state.startedAt, font: .caption2.monospacedDigit())
            } minimal: {
                Image(systemName: context.state.isReconnecting ? "wifi.slash" : "display")
            }
            .widgetURL(URL(string: "iosremote://session"))
            .keylineTint(accentColor(for: context))
        }
    }

    @ViewBuilder
    private func liveElapsedText(_ startedAt: Date, font: Font) -> some View {
        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
            .font(font)
            .foregroundStyle(.white.opacity(0.94))
    }

    private func compactQualityText(_ summary: String) -> String {
        switch summary.lowercased() {
        case "excellent":
            return "EX"
        case "good":
            return "GD"
        case "fair":
            return "OK"
        case "poor":
            return "LOW"
        default:
            return summary.prefix(2).uppercased()
        }
    }

    private func accentColor(for context: ActivityViewContext<RemoteSessionActivityAttributes>) -> Color {
        context.state.isReconnecting ? .orange : .green
    }

    private func statusBadge(for context: ActivityViewContext<RemoteSessionActivityAttributes>) -> some View {
        Text(context.state.isReconnecting ? "Restoring" : "Live")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(accentColor(for: context).opacity(0.18), in: Capsule())
            .foregroundStyle(accentColor(for: context))
    }

    private func metricPill(systemImage: String, text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.08), in: Capsule())
    }
}
