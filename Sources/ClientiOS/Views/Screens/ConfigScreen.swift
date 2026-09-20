import SwiftUI
import SharedModels
import Diagnostics
#if canImport(UIKit)
import UIKit
#endif

struct ConfigScreen: View {
    let environment: ClientAppEnvironment
    @ObservedObject var appLock: AppLockService

    @StateObject private var trustedVM: ClientTrustedHostsViewModel
    @ObservedObject private var hostsVM: HostsListViewModel
    @ObservedObject private var sessionCoordinator: ClientSessionCoordinator
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var paletteManager: PaletteManager
    @AppStorage("client.ui.whiteMode") private var whiteModeEnabled = false
    @AppStorage("client.ui.inlineStreamPreview") private var inlineStreamPreview = false
    @AppStorage("client.ui.streamingUITheme") private var streamingUITheme = "classic"
    @AppStorage("client.liveActivity.enabled") private var liveActivityEnabled = true
    @AppStorage("com.mesutcy.remotedesktop.client.filetransfer.enabled") private var fileTransferEnabled = true
    @AppStorage("client.audio.placeholder.enabled") private var audioWhenReadyEnabled = false
    @AppStorage("client.clipboard.enabled") private var clipboardEnabled = true
    @State private var showDiagnostics = false
    @Environment(\.dismiss) private var dismiss

