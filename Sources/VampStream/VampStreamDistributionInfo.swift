import SharedModels
import SwiftUI

/// Both iOS distributions use this information and the same connection stack.
struct VampStreamDistributionInfo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("\(VampProductIdentity.syncName) editions")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("The App Store edition of \(VampProductIdentity.streamName) connects to your own Mac on the same Wi-Fi or Ethernet network. The website edition also supports private Tailscale connections.")
                .font(.footnote)
                .foregroundStyle(StreamReading.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VampStreamEditionRow(
                title: "Website edition: Vamp Sync",
                detail: "Control app windows with touch and keyboard, resize them for your device, and optionally unlock your Mac. Requires Screen Recording and Accessibility on the Mac. Updates come from \(VampProductIdentity.syncName).")
            Divider()
            VampStreamEditionRow(
                title: "Mac App Store edition: App Sync",
                detail: "View app windows already open on your Mac. Open, resize, and close windows on the Mac. Requires Screen Recording only. Remote input and Remote Unlock are unavailable. Updates come from the Mac App Store.")
            Text("\(VampProductIdentity.streamName) works with either edition. The Mac determines the available controls. Both editions use the same private pairing and encrypted connection.")
                .font(.footnote)
                .foregroundStyle(StreamReading.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Compare editions and get \(VampProductIdentity.syncName)", destination: VampProductLinks.syncEditions)
            Link("\(VampProductIdentity.streamName) website", destination: VampProductLinks.stream)
            Link("Privacy policy", destination: VampProductLinks.privacy)
            Link("Support", destination: VampProductLinks.support)
            Text("\(VampProductIdentity.streamName) updates through the App Store when installed from the App Store. Website installations are updated through the installation method you used.")
                .font(.caption)
                .foregroundStyle(StreamReading.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .padding(AppHostMetrics.cardPadding)
        .appQuietSurface()
    }
}

private struct VampStreamEditionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(StreamReading.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct VampStreamViewOnlyNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Label("View Only", systemImage: "eye").font(.subheadline.weight(.semibold))
            Text("This Mac shares existing windows. Open and resize them on the Mac. Zoom, pan, and markup stay on this device.")
                .font(.footnote)
                .foregroundStyle(StreamReading.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("About \(VampProductIdentity.syncName) editions", destination: VampProductLinks.syncEditions)
                .font(.footnote)
        }
    }
}
