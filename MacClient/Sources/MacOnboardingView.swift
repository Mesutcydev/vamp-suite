import SwiftUI
import AppKit

/// One-time welcome shown on the first launch of the Mac client. Explains the
/// Vamp Host requirement and the basics of connecting, then never reappears
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
                Text("Control another Mac from this one — full keyboard, mouse, and screen, over your local network or Tailscale.")
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
                         title: "Run a Vamp host on the other Mac",
                         detail: "Vamp Host shares its whole desktop, Vamp Sync shares a single app window, and Vamp Assistant connects with a pairing code. Keep it running.")
                    Divider()
                    step(number: 2,
                         icon: "wifi",
                         title: "Stay on the same network",
                         detail: "Both Macs should share a Wi-Fi or Ethernet network — or be reachable over Tailscale.")
                    Divider()
                    step(number: 3,
                         icon: "cursorarrow.rays",
                         title: "Connect and approve",
                         detail: "Pick the Mac from the list, then approve this device once on the other computer. Vamp Assistant pairs with a code instead — use Pair Assistant in the toolbar.")
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
