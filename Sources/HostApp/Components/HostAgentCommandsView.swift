import SwiftUI

/// Quick-reference terminal commands for AI agents and automation scripts.
struct HostAgentCommandsView: View {
    enum Style {
        case settings
        case onboarding
    }

    var style: Style = .settings
    @State private var copiedCommand: String?

    private struct AgentCommand: Identifiable {
        let id: String
        let command: String
        let hint: String
    }

    private let commands: [AgentCommand] = [
        .init(id: "ensure", command: "vamp ensure", hint: "Start Vamp Host if needed; exit 0 when ready"),
        .init(id: "status", command: "vamp status --json", hint: "Machine-readable Vamp Host status"),
        .init(id: "version", command: "vamp version", hint: "Installed Vamp Host version and build"),
        .init(id: "pending", command: "vamp pending", hint: "Inspect pending trust request before approving"),
        .init(id: "approve-pairing", command: "vamp approve-pairing --fingerprint <hex>", hint: "Approve only when fingerprint matches"),
        .init(id: "approve-connection", command: "vamp approve-connection --fingerprint <hex>", hint: "Approve only when fingerprint matches"),
        .init(id: "terminal-list", command: "vamp terminal list", hint: "List persistent tmux/screen sessions that Vamp Terminal can resume"),
        .init(id: "terminal-start", command: "vamp terminal start --session work", hint: "Create a persistent shell for mobile handoff"),
        .init(id: "terminal-agent-opencode", command: "vamp terminal agent opencode --session opencode", hint: "Run OpenCode inside tmux so Vamp Terminal can reattach"),
        .init(id: "terminal-agent-pi", command: "vamp terminal agent pi --session pi", hint: "Run Pi inside tmux so Vamp Terminal can reattach"),
        .init(id: "terminal-agent-commandcode", command: "vamp terminal agent commandcode --session commandcode", hint: "Run CommandCode inside tmux so Vamp Terminal can reattach"),
        .init(id: "terminal-agent-chatgpt", command: "vamp terminal agent chatgpt --session chatgpt", hint: "Run ChatGPT CLI inside tmux so Vamp Terminal can reattach"),
        .init(id: "terminal-agent-claude", command: "vamp terminal agent claude --session claude", hint: "Run Claude Code inside tmux so Vamp Terminal can reattach"),
        .init(id: "terminal-agent-kimi", command: "vamp terminal agent kimi --session kimi", hint: "Run Kimi inside tmux so Vamp Terminal can reattach"),
        .init(id: "terminal-agent-qwen", command: "vamp terminal agent qwen --session qwen", hint: "Run Qwen Code inside tmux so Vamp Terminal can reattach"),
        .init(id: "terminal-agent-codex", command: "vamp terminal agent codex --session codex", hint: "Run Codex CLI inside tmux so Vamp Terminal can reattach"),
        .init(id: "terminal-agent-aider", command: "vamp terminal agent aider --session aider", hint: "Run Aider inside tmux so Vamp Terminal can reattach"),
        .init(id: "terminal-agent-grok", command: "vamp terminal agent grok --session grok", hint: "Run Grok CLI inside tmux so Vamp Terminal can reattach"),
        .init(id: "terminal-agent-gemini", command: "vamp terminal agent gemini --session gemini", hint: "Run Gemini CLI inside tmux so Vamp Terminal can reattach"),
        .init(id: "open", command: "open -b com.mesutcy.remotedesktop.host", hint: "Launch Vamp Host"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: style == .onboarding ? 12 : 8) {
            if style == .onboarding {
                Text("Cursor, Claude Code, and other agents can start and check this host from Terminal. The website DMG includes an optional CLI installer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Use the `vamp` CLI from Terminal to start or verify Vamp Host. Install its optional `/usr/local/bin/vamp` symlink from the release package.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(commands) { entry in
                commandRow(entry)
            }

            Link(destination: HostAppLinks.websiteURL) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Full agent docs")
                            .font(style == .onboarding ? .callout : .caption.weight(.medium))
                        Text(HostAppLinks.websiteDisplayPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    @ViewBuilder
    private func commandRow(_ entry: AgentCommand) -> some View {
        let isCopied = copiedCommand == entry.command
        Button {
            copyCommand(entry.command)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.command)
                        .font(.system(style == .onboarding ? .callout : .caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Text(entry.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.callout)
                    .foregroundStyle(isCopied ? Color.green : Color.secondary)
            }
            .padding(style == .onboarding ? 10 : 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy command")
    }

    private func copyCommand(_ command: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        #endif
        copiedCommand = command
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedCommand == command { copiedCommand = nil }
        }
    }
}
