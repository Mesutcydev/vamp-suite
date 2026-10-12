import SwiftUI

struct PRTerminalLine: View {
    enum Kind {
        case cmd
        case info
        case ok
        case warn
        case err
    }

    let text: String
    let kind: Kind

    var body: some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(color)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch kind {
        case .cmd: PR.fg
        case .info: PR.dim
        case .ok: PR.accent
        case .warn: PR.warn
        case .err: PR.err
        }
    }
}

#Preview("PRTerminalLine") {
    VStack(alignment: .leading, spacing: 1) {
        PRTerminalLine(text: "$ scan --lan", kind: .cmd)
        PRTerminalLine(text: "· broadcasting mDNS query", kind: .info)
        PRTerminalLine(text: "✓ found 3 host(s)", kind: .ok)
        PRTerminalLine(text: "! weak signal", kind: .warn)
        PRTerminalLine(text: "x failed to connect", kind: .err)
    }
    .padding(.vertical, 8)
    .background(PR.card)
}
