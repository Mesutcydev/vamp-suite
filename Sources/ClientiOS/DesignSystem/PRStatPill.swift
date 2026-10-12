import SwiftUI

struct PRStatPill: View {
    let key: String
    let value: String
    var color: Color = PR.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key.uppercased())
                .font(.caption2)
                .foregroundColor(PR.dim)

            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r8, style: .continuous))
    }
}

#Preview("PRStatPill") {
    HStack(spacing: 8) {
        PRStatPill(key: "fps", value: "60")
        PRStatPill(key: "latency", value: "0.4ms", color: PR.accent2)
        PRStatPill(key: "state", value: "LIVE", color: PR.warn)
    }
    .padding()
    .background(PR.bg)
}
