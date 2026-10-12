import SwiftUI
import Discovery
import SharedModels

struct StreamStep: View {
    @ObservedObject var vm: OnboardingViewModel
    let onPick: (Host) -> Void
    @State private var blink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PRScreenHeader(title: "pair", host: "vamp.host", state: .live)

            VStack(spacing: 12) {
                terminalCard
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)

                if vm.foundNoHosts {
                    Button {
                        Task { await vm.rescan() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                            Text("rescan network")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(PR.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(RoundedRectangle(cornerRadius: PR.r8).strokeBorder(PR.accent.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                }

                if vm.pickedHost != nil, !vm.pairingDone {
                    VStack(spacing: 4) {
                        HStack {
                            Text("handshake")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(PR.dim)
                            Spacer()
                            Text("\(Int(vm.pairingProgress * 100))%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(PR.accent)
                                .monospacedDigit()
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(PR.border).frame(height: 4)
                                Capsule().fill(PR.accent)
                                    .frame(width: geo.size.width * vm.pairingProgress, height: 4)
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PR.bg)
    }

    private var terminalCard: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: 0xFF5F57)).frame(width: 10, height: 10)
                        Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 10, height: 10)
                        Circle().fill(Color(hex: 0x28C840)).frame(width: 10, height: 10)
                    }
                    Spacer(minLength: 0)
                }

                Text("vamp pending --json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(PR.dim)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 56)
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
            .background(PR.cardHi)

            Divider().overlay(PR.border)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if vm.lines.isEmpty {
                            HStack(spacing: 0) {
                                Text("· scanning for hosts…")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(PR.dim)
                                    .padding(.horizontal, 12)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 10)
                        }

                        ForEach(vm.lines) { line in
                            LogLineView(line: line) { host in
                                onPick(host)
                            }
                            .id(line.id)
                            .opacity(opacity(for: line))
                        }

                        if !vm.pairingDone, !vm.lines.isEmpty {
                            Rectangle()
                                .fill(PR.accent)
                                .frame(width: 8, height: 14)
                                .padding(.leading, 12)
                                .opacity(blink ? 0 : 1)
                                .onAppear {
                                    withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: true)) {
                                        blink.toggle()
                                    }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onChangeCompat(of: vm.lines.count) { _ in
                    guard vm.lines.count > 10 else { return }
                    guard let lastID = vm.lines.last?.id else { return }
                    withAnimation(.linear(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.rCard, style: .continuous))
    }

    private func opacity(for line: OnboardingViewModel.LogLine) -> Double {
        guard line.kind == .host, let picked = vm.pickedHost else { return 1 }
        return line.host?.id == picked.id ? 1 : 0.4
    }
}

private struct LogLineView: View {
    let line: OnboardingViewModel.LogLine
    let onPick: (Host) -> Void

    var body: some View {
        if line.kind == .host, let host = line.host {
            Button {
                onPick(host)
            } label: {
                HStack(spacing: 10) {
                    Text(">")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(PR.accent)

                    Text(line.text)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(PR.fg)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("tap")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(PR.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(PR.accent.opacity(0.16))
                        .overlay(
                            Capsule().strokeBorder(PR.accent.opacity(0.45), lineWidth: 1)
                        )
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(PR.bg2)
                .overlay(
                    RoundedRectangle(cornerRadius: PR.r8)
                        .strokeBorder(PR.accent.opacity(0.35), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: PR.r8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        } else {
            HStack(spacing: 0) {
                Text(line.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(color(for: line.kind))
                    .padding(.horizontal, 12)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
        }
    }

    private func color(for kind: OnboardingViewModel.LogLine.Kind) -> Color {
        switch kind {
        case .cmd: return PR.fg
        case .info: return PR.dim
        case .ok: return PR.accent
        case .warn: return PR.warn
        case .err: return PR.err
        case .prompt: return PR.warn
        case .code: return PR.warn
        case .host: return PR.fg
        }
    }
}

#Preview("StreamStep") {
    let vm = OnboardingViewModel()
    StreamStep(vm: vm, onPick: { _ in })
        .task {
            await vm.startStream(known: [
                Host(
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
                )
            ])
        }
        .background(PR.bg)
}
