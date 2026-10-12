import SwiftUI

struct PRToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? PR.accent.opacity(0.2) : PR.fg2.opacity(0.18))
                    .overlay(
                        Capsule().strokeBorder(isOn ? PR.accent : PR.borderHi)
                    )
                    .frame(width: 38, height: 22)

                Circle()
                    .fill(isOn ? PR.accent : PR.fg.opacity(0.82))
                    .frame(width: 16, height: 16)
                    .padding(.horizontal, 3)
                    .shadow(color: isOn ? PR.accent.opacity(0.6) : .clear, radius: 4)
            }
            .animation(.easeInOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

#Preview("PRToggle") {
    PreviewPRToggle()
}

private struct PreviewPRToggle: View {
    @State private var enabled = true

    var body: some View {
        VStack(spacing: 12) {
            PRToggle(isOn: $enabled)
            Text(enabled ? "on" : "off")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(PR.fg)
        }
        .padding()
        .background(PR.bg)
    }
}
