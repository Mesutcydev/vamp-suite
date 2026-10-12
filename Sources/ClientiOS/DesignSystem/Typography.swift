import SwiftUI

enum PRType {
    static func title(_ s: String) -> Text {
        Text(s)
            .font(.system(size: 26, weight: .semibold))
            .tracking(-0.4)
    }

    static func bigTitle(_ s: String) -> Text {
        Text(s)
            .font(.system(size: 30, weight: .semibold))
            .tracking(-0.6)
    }

    static func mono(_ s: String, size: CGFloat = 12, weight: Font.Weight = .regular) -> Text {
        Text(s)
            .font(.system(size: size, weight: weight, design: .monospaced))
    }

    static func sectionHeader(_ s: String) -> Text {
        mono("// \(s)", size: 10, weight: .semibold)
            .foregroundColor(.clear)
    }
}

#Preview("PR Type") {
    VStack(alignment: .leading, spacing: 8) {
        PRType.bigTitle("mirror").foregroundColor(PR.fg)
        PRType.title("hosts").foregroundColor(PR.fg)
        PRType.mono("$ connect --ip", size: 12).foregroundColor(PR.accent)
        PRType.sectionHeader("stream").foregroundColor(PR.dim)
    }
    .padding()
    .background(PR.bg)
}