    init(environment: ClientAppEnvironment, appLock: AppLockService) {
        self.environment = environment
        self.appLock = appLock
        self.sessionCoordinator = environment.sessionCoordinator
        _trustedVM = StateObject(wrappedValue: ClientTrustedHostsViewModel(peerStore: environment.trustedPeerStore))
        self.hostsVM = environment.sharedHostsViewModel
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 12) {
                    PRCard("stream") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            qualityButton(.performance, label: "perf", hint: "lighter · 30 fps")
                            qualityButton(.balanced, label: "balanced", hint: "stable · 30 fps")
                            qualityButton(.quality, label: "quality", hint: "sharp · 60 fps")
                            qualityButton(.ultra, label: "ultra", hint: "native · 60 fps")
                        }
                    }

                    PRCard("color palette") {
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 8
                        ) {
                            ForEach(PRPalette.allCases) { palette in
                                paletteButton(palette)
                            }
                        }
                        Text("applies everywhere — buttons, toggles, stream chrome, and the header glow")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(PR.dim)
                            .padding(.top, 6)
                    }

                    PRCard("runtime") {
                        PRRow(label: "inline stream", hint: "show the live mirror on the home screen when connected — tap it to go fullscreen", trailing: {
                            PRToggle(isOn: $inlineStreamPreview)
                        }, isLast: false)

                        PRRow(label: "live stats overlay", hint: "latency + frame metrics on stream", trailing: {
                            PRToggle(isOn: showsStatsBinding)
                        }, isLast: false)

                        PRRow(label: "low power mode", hint: "reduce energy, steadier thermals", trailing: {
                            PRToggle(isOn: lowPowerBinding)
                        }, isLast: false)

                        PRRow(label: "prefer view-only", hint: "default new sessions to observation", trailing: {
                            PRToggle(isOn: prefersViewOnlyBinding)
                        }, isLast: false)

                        PRRow(label: "white mode", hint: "light ui theme override", trailing: {
                            PRToggle(isOn: $whiteModeEnabled)
                        }, isLast: false)

                        PRRow(label: "modern stream ui", hint: "experimental neon trackpad layout (portrait) — falls back to classic in landscape", trailing: {
                            PRToggle(isOn: Binding(
                                get: { streamingUITheme == "modern" },
                                set: { streamingUITheme = $0 ? "modern" : "classic" }
                            ))
                        }, isLast: false)

                        PRRow(label: "app lock", hint: appLockHint, trailing: {
                            PRToggle(isOn: $appLock.isEnabled)
                        }, isLast: false)

                        PRRow(label: "live activity", hint: "show session status on lock screen while connected", trailing: {
                            PRToggle(isOn: $liveActivityEnabled)
                        }, isLast: true)
                    }

                    PRCard("workflow") {
                        PRRow(label: "file transfer", hint: "send a file from iphone to your mac after explicit host approval", trailing: {
                            PRToggle(isOn: $fileTransferEnabled)
                        }, isLast: false)

                        PRRow(label: "voice input", hint: "dictate text on iphone, review it, then send it to the mac", trailing: {
                            secBadge("on demand", tint: PR.accent2)
                        }, isLast: false)

                        PRRow(label: "audio", hint: "groundwork only for now — user-facing streaming stays disabled", trailing: {
                            PRToggle(isOn: $audioWhenReadyEnabled)
                        }, isLast: false)

                        PRRow(label: "clipboard sync", hint: "user-triggered push and pull of plaintext clipboard between iphone and mac", trailing: {
                            PRToggle(isOn: $clipboardEnabled)
                        }, isLast: true)
                    }

                    PRCard("daemon") {
                        HStack(spacing: 8) {
                            PRStatPill(key: "sync", value: "local", color: PR.accent2)
                            PRStatPill(key: "security", value: environment.prefersViewOnly ? "guarded" : "interactive", color: PR.accent)
                            PRStatPill(key: "session", value: sessionCoordinator.phase == .idle ? "off" : "on", color: PR.warn)
                        }
                    }

                    PRCard("trusted hosts", trailing: {
                        Text("\(trustedHostCount) · mixed")
                    }) {
                        if trustedVM.trustedHosts.isEmpty && hostsVM.savedHosts.isEmpty {
                            Text("No trusted hosts. Pair a Vamp Host to create trust.")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(PR.dim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(trustedVM.trustedHosts.enumerated()), id: \.element.id) { index, host in
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(host.displayName)
                                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                                .foregroundColor(PR.fg)
                                            Text(host.fingerprint)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(PR.dim)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Button("revoke") {
                                            Task { await trustedVM.forget(host) }
                                        }
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundColor(PR.err)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: PR.r6)
                                                .strokeBorder(PR.err.opacity(0.45), lineWidth: 1)
                                        )
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    if index != trustedVM.trustedHosts.count - 1 || !hostsVM.savedHosts.isEmpty {
                                        Divider().overlay(PR.border)
                                    }
                                }

                                ForEach(Array(hostsVM.savedHosts.enumerated()), id: \.element.id) { index, host in
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(host.title)
                                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                                .foregroundColor(HostNameColor.color(for: host.id))
                                            Text("\(host.endpoint.hostname):\(host.endpoint.port)")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(PR.dim)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Button("revoke") {
                                            hostsVM.removeSavedHost(host.id)
                                        }
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundColor(PR.err)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: PR.r6)
                                                .strokeBorder(PR.err.opacity(0.45), lineWidth: 1)
                                        )
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    if index != hostsVM.savedHosts.count - 1 {
                                        Divider().overlay(PR.border)
                                    }
                                }
                            }
                        }
                    }

                    // MARK: Security
                    PRCard("security", trailing: {
                        Text("all enforced")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(PR.accent)
                    }) {
                        PRRow(
                            label: "device key",
                            hint: "P-256 · ECDSA · Keychain · this device only",
                            trailing: { secBadge("active", tint: PR.accent) },
                            isLast: false
                        )
                        PRRow(
                            label: "fingerprint",
                            hint: LocalizedStringKey(fingerprintDisplay),
                            trailing: {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(PR.accent)
                            },
                            isLast: false
                        )
                        PRRow(
                            label: "trust model",
                            hint: "new hosts require visible approval in Vamp Host before access",
                            trailing: { secBadge("pinned", tint: PR.accent) },
                            isLast: false
                        )
                        PRRow(
                            label: "transport",
                            hint: "all traffic stays on your local network — no external relay",
                            trailing: { secBadge("lan-direct", tint: PR.accent2) },
                            isLast: false
                        )
                        PRRow(
                            label: "session binding",
                            hint: "commands rejected unless they carry the active session ID",
                            trailing: { secBadge("enforced", tint: PR.accent2) },
                            isLast: false
                        )
                        PRRow(
                            label: "input validation",
                            hint: "coordinates bounded, control chars filtered, dangerous shortcuts blocked",
                            trailing: { secBadge("active", tint: PR.accent) },
                            isLast: false
                        )
                        PRRow(
                            label: "replay guard",
                            hint: "envelopes older than 30 s are silently dropped",
                            trailing: { secBadge("±30 s", tint: PR.accent2) },
                            isLast: false
                        )
                        PRRow(
                            label: "rate limiting",
                            hint: "5 connection attempts allowed per source address per minute",
                            trailing: { secBadge("5 / min", tint: PR.accent2) },
                            isLast: false
                        )
                        PRRow(
                            label: "payload cap",
                            hint: "messages over 1 MB are rejected before decoding",
                            trailing: { secBadge("1 MB", tint: PR.accent2) },
                            isLast: false
                        )
                        PRRow(
                            label: "view-only mode",
                            hint: "when on, blocks all input injection regardless of session",
                            trailing: {
                                secBadge(
                                    environment.prefersViewOnly ? "on" : "off",
                                    tint: environment.prefersViewOnly ? PR.accent : PR.dim
                                )
                            },
                            isLast: true
                        )
                    }

                    PRCard("vamp host") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Vamp Control requires Vamp Host running on macOS.")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(PR.fg)
                            Text("Vamp Host receives your approved commands and performs them on your Mac.")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(PR.dim)
                            Text("For outside-LAN access, connect both devices with Tailscale and use the Mac’s Tailscale IP.")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(PR.dim)
                            Text("Only control Macs you own or are authorized to access. You can stop Vamp Host at any time.")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(PR.dim)

                        }
                    }

                    VampHostPromoCard.direct

                    PRCard("diagnostics") {
                        Button {
                            showDiagnostics = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "ladybug")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("view connection log")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(PR.dim)
                            }
                            .foregroundColor(PR.accent)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .sheet(isPresented: $showDiagnostics) {
                        ClientDiagnosticsView(environment: environment)
                    }

                    PRCard("about") {
                        PRRow(label: "version", trailing: {
                            Text("3.1.0")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(PR.fg)
                        }, isLast: false)

                        PRRow(label: "protocol", trailing: {
                            Text("vamp-terminal/1")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(PR.fg)
                        }, isLast: false)

                        PRRow(label: "open source", trailing: {
                            Image(systemName: "chevron.right")
                                .foregroundColor(PR.dim)
                        }, onTap: {
                            if let url = URL(string: "https://thevamp.app/") {
                                openURL(url)
                            }
                        }, isLast: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 88)
                .padding(.bottom, 14)
            }

            PRScreenHeader(
                title: "config",
                host: "vamp.host · v1.0.3",
                state: sessionCoordinator.phase == .error ? .error : .live
            )
            .zIndex(1)
        }
        .background { PRAppBackground() }
        .task {
            await trustedVM.refresh()
            await hostsVM.start()
        }
    }

    private var trustedHostCount: Int {
        trustedVM.trustedHosts.count + hostsVM.savedHosts.count
    }

    private func qualityButton(_ preset: StreamQualityPreset, label: String, hint: String) -> some View {
        let active = environment.effectivePreferredQualityPreset == preset
        let deviceUnavailable = preset == .ultra && !environment.supportsUltraQualityPreset
        let subtitle = deviceUnavailable ? "needs newer iphone" : hint
        return Button {
            environment.preferredQualityPreset = preset
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(deviceUnavailable ? PR.dim : active ? PR.accent : PR.fg)
                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(PR.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(deviceUnavailable ? PR.bg2.opacity(0.5) : active ? PR.accent.opacity(0.10) : PR.bg2)
            .overlay(
                RoundedRectangle(cornerRadius: PR.r8)
                    .strokeBorder(deviceUnavailable ? PR.border.opacity(0.4) : active ? PR.accent.opacity(0.45) : PR.border)
            )
            .clipShape(RoundedRectangle(cornerRadius: PR.r8))
            .opacity(deviceUnavailable ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(deviceUnavailable)
    }

    private var showsStatsBinding: Binding<Bool> {
        Binding(
            get: { environment.showsStatsOverlay },
            set: { environment.showsStatsOverlay = $0 }
        )
    }

    private func paletteButton(_ palette: PRPalette) -> some View {
        let active = paletteManager.selected == palette
        return Button {
            paletteManager.selected = palette
            AppHaptics.selection()
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(palette.color)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                Text(palette.title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(active ? PR.accent : PR.fg)
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(palette.color)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? palette.color.opacity(0.12) : PR.bg2)
            .overlay(
                RoundedRectangle(cornerRadius: PR.r8)
                    .strokeBorder(active ? palette.color.opacity(0.55) : PR.border)
            )
            .clipShape(RoundedRectangle(cornerRadius: PR.r8))
        }
        .buttonStyle(.plain)
    }

    private var lowPowerBinding: Binding<Bool> {
        Binding(
            get: { environment.lowPowerModeEnabled },
            set: { environment.lowPowerModeEnabled = $0 }
        )
    }

    private var prefersViewOnlyBinding: Binding<Bool> {
        Binding(
            get: { environment.prefersViewOnly },
            set: { environment.prefersViewOnly = $0 }
        )
    }

    private var appLockHint: LocalizedStringKey {
        switch appLock.biometryType {
        case .faceID:  return "require face id when reopening app"
        case .touchID: return "require touch id when reopening app"
        default:       return "require passcode when reopening app"
        }
    }

    private var fingerprintDisplay: String {
        let fp = environment.clientIdentity.publicKeyFingerprint
        guard fp.count >= 12 else {
            return "no fingerprint"
        }
        return "SHA256:" + fp.prefix(8) + "…" + fp.suffix(4)
    }

    @ViewBuilder
    private func secBadge(_ value: String, tint: Color) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }
}

#Preview("ConfigScreen") {
    ConfigScreen(
        environment: ClientAppEnvironment.makeDefault(clientName: "Vamp Control"),
        appLock: AppLockService()
    )
    .environmentObject(PaletteManager.shared)
}

