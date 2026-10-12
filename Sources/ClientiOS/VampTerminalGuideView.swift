import SwiftUI

/// The terminal manual lives in the client so a first-time user can learn the
/// workflow before pairing. Diagrams are native SwiftUI shapes/icons: they
/// stay crisp on iPhone, iPad, Dynamic Type, and high-contrast settings.
struct VampTerminalGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    guideIntro

                    guideStep(
                        number: "01",
                        title: "Pair the Mac once",
                        body: "Keep Vamp Host open, enable Terminal Mode in Settings, then approve this device when the signed pairing prompt appears. LAN discovery and Tailscale addresses use the same trusted identity.",
                        diagram: .pairing
                    )
                    guideStep(
                        number: "02",
                        title: "Keep shells in tabs",
                        body: "Tap + for another independent PTY. Each tab keeps its scrollback, working directory, process, resize, and output while you switch away. Up to eight tabs are available per connection.",
                        diagram: .tabs
                    )
                    guideStep(
                        number: "03",
                        title: "Resume work in the middle",
                        body: "A new PTY is intentionally fresh after reconnect. To carry a shell or agent between Mac Terminal, Vamp Terminal, and Safari, start it inside tmux or GNU screen and attach it from the tab menu.",
                        diagram: .handoff
                    )
                    guideStep(
                        number: "04",
                        title: "Use the phone-friendly controls",
                        body: "The terminal supports paste, copy selection, host clipboard read/write, Ctrl/Alt/Esc/Tab, arrows, paging, and pinch-to-resize. The accessory row stays horizontally scrollable so small iPhones keep 44-point targets.",
                        diagram: .controls
                    )
                    guideStep(
                        number: "05",
                        title: "Launch agents without losing them",
                        body: "Use the tab menu for Claude Code, Codex CLI, Aider, or OpenCode. Those launchers use tmux-backed sessions so the agent can continue while you change tabs or reconnect later.",
                        diagram: .agents
                    )

                    browserNote
                    safetyNote
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(VampTerminalBackdrop())
            .navigationTitle("How to use")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var guideIntro: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("A readable remote shell, built for small screens.")
                .font(.title2.weight(.semibold))
                .foregroundStyle(VampGlassPalette.ink)
            Text("Vamp Terminal keeps the interaction close to a real task workspace: stable tabs, explicit connection states, and controls that stay reachable when the keyboard is open.")
                .font(.body)
                .foregroundStyle(VampGlassPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .vampGlassSurface(.card, cornerRadius: 18)
        .vampGlassOutline(cornerRadius: 18, color: VampGlassPalette.ruleStrong)
    }

    private func guideStep(
        number: String,
        title: String,
        body: String,
        diagram: VampGuideDiagram.Kind
    ) -> some View {
        VampGlassCard(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(number)
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(VampGlassPalette.inkTertiary)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(VampGlassPalette.ink)
                }
                Text(body)
                    .font(.body)
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VampGuideDiagram(kind: diagram)
            }
            .padding(15)
        }
    }

    private var browserNote: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "safari")
                .font(.headline)
                .foregroundStyle(VampGlassPalette.ink)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("Safari task chat is available too")
                    .font(.headline)
                    .foregroundStyle(VampGlassPalette.ink)
                Text("On the Mac, open Host Settings → Safari control, copy the Tailscale Serve command, and open its private HTTPS URL in Safari. Pair with the 12-digit host code. The browser workspace supports the same eight-tab PTY limit, command approval cards, clipboard, tmux/screen handoff, and agent launchers.")
                    .font(.footnote)
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .vampGlassSurface(.card, cornerRadius: 16)
        .vampGlassOutline(cornerRadius: 16)
        .accessibilityElement(children: .combine)
    }

    private var safetyNote: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "lock.shield")
                .foregroundStyle(VampGlassPalette.good)
                .frame(width: 24)
            Text("On Vamp Host, Terminal Mode is opt-in. On Vamp Terminal Host it is always on. Commands travel through the authenticated session. A dropped connection detaches the client; it does not destroy host PTYs. Reattach, or use tmux/screen for shells that must outlive the app.")
                .font(.footnote)
                .foregroundStyle(VampGlassPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .vampGlassSurface(.card, cornerRadius: 16)
        .vampGlassOutline(cornerRadius: 16, color: VampGlassPalette.good.opacity(0.28))
        .accessibilityElement(children: .combine)
    }
}

