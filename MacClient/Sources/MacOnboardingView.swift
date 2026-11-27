import SwiftUI
import AppKit
import SharedModels

/// One-time welcome shown on the first launch of the Mac client. Explains the
/// Vamp Sync requirement and the code check, then never reappears
/// (gated by `client.onboarding.completed`).
struct MacOnboardingView: View {
    /// This Mac's key fingerprint: the code Vamp Sync shows when it asks to approve this Mac.
    var fingerprint: String?
    let onDone: () -> Void

    init(fingerprint: String? = nil, onDone: @escaping () -> Void) {
        self.fingerprint = fingerprint
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 14) {
            MacMarkTile(size: 72, arc: .control)
                .padding(.top, 6)
            VStack(spacing: 6) {
                MacMetaLabel(text: "Welcome to Vamp Control")
                Text("Your other Mac, right here")
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.4)
                    .multilineTextAlignment(.center)
                Text(MacDistributionPolicy.isAppStoreEdition
                     ? "See another Mac’s desktop over your local network or a private Tailscale network. App windows need your local network."
                     : "See and control another Mac’s desktop or app windows over your local network or a private Tailscale network.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }

            VStack(spacing: 10) {
                step(1, title: "Open Vamp Sync on the other Mac",
                     detail: "It lives in that Mac’s menu bar. Its Mac App Store edition is View Only. Vamp Assistant pairs with a code from the Assistant tab instead.")
                step(2, title: "Check the code on both screens",
                     detail: "When you connect, Vamp Sync shows this Mac’s code. Approve only when every group matches.") {
                    if let fingerprint {
                        MacFingerprintChunks(fingerprint: fingerprint)
                            .padding(.top, 6)
                            .accessibilityLabel("This Mac’s code")
                    }
                }
                step(3, title: "Connect over Wi-Fi or Tailscale",
                     detail: "Your screen goes straight between your Macs. No Vamp server sits in the middle.")
            }
            .padding(.top, 4)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Link("Get Vamp Sync", destination: VampProductLinks.syncEditions)
                    .buttonStyle(MacCapsuleButtonStyle(kind: .quiet, large: true))
                Button("Get started", action: onDone)
                    .buttonStyle(MacCapsuleButtonStyle(kind: .primary, large: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 26)
        .frame(width: 560, height: fingerprint == nil ? 580 : 640)
        .background(MacBrand.pageBackdrop)
    }

    private func step(_ number: Int, title: String, detail: String) -> some View {
        step(number, title: title, detail: detail) { EmptyView() }
    }

    private func step<Extra: View>(_ number: Int, title: String, detail: String,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(MacBrand.mono(12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MacBrand.hairline, lineWidth: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                extra()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macCard(radius: 16)
        .accessibilityElement(children: .combine)
    }
}