// MARK: - Vamp Host promo + explainer
//
// Shared UI for getting the required Vamp Host Mac app and explaining how Vamp Control works.
// Reused by the home empty state, the first-run welcome, and this config screen. Lives
// here (an already-compiled file) rather than a new file to skip the two-target pbxproj
// registration dance — see [[build-targets-and-file-membership]].

enum VampHostLinks {
    static let direct = URL(string: "https://thevamp.app/#download")!
}

/// A cross-promo–style card for installing Vamp Host.
struct VampHostPromoCard: View {
    struct Badge: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
    }

    let eyebrow: String
    let title: String
    let subtitle: String
    let badges: [Badge]
    let ctaLabel: String
    let ctaIcon: String
    let url: URL

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                iconTile
                VStack(alignment: .leading, spacing: 3) {
                    Text(eyebrow)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundColor(PR.dim)
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(PR.fg)
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(PR.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !badges.isEmpty {
                HStack(spacing: 8) {
                    ForEach(badges) { badge in
                        HStack(spacing: 5) {
                            Image(systemName: badge.icon)
                                .font(.system(size: 9, weight: .semibold))
                            Text(badge.label)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(PR.fg2)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .overlay(Capsule().strokeBorder(PR.border, lineWidth: 1))
                    }
                    Spacer(minLength: 0)
                }
            }

            Button {
                openURL(url)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: ctaIcon)
                        .font(.system(size: 12, weight: .semibold))
                    Text(ctaLabel)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(PR.bg)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(PR.accent)
                .clipShape(RoundedRectangle(cornerRadius: PR.r8))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.rCard, style: .continuous))
    }

    private var iconTile: some View {
        Image("VampHostIcon")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    static var direct: VampHostPromoCard {
        VampHostPromoCard(
            eyebrow: "DIRECT DOWNLOAD",
            title: "Vamp Host",
            subtitle: "The open-source Mac host distributed directly by the project.",
            badges: [Badge(icon: "bolt.fill", label: "full build"), Badge(icon: "chevron.left.forwardslash.chevron.right", label: "open source")],
            ctaLabel: "Download",
            ctaIcon: "arrow.down.circle.fill",
            url: VampHostLinks.direct
        )
    }
}

