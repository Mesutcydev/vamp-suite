import SwiftUI

struct PRRow<Trailing: View>: View {
    let label: LocalizedStringKey
    var hint: LocalizedStringKey? = nil
    @ViewBuilder var trailing: () -> Trailing
    var onTap: (() -> Void)? = nil
    var isLast: Bool = false

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.body)
                        .foregroundColor(PR.fg)
                    if let hint {
                        Text(hint)
                            .font(.caption)
                            .foregroundColor(PR.dim)
                    }
                }
                Spacer()
                trailing()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if !isLast {
                Divider().overlay(PR.border)
            }
        }
    }
}

#Preview("PRRow") {
    PRCard("runtime") {
        PRRow(label: "$ connect --ip", hint: "enter address", trailing: {
            Image(systemName: "chevron.right")
                .foregroundColor(PR.dim)
        }, onTap: {}, isLast: false)

        PRRow(label: "$ connect --qr", hint: "scan code", trailing: {
            Image(systemName: "qrcode")
                .foregroundColor(PR.accent)
        }, onTap: {}, isLast: true)
    }
    .padding()
    .background(PR.bg)
}
