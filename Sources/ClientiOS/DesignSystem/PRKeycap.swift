import SwiftUI

struct PRKeycap: View {
    let combo: String
    var tint: Color = PR.accent

    var body: some View {
        Text(combo)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundColor(tint)
            .frame(minWidth: 50)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(tint.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

#Preview("PRKeycap") {
    HStack(spacing: 8) {
        PRKeycap(combo: "⌘C")
        PRKeycap(combo: "⌘⇧Z")
        PRKeycap(combo: "F11")
    }
    .padding()
    .background(PR.bg)
}
