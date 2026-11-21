#if canImport(UIKit)
import SwiftUI

/// Read frame freshness at render time, rather than caching a stale Boolean between polls.
enum AppStreamVideoHealth {
    static func isStalled(lastDecodedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastDecodedAt else { return true }
        return now - lastDecodedAt > 5
    }

    static func needsRecovery(lastDecodedAt: TimeInterval?, startedAt: TimeInterval, now: TimeInterval) -> Bool {
        now - startedAt > 5 && isStalled(lastDecodedAt: lastDecodedAt, now: now)
    }
}

struct AppStreamVideoRecoveryBar: View {
    let onRetry: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Label("Video delayed", systemImage: "wifi.exclamationmark")
                    .font(.subheadline)
                Spacer(minLength: 8)
                Button("Retry video", action: onRetry)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("Video delayed", systemImage: "wifi.exclamationmark")
                Button("Retry video", action: onRetry).frame(minHeight: 44)
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PR.rCard))
    }
}

struct AppStreamGestureHelpView: View {
    var isViewOnly = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        StreamEyebrow(title: "A FEW NATURAL MOVES")
                        Text("At your fingertips.")
                            .font(.largeTitle.weight(.medium)).tracking(-1.5)
                            .foregroundStyle(StreamDesign.text)
                        Text(isViewOnly ? "View Only keeps control on your Mac. Zoom and move the picture here." : "Familiar gestures. A whole new workspace.")
                            .font(.subheadline).foregroundStyle(StreamDesign.secondary)
                    }
                    if !isViewOnly { AppStreamControlHelpSection() }
                    AppStreamPictureHelpSection(isViewOnly: isViewOnly)
                }
                .frame(maxWidth: 560)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background { StreamAtmosphere() }
            .navigationTitle("Stream controls")
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StreamPrimaryButton(title: "Got it", symbol: "checkmark") { dismiss() }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, StreamDesign.inset)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)

            }
        }
        // Uses the app's own surfaces, so it follows the chosen appearance like everything else.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct AppStreamControlHelpSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Control the Mac")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 20) {
                AppStreamHelpRow(symbol: "hand.tap", title: "Click", detail: "Tap once to click. Tap twice to double-click.")
                AppStreamHelpRow(symbol: "hand.point.up.left", title: "Right-click", detail: "Tap with two fingers.")
                AppStreamHelpRow(symbol: "arrow.up.arrow.down", title: "Scroll", detail: "Slide two fingers up or down.")
                AppStreamHelpRow(symbol: "hand.draw", title: "Drag", detail: "Touch and hold, then move. Lift to release.")
                AppStreamHelpRow(symbol: "keyboard", title: "Type", detail: "Tap the keyboard button to type in the Mac app.")
            }
            .padding(AppHostMetrics.cardPadding)
            .streamGlass()
        }
    }
}

private struct AppStreamPictureHelpSection: View {
    let isViewOnly: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adjust the picture")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 20) {
                AppStreamHelpRow(symbol: "viewfinder", title: "Zoom and move", detail: "Tap Adjust view, then pinch to zoom or drag to move the picture.")
                if !isViewOnly {
                    AppStreamHelpRow(symbol: "checkmark", title: "Return to control", detail: "Tap the checkmark when you’re done adjusting.")
                }
                AppStreamHelpRow(symbol: "1.circle", title: "Back to actual size", detail: "Tap 1× at the top to undo any zoom and re-centre the picture.")
                if !isViewOnly {
                    AppStreamHelpRow(symbol: "aspectratio", title: "Reshape the Mac window", detail: "Use the sizing button in the bottom bar: Adaptive resize fits the window to your phone, Original Size leaves it as it is on the Mac.")
                }
            }
            .padding(AppHostMetrics.cardPadding)
            .streamGlass()
            Text(isViewOnly ? "These adjustments change only the picture on this device. The Mac window stays as it is." : "Adjust view and 1× move the picture on this device. Only the sizing button changes the window on the Mac.")
                .font(.footnote)
                .foregroundStyle(StreamDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AppStreamHelpRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ScaledMetric(relativeTo: .body) private var iconSize = 24

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(StreamDesign.accent)
                .frame(width: iconSize + 8, height: iconSize + 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(StreamDesign.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

#endif
