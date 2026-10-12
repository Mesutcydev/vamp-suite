import SwiftUI
import SharedProtocol

#if canImport(UIKit)
import UIKit
#endif

/// Neutral visual language for Vamp Terminal.
///
/// This deliberately keeps color out of structural chrome. The backdrop gives
/// clear material something to refract, while the surfaces themselves remain
/// system-owned glass with a hairline optical rim. Green, amber, and red are
/// reserved for connection state and errors.
enum VampTerminalDesign {
    /// A four-point base grid keeps card padding, control heights, and gaps
    /// divisible across iPhone and iPad widths.
    static let unit: CGFloat = 4
    static let space1 = unit
    static let space2 = unit * 2
    static let space3 = unit * 3
    static let space4 = unit * 4
    static let space5 = unit * 5
    static let space6 = unit * 6
    static let space7 = unit * 7

    static let minTapTarget = unit * 11
    static let compactControlHeight = unit * 10
    static let controlHeight = unit * 11
    static let cardRadius = unit * 4
    static let largeCardRadius = unit * 5
    static let controlRadius = unit * 3
    static let smallRadius = unit * 2
    static let tabRadius = unit * 2.5
    /// Cards share a common baseline height while still growing naturally for
    /// Dynamic Type and longer host diagnostics.
    static let cardMinHeight = unit * 20
    static let hostCardMinHeight = unit * 24
    /// Chat is a readable activity feed, so a full-screen terminal repaint
    /// must stay inside a bounded card. The Raw view remains the escape hatch
    /// for inspecting the complete PTY stream.
    static let chatOutputMaxHeight = unit * 56

    static let heroTitleSize: CGFloat = 22
    static let sectionTitleSize: CGFloat = 16
    static let bodySize: CGFloat = 15
    static let footnoteSize: CGFloat = 13
    static let captionSize: CGFloat = 11
}

enum VampGlassPalette {
    static let ink = Color.primary
    static let inkSecondary = adaptive(light: Color(white: 0.44), dark: Color(white: 0.63))
    static let inkTertiary = adaptive(light: Color(white: 0.63), dark: Color(white: 0.44))
    static let inkSubtle = adaptive(light: Color(white: 0.72), dark: Color(white: 0.51))

    /// Hairlines read as a 1px rule on the flat surfaces below them.
    static let rule = Color.primary.opacity(0.12)
    static let ruleStrong = Color.primary.opacity(0.22)

    /// Flat card/panel fills: white cards on light grouped background, zinc
    /// panels on a near-black page. Surfaces are opaque, not materials.
    static let surfaceFill = adaptive(light: .white, dark: Color(red: 0.094, green: 0.094, blue: 0.102))
    static let surfaceRaised = adaptive(light: Color(red: 0.957, green: 0.961, blue: 0.965), dark: Color(red: 0.153, green: 0.157, blue: 0.169))

    static let good = Color.green
    static let warning = Color.orange
    static let bad = Color.red

    /// Resolves a fixed light/dark pair against the current interface style.
    static func adaptive(light: Color, dark: Color) -> Color {
#if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
#else
        light
#endif
    }
}

/// Provider launch profiles are intentionally a UI concern. Vamp Terminal
/// still transports an ordinary PTY, but a profile gives a tab a stable name,
/// an obvious visual identity, and a safe tmux handoff command.
extension VampAgentProvider {
    var displayName: String {
        switch self {
        case .openCode: return "OpenCode"
        case .pi: return "Pi"
        case .commandCode: return "CommandCode"
        case .chatGPT: return "ChatGPT CLI"
        case .claude: return "Claude Code"
        case .kimi: return "Kimi"
        case .qwen: return "Qwen Code"
        case .codex: return "Codex CLI"
        case .aider: return "Aider"
        case .grok: return "Grok CLI"
        case .gemini: return "Gemini CLI"
        }
    }

    /// This is the executable expected in the host login shell. It is not
    /// run by iOS and is deliberately displayed in the launcher UI.
    var executable: String {
        switch self {
        case .openCode: return "opencode"
        case .pi: return "pi"
        // Command Code's installed package is `command-code`, but its actual
        // launcher is the short `cmd` executable. Keeping the package name in
        // the UI while using the real binary prevents a tab from opening only
        // to print "commandcode: command not found".
        case .commandCode: return "cmd"
        // There is no separate supported `chatgpt` executable. OpenAI's
        // supported terminal client is Codex CLI; keep this legacy profile as
        // an alias so the ChatGPT entry remains useful on hosts that have
        // Codex installed.
        case .chatGPT: return "codex"
        case .claude: return "claude"
        case .kimi: return "kimi"
        case .qwen: return "qwen"
        case .codex: return "codex"
        case .aider: return "aider"
        case .grok: return "grok"
        case .gemini: return "gemini"
        }
    }