/// Three-step Vamp Control explainer.
struct HowItWorksCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HOW VAMP REMOTE CONTROL WORKS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundColor(PR.dim)
            step(1, title: "Get Vamp Host on your Mac", detail: "Download it from mesut.uk or build it from source, then open it.")
            step(2, title: "Approve this iPhone", detail: "The first time, accept the connection on your Mac.")
            step(3, title: "Tap your Mac to connect", detail: "It shows up here — tap to mirror and control it.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.rCard, style: .continuous))
    }

    private func step(_ n: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(PR.accent.opacity(0.12)).frame(width: 28, height: 28)
                Text("\(n)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(PR.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(PR.fg)
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(PR.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// In-app connection-log viewer (the client's "debugger"): shows the shared eventLogStore the
/// session coordinator already writes to, newest-first, with a one-tap Copy so the user can paste
/// the log when reporting an issue. Mirrors the host's diagnostics/events screen.
@available(iOS 16.1, *)
private struct ClientDiagnosticsView: View {
    let environment: ClientAppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var items: [EventLogItem] = []
    @State private var copied = false
    // On-device "explain this log" (Apple Intelligence). Hidden unless available.
    @State private var explainAvailable = false
    @State private var explaining = false
    @State private var explanation: String?
    @State private var explainEngine: LogExplainer.Engine?
    @State private var summary: String?
    @State private var summarizing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if explainAvailable {
                        explainCard
                    }
                    if items.isEmpty {
                        Text("no events yet — connect to a Mac, then reopen this to see the log")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(PR.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 24)
                    }
                    ForEach(items.reversed()) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.severity.rawValue.uppercased())
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(color(for: item.severity))
                                Text(item.category)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(PR.dim)
                                Spacer(minLength: 6)
                                Text(item.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(PR.dim)
                            }
                            Text(item.message)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(PR.fg)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(PR.card)
                        .overlay(RoundedRectangle(cornerRadius: PR.r8).strokeBorder(PR.border, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: PR.r8))
                    }
                }
                .padding(12)
            }
            .background(PR.bg.ignoresSafeArea())
            .navigationTitle("connection log")