private struct VampGuideDiagram: View {
    enum Kind { case pairing, tabs, handoff, controls, agents }
    let kind: Kind

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 116)
            .padding(12)
            .vampGlassSurface(.field, cornerRadius: 14)
            .vampGlassOutline(cornerRadius: 14)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .pairing:
            HStack(spacing: 12) {
                diagramDevice("iPhone", systemImage: "iphone")
                Image(systemName: "lock.shield")
                    .font(.title3)
                    .foregroundStyle(VampGlassPalette.good)
                diagramDevice("Vamp Host", systemImage: "desktopcomputer")
            }
            .accessibilityLabel("iPhone connects through a secure pairing lock to Vamp Host")
        case .tabs:
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 7) {
                    diagramTab("build", active: true)
                    diagramTab("agent", active: false)
                    diagramTab("logs", active: false)
                    Spacer(minLength: 0)
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                }
                HStack(spacing: 7) {
                    Circle().fill(VampGlassPalette.good).frame(width: 7, height: 7)
                    Text("$ git status")
                        .font(.callout.monospaced())
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                }
            }
            .accessibilityLabel("Three stable terminal tabs named build, agent, and logs")
        case .handoff:
            VStack(alignment: .leading, spacing: 6) {
                guideCommand("$ tmux new-session -A -s work")
                guideCommand("$ screen -r work")
                Text("attach the same session from another device")
                    .font(.caption)
                    .foregroundStyle(VampGlassPalette.inkTertiary)
            }
            .accessibilityLabel("Use tmux or screen commands to resume a session")
        case .controls:
            HStack(spacing: 7) {
                ForEach(["ctrl", "esc", "tab", "↑", "⌘V"], id: \.self) { key in
                    Text(key)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(VampGlassPalette.ink)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 40)
                        .vampGlassSurface(.button, cornerRadius: 8)
                        .vampGlassOutline(cornerRadius: 8)
                }
                Image(systemName: "arrow.up.doc")
                    .foregroundStyle(VampGlassPalette.inkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Terminal accessory keys for control, escape, tab, arrows, and paste")
        case .agents:
            HStack(spacing: 8) {
                ForEach(["Claude", "Codex", "Aider"], id: \.self) { name in
                    VStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text(name)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .vampGlassSurface(.button, cornerRadius: 10)
                    .vampGlassOutline(cornerRadius: 10)
                }
            }
            .accessibilityLabel("Agent launchers for Claude, Codex, and Aider")
        }
    }

    private func diagramDevice(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.title2)
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(VampGlassPalette.ink)
        .frame(maxWidth: .infinity, minHeight: 68)
        .vampGlassSurface(.button, cornerRadius: 12)
        .vampGlassOutline(cornerRadius: 12)
    }

    private func diagramTab(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.caption.monospaced().weight(active ? .bold : .medium))
            .foregroundStyle(active ? VampGlassPalette.ink : VampGlassPalette.inkTertiary)
            .padding(.horizontal, 9)
            .frame(minHeight: 32)
            .background(active ? Color.primary.opacity(0.12) : Color.clear, in: Capsule())
    }

    private func guideCommand(_ text: String) -> some View {
        Text(text)
            .font(.callout.monospaced())
            .foregroundStyle(VampGlassPalette.inkSecondary)
            .textSelection(.enabled)
    }
}

/// Dismissible companion promotion shown on the client home screen. The host
/// settings card uses the same neutral visual language but a host-specific
/// implementation so the iOS target never links macOS-only APIs.
struct VampHostPromoCard: View {
    @Environment(\.openURL) private var openURL
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VampGlassIconTile(systemImage: "desktopcomputer", size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vamp Host + Tailscale")
                        .font(.headline)
                        .foregroundStyle(VampGlassPalette.ink)
                    Text("Pair your Mac, then use the open-source terminal client from iPhone, iPad, or Safari.")
                        .font(.footnote)
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VampGlassPalette.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss Vamp Host promotion")
            }
            Button {
                if let url = URL(string: "https://thevamp.app/#download") {
                    openURL(url)
                }
            } label: {
                Label("Learn about Vamp Host", systemImage: "arrow.up.right.square")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vampGlassSurface(.card, cornerRadius: 16)
        .vampGlassOutline(cornerRadius: 16)
        .accessibilityElement(children: .contain)
    }
}