    var sessionName: String {
        switch self {
        case .openCode: return "opencode"
        case .pi: return "pi"
        case .commandCode: return "command-code"
        case .chatGPT: return "chatgpt"
        case .claude: return "claude"
        case .kimi: return "kimi"
        case .qwen: return "qwen"
        case .codex: return "codex"
        case .aider: return "aider"
        case .grok: return "grok"
        case .gemini: return "gemini"
        }
    }

    var startupCommand: String {
        let shellExecutable = Self.shellQuote(executable)
        let shellSession = Self.shellQuote(sessionName)
        let shellDisplayName = Self.shellQuote(displayName)
        return "if ! command -v tmux >/dev/null 2>&1; then printf '\\nVamp Terminal: tmux is not installed or not on PATH.\\n'; elif ! command -v \(shellExecutable) >/dev/null 2>&1; then printf '\\nVamp Terminal: \(shellDisplayName) CLI (\(shellExecutable)) is not installed or not on PATH.\\n'; else tmux new-session -A -s \(shellSession) -- \(shellExecutable); fi"
    }

    /// Returns a direct process launch configuration. A persisted/resumed
    /// agent uses tmux, while a session-only launch execs the provider itself.
    /// Neither path echoes a shell bootstrap script into the PTY transcript.
    func launchConfiguration(
        resumeMode: ResumeMode,
        persistenceMode: PersistenceMode,
        workspaceID: UUID? = nil
    ) -> (executable: String, arguments: [String]) {
        guard persistenceMode == .preserveWithTmux || resumeMode == .resumePrevious else {
            return (executable, [])
        }
        let scopedSessionName: String
        if let workspaceID {
            let suffix = String(workspaceID.uuidString.prefix(8)).lowercased()
            scopedSessionName = "\(sessionName)-\(suffix)"
        } else {
            scopedSessionName = sessionName
        }
        if resumeMode == .resumePrevious {
            return ("tmux", ["new-session", "-A", "-s", scopedSessionName, "--", executable])
        }

        // `tmux new-session -A` means "attach if this name already exists".
        // Using it for a user-selected *New session* silently reused stale or
        // wedged agents and left the UI connected to a process that could not
        // answer. Replace that named session first, then exec a clean one.
        // The command is an app-owned constant assembled only from this enum
        // and a UUID-derived name; it is never user-authored terminal input.
        let command = "tmux kill-session -t \(Self.shellQuote(scopedSessionName)) 2>/dev/null || true; exec tmux new-session -s \(Self.shellQuote(scopedSessionName)) -- \(Self.shellQuote(executable))"
        return ("zsh", ["-f", "-c", command])
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var assetName: String? {
        switch self {
        case .openCode: return "ProviderOpenCode"
        case .claude: return "ProviderClaude"
        case .kimi: return "ProviderKimi"
        case .grok: return "ProviderGrok"
        case .codex, .chatGPT: return "ProviderOpenAI"
        case .pi, .commandCode, .qwen, .aider: return nil
        case .gemini: return nil
        }
    }

    /// Local reference assets are used where they exist. For Pi, CommandCode,
    /// and Qwen the reference project has no logo, so the fallback mark is
    /// deliberately typographic rather than pretending to be an official
    /// vendor asset.
    var markLabel: String {
        switch self {
        case .pi: return "π"
        case .commandCode: return "⌘"
        case .qwen: return "QW"
        case .aider: return "A"
        case .grok: return "G"
        case .gemini: return "Gm"
        default: return "·"
        }
    }

    /// Menu labels need an actual Image view to preserve their icon when
    /// SwiftUI bridges a Menu into a UIKit context menu. These symbols are
    /// intentionally generic, product-neutral marks for providers without a
    /// bundled logo; they keep the row identifiable without fabricating
    /// vendor artwork.
    var fallbackSystemImage: String {
        switch self {
        case .pi: return "circle.dotted"
        case .commandCode: return "command"
        case .qwen: return "q.circle"
        case .aider: return "a.circle"
        case .grok: return "x.circle"
        case .gemini: return "sparkles"
        default: return "terminal"
        }
    }

    var accent: Color {
        switch self {
        case .openCode: return Color(red: 0.00, green: 0.78, blue: 0.80)
        case .pi: return Color(red: 0.96, green: 0.48, blue: 0.28)
        case .commandCode: return Color(red: 0.72, green: 0.52, blue: 1.00)
        case .chatGPT, .codex: return Color(red: 0.06, green: 0.64, blue: 0.49)
        case .claude: return Color(red: 0.86, green: 0.40, blue: 0.25)
        case .kimi: return Color(red: 0.30, green: 0.56, blue: 1.00)
        case .qwen: return Color(red: 0.27, green: 0.47, blue: 0.95)
        case .aider: return Color(red: 0.40, green: 0.76, blue: 0.55)
        case .grok: return Color(red: 0.90, green: 0.66, blue: 0.28)
        case .gemini: return Color(red: 0.35, green: 0.55, blue: 0.98)
        }
    }

    var terminalBackground: Color {
        switch self {
        case .openCode: return Color(red: 0.025, green: 0.035, blue: 0.037)
        case .pi: return Color(red: 0.075, green: 0.045, blue: 0.035)
        case .commandCode: return Color(red: 0.045, green: 0.035, blue: 0.075)
        case .chatGPT, .codex: return Color(red: 0.025, green: 0.055, blue: 0.045)
        case .claude: return Color(red: 0.075, green: 0.055, blue: 0.050)
        case .kimi: return Color(red: 0.035, green: 0.050, blue: 0.090)
        case .qwen: return Color(red: 0.035, green: 0.050, blue: 0.105)
        case .aider: return Color(red: 0.035, green: 0.075, blue: 0.050)
        case .grok: return Color(red: 0.070, green: 0.055, blue: 0.025)
        case .gemini: return Color(red: 0.035, green: 0.050, blue: 0.100)
        }
    }

    var terminalText: Color {
        switch self {
        case .openCode: return Color(red: 0.84, green: 0.98, blue: 0.96)
        case .pi: return Color(red: 1.00, green: 0.91, blue: 0.84)
        case .commandCode: return Color(red: 0.93, green: 0.88, blue: 1.00)
        case .chatGPT, .codex: return Color(red: 0.88, green: 1.00, blue: 0.95)
        case .claude: return Color(red: 1.00, green: 0.94, blue: 0.91)
        case .kimi: return Color(red: 0.88, green: 0.93, blue: 1.00)
        case .qwen: return Color(red: 0.88, green: 0.93, blue: 1.00)
        case .aider: return Color(red: 0.88, green: 1.00, blue: 0.91)
        case .grok: return Color(red: 1.00, green: 0.95, blue: 0.82)
        case .gemini: return Color(red: 0.90, green: 0.94, blue: 1.00)
        }
    }

#if canImport(UIKit)
    var terminalBackgroundUIColor: UIColor {
        switch self {
        case .openCode: return UIColor(red: 0.025, green: 0.035, blue: 0.037, alpha: 1)
        case .pi: return UIColor(red: 0.075, green: 0.045, blue: 0.035, alpha: 1)
        case .commandCode: return UIColor(red: 0.045, green: 0.035, blue: 0.075, alpha: 1)
        case .chatGPT, .codex: return UIColor(red: 0.025, green: 0.055, blue: 0.045, alpha: 1)
        case .claude: return UIColor(red: 0.075, green: 0.055, blue: 0.050, alpha: 1)
        case .kimi: return UIColor(red: 0.035, green: 0.050, blue: 0.090, alpha: 1)
        case .qwen: return UIColor(red: 0.035, green: 0.050, blue: 0.105, alpha: 1)
        case .aider: return UIColor(red: 0.035, green: 0.075, blue: 0.050, alpha: 1)
        case .grok: return UIColor(red: 0.070, green: 0.055, blue: 0.025, alpha: 1)
        case .gemini: return UIColor(red: 0.035, green: 0.050, blue: 0.100, alpha: 1)
        }
    }

    var terminalTextUIColor: UIColor {
        switch self {
        case .openCode: return UIColor(red: 0.84, green: 0.98, blue: 0.96, alpha: 1)
        case .pi: return UIColor(red: 1.00, green: 0.91, blue: 0.84, alpha: 1)
        case .commandCode: return UIColor(red: 0.93, green: 0.88, blue: 1.00, alpha: 1)
        case .chatGPT, .codex: return UIColor(red: 0.88, green: 1.00, blue: 0.95, alpha: 1)
        case .claude: return UIColor(red: 1.00, green: 0.94, blue: 0.91, alpha: 1)
        case .kimi: return UIColor(red: 0.88, green: 0.93, blue: 1.00, alpha: 1)
        case .qwen: return UIColor(red: 0.88, green: 0.93, blue: 1.00, alpha: 1)
        case .aider: return UIColor(red: 0.88, green: 1.00, blue: 0.91, alpha: 1)
        case .grok: return UIColor(red: 1.00, green: 0.95, blue: 0.82, alpha: 1)
        case .gemini: return UIColor(red: 0.90, green: 0.94, blue: 1.00, alpha: 1)
        }
    }
#endif
}

struct VampProviderMark: View {
    let provider: VampAgentProvider
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(provider.accent.opacity(0.13))