#if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "copied ✓" : "copy") { copyLog() }
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    @ViewBuilder private var explainCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(PR.accent)
                Text("explain this log")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(PR.fg)
                Spacer(minLength: 6)
                if explaining { ProgressView().controlSize(.small) }
            }
            if let explanation {
                Text(explanation)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(PR.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Button("analyze again") { Task { await explain() } }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(PR.accent)
                    .disabled(explaining)
            } else {
                Button(action: { Task { await explain() } }) {
                    Text(explaining ? "analyzing…" : "analyze")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(PR.bg)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(PR.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(explaining || items.isEmpty)
            }
            if let summary {
                Text(summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(PR.fg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: { Task { await summarize() } }) {
                Text(summarizing ? "summarizing…" : "summarize session")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(PR.accent)
            }
            .buttonStyle(.plain)
            .disabled(summarizing || items.isEmpty)
            Text(explainEngine.map { "answered by \($0.label) · your log isn’t stored or shared" }
                 ?? "runs privately — on-device or via Apple Private Cloud Compute; your log isn’t stored or shared")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(PR.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(PR.card)
        .overlay(RoundedRectangle(cornerRadius: PR.r8).strokeBorder(PR.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: PR.r8))
    }

    private func explain() async {
        explaining = true
        explanation = nil
        let result = await LogExplainer.explain(items)
        explanation = result?.text ?? "Couldn’t analyze the log right now — try again in a moment."
        explainEngine = result?.engine
        explaining = false
    }

    private func summarize() async {
        summarizing = true
        summary = nil
        summary = await SessionSummarizer.summarize(items) ?? "Couldn’t summarize the session right now."
        summarizing = false
    }

    private func reload() async {
        items = await environment.eventLogStore.recentItems(limit: 500)
        explainAvailable = LogExplainer.availability.isAvailable
    }

    private func copyLog() {
        let text = items.map { item in
            "\(item.timestamp.formatted(.iso8601)) [\(item.severity.rawValue)] \(item.category): \(item.message)"
        }.joined(separator: "\n")
#if canImport(UIKit)
        UIPasteboard.general.string = text
#endif
        copied = true
    }

    private func color(for severity: EventSeverity) -> Color {
        switch severity {
        case .error: return PR.err
        case .warning: return PR.warn
        case .info: return PR.accent2
        case .debug: return PR.dim
        }
    }
}
