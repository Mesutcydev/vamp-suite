import SwiftUI

struct WelcomeStep: View {
    let knownHostCount: Int
    let start: () -> Void
    let skip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PRScreenHeader(title: "welcome", host: "vamp.host", state: .live)

            ScrollView {
                VStack(spacing: 12) {
                    PRCard("bootstrap") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your Mac. In your pocket.")
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .foregroundColor(PR.fg)
                            Text("Full remote control over your Mac — from the sofa, from a coffee shop, or from the other side of the world.")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(PR.fg2)
                                .fixedSize(horizontal: false, vertical: true)

                            Divider().overlay(PR.border)

                            HStack(spacing: 8) {
                                Circle()
                                    .fill(knownHostCount > 0 ? PR.accent : PR.warn)
                                    .frame(width: 7, height: 7)
                                Text(knownHostCount > 0
                                    ? "paired hosts detected: \(knownHostCount)"
                                    : "no paired host detected yet")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(knownHostCount > 0 ? PR.accent : PR.warn)
                            }
                        }
                    }

                    HowItWorksCard()

                    PRCard("works anywhere") {
                        VStack(alignment: .leading, spacing: 8) {
                            useCaseLine(icon: "house.fill",               text: "Home — switch between screens, run scripts, control apps")
                            useCaseLine(icon: "cup.and.saucer.fill",      text: "Coffee shop — Tailscale relay keeps it private, no open ports")
                            useCaseLine(icon: "airplane",                 text: "Travel — access your Mac from any network, anywhere")
                            useCaseLine(icon: "bolt.fill",                text: "Emergency — wake, unlock, and fix things from your phone")
                        }
                    }

                    VampHostPromoCard.direct

                    PRCard("security model") {
                        VStack(alignment: .leading, spacing: 8) {
                            secLine(icon: "key.fill",           text: "P-256 device key — unique identity, stored in Keychain")
                            secLine(icon: "checkmark.seal.fill", text: "fingerprint pinning — every reconnect cryptographically verified")
                            secLine(icon: "person.badge.shield.checkmark.fill", text: "explicit approval — new Vamp Control clients must be accepted on-screen")
                            secLine(icon: "network",            text: "lan-direct transport — no data leaves your local network")
                            secLine(icon: "lock.doc.fill",      text: "session-locked commands — validated against active session ID")
                            secLine(icon: "arrow.clockwise",    text: "replay guard — stale packets older than 30 s are dropped")
                            secLine(icon: "hand.raised.fill",   text: "revoke anytime — remove any trusted host from Settings")
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
            }

            Spacer(minLength: 0)

            PRCard("controls") {
                VStack(spacing: 10) {
                    Button(action: start) {
                        Text("get started")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(PR.bg)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(PR.accent)
                            .clipShape(RoundedRectangle(cornerRadius: PR.r8))
                    }
                    .buttonStyle(.plain)

                    Button(action: skip) {
                        Text("skip for now")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(PR.dim)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .overlay(RoundedRectangle(cornerRadius: PR.r8).strokeBorder(PR.border))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PR.bg)
    }
}

private extension WelcomeStep {
    @ViewBuilder
    func secLine(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(PR.accent)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(PR.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    func useCaseLine(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(PR.accent2)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(PR.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

#Preview("WelcomeStep") {
    WelcomeStep(knownHostCount: 1, start: {}, skip: {})
        .background(PR.bg)
}
