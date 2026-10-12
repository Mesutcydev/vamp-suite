import SwiftUI
import Discovery
import SharedModels

struct DoneStep: View {
    let host: Host
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            PRScreenHeader(title: "done", host: host.displayName, latency: "", state: .live)

            VStack(spacing: 12) {
                PRCard("paired") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Trusted host is ready")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(PR.fg)
                        Text(host.fingerprint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(PR.dim)
                        Text("Signal: \(host.signal.rawValue)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(PR.accent)
                    }
                }

                Button(action: finish) {
                    Text("open mirror")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(PR.bg)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(PR.accent)
                        .clipShape(RoundedRectangle(cornerRadius: PR.r8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)

            Spacer()
        }
        .background(PR.bg)
    }
}

#Preview("DoneStep") {
    DoneStep(
        host: Host(
            id: "joel-studio",
            displayName: "joel-studio.local",
            ip: "192.168.1.42",
            model: "M2 Max",
            signal: .lan,
            fingerprint: "SHA256:7f3c…b201",
            endpoint: ResolvedHostEndpoint(
                hostname: "192.168.1.42",
                port: 9471,
                metadata: HostAdvertisementMetadata(
                    protocolVersion: 1,
                    hostID: UUID(),
                    displayName: "joel-studio.local",
                    appVersion: "3.1.0",
                    signalingPort: 9471,
                    capabilities: HostCapabilityFlags(stableNames: []),
                    supportedCodecs: ["h264"],
                    availability: .available
                ),
                resolvedAt: Date()
            )
        ),
        finish: {}
    )
    .background(PR.bg)
}
