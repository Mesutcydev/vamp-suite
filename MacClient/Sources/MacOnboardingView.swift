import SwiftUI
import AppKit

/// One-time welcome shown on the first launch of the Mac client. Explains the
/// Vamp Sync requirement and the basics of connecting, then never reappears
/// (gated by `client.onboarding.completed`).
struct MacOnboardingView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("Welcome to Vamp Control")
                    .font(.title2.weight(.semibold))
                Text(MacDistributionPolicy.isAppStoreEdition
                     ? "Stream another Mac’s desktop over your local network or a private Tailscale network. App windows need your local network."
                     : "Stream another Mac’s desktop or app windows over your local network or a private Tailscale network.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 410)
            }
            .padding(.top, 28)
            .padding(.bottom, 22)

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    step(number: 1,
                         icon: "desktopcomputer",
                         title: "Run Vamp Sync on the other Mac",
                         detail: "Vamp Sync shares its desktop or app windows. Its Mac App Store edition is View Only. Vamp Assistant also connects through Pair Assistant in the toolbar.")
                    Divider()
                    step(number: 2,
                         icon: "wifi",
                         title: "Stay on the same network",
                         detail: "Both Macs should share a Wi-Fi or Ethernet network — or be reachable over Tailscale.")
                    Divider()
                    step(number: 3,
                         icon: "cursorarrow.rays",
                         title: "Connect and approve",
                         detail: "Pick the Mac from the list, compare the complete device fingerprints, then approve this device on the other Mac. Vamp Assistant pairs with a code instead.")
                }
                .padding(6)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 20)

            Button(action: onDone) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .frame(width: 520, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func step(number: Int, icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 26, height: 26)
                Text("\(number)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: icon)
                    .font(.body.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
