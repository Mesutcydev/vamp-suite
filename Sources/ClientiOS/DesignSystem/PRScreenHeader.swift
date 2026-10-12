import SwiftUI

struct PRScreenHeader: View {
    enum State: String {
        case live
        case idle
        case error
    }

    let title: LocalizedStringKey
    let host: String
    var latency: String = ""
    var state: State = .live

    private var dot: Color {
        switch state {
        case .live: PR.accent
        case .idle: PR.warn
        case .error: PR.err
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dot)
                    .frame(width: 6, height: 6)
                    .shadow(color: dot.opacity(0.7), radius: 4)

                Text(host)
                    .font(.caption)
                    .foregroundColor(PR.fg2)

                if !latency.isEmpty {
                    Text("·").foregroundColor(PR.dim)
                    Text(latency)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(dot)
                }

                Spacer()

                Text(state.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(PR.dim)
            }

            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundColor(PR.fg)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .prGlassSurface(in: Rectangle())
    }
}

#Preview("PRScreenHeader") {
    PRScreenHeader(title: "mirror", host: "joel-studio.local", latency: "0.5ms", state: .live)
        .background(PR.bg)
}