            if let assetName = provider.assetName {
                Image(assetName)
                    .resizable()
                    // Provider files are square artwork, not terminal
                    // thumbnails. Fit the complete mark so its border and
                    // central symbol are never cropped differently per row.
                    .scaledToFit()
                    .padding(size * 0.10)
            } else {
                Image(systemName: provider.fallbackSystemImage)
                    .font(.system(size: size * 0.43, weight: .semibold))
                    .minimumScaleFactor(0.58)
                    .foregroundStyle(provider.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(provider.accent.opacity(0.42), lineWidth: 0.8)
        }
        .accessibilityHidden(true)
    }
}

enum VampGlassRole {
    case card
    case button
    case field
    case icon
    case toolbar
    case tab
    case capsule

    var cornerRadius: CGFloat {
        switch self {
        case .card: return VampTerminalDesign.largeCardRadius
        case .button: return 14
        case .field: return 16
        case .icon: return 16
        case .toolbar: return 0
        case .tab: return 12
        case .capsule: return 999
        }
    }

    var isInteractive: Bool {
        switch self {
        case .button, .field, .icon, .tab, .capsule: return true
        case .card, .toolbar: return false
        }
    }

    /// A compact control needs a slightly stronger rim than a broad card.
    var materialOpacity: Double {
        switch self {
        case .card: return 0.30
        case .button: return 0.38
        case .field: return 0.34
        case .icon: return 0.38
        case .toolbar: return 0.26
        case .tab: return 0.34
        case .capsule: return 0.40
        }
    }
}

struct VampTerminalBackdrop: View {
    var body: some View {
        ZStack {
            groupedBackground
            // The flat task surface needs no wallpaper, grid, or ambient light
            // behind its white cards. The grouped background supplies the
            // ZCode-style page field.
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var groupedBackground: Color {
#if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
#else
        Color.black
#endif
    }
}

#if os(iOS) && compiler(>=6.2)
@available(iOS 26.0, *)
private func vampNativeGlass(for role: VampGlassRole) -> Glass {
    role.isInteractive ? Glass.clear.interactive() : Glass.clear
}
#endif

private struct VampGlassSurfaceModifier: ViewModifier {
    let role: VampGlassRole
    let cornerRadius: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        let radius = cornerRadius ?? role.cornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let fill = role == .toolbar ? VampGlassPalette.surfaceRaised : VampGlassPalette.surfaceFill
        content.background(fill, in: shape)
    }
}

extension View {
    func vampGlassSurface(
        _ role: VampGlassRole = .card,
        cornerRadius: CGFloat? = nil
    ) -> some View {
        modifier(VampGlassSurfaceModifier(role: role, cornerRadius: cornerRadius))
    }

    func vampGlassOutline(
        cornerRadius: CGFloat,
        color: Color = VampGlassPalette.rule,
        lineWidth: CGFloat = 0.5
    ) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(color, lineWidth: lineWidth)
        }
    }
}

struct VampGlassPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? 0.035 : 0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.84),
                value: configuration.isPressed
            )
    }
}

struct VampTerminalSectionLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(VampGlassPalette.inkSecondary)

            Rectangle()
                .fill(VampGlassPalette.ruleStrong)
                .frame(height: 1)

            if let detail {
                Text(detail)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(VampGlassPalette.inkTertiary)
            }
        }
    }
}

struct VampGlassStatusPill: View {
    let text: String
    let color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.35)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .overlay { Capsule().stroke(color.opacity(0.28), lineWidth: 0.5) }
    }
}

struct VampGlassIconTile: View {
    let systemImage: String
    var size: CGFloat = 58
    var tint: Color = VampGlassPalette.ink

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.38, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .vampGlassSurface(.icon, cornerRadius: size * 0.28)
            .vampGlassOutline(cornerRadius: size * 0.28, color: VampGlassPalette.ruleStrong)
    }
}

struct VampGlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content

    init(cornerRadius: CGFloat = 18, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content
    }

    var body: some View {
        content()
            .vampGlassSurface(.card, cornerRadius: cornerRadius)
            .vampGlassOutline(cornerRadius: cornerRadius)
    }
}
