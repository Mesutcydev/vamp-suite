import Foundation

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step {
        case welcome
        case stream
        case done
    }

    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let kind: Kind
        let text: String
        let host: Host?

        enum Kind {
            case cmd
            case info
            case ok
            case warn
            case err
            case prompt
            case code
            case host
        }
    }

    @Published var step: Step = .welcome
    @Published var lines: [LogLine] = []
    @Published var pickedHost: Host?
    @Published var pairingProgress: Double = 0
    @Published var pairingDone = false
    @Published var foundNoHosts = false

    private var knownHosts: [Host] = []

    func updateKnownHosts(_ hosts: [Host]) {
        knownHosts = hosts
    }

    func rescan() async {
        await startStream(known: knownHosts)
    }

    func startStream(known: [Host]) async {
        lines.removeAll()
        pickedHost = nil
        pairingProgress = 0
        pairingDone = false
        foundNoHosts = false
        knownHosts = known

        let script: [LogLine] = [
            .init(kind: .cmd, text: "$ vamp ensure", host: nil),
            .init(kind: .info, text: "· checking Vamp Host status", host: nil),
            .init(kind: .info, text: "· reading signed peer identity", host: nil),
            .init(kind: .ok, text: "✓ key fingerprint: SHA256:7f3c…b201", host: nil),
            .init(kind: .cmd, text: "$ scan --lan", host: nil),
            .init(kind: .info, text: "· broadcasting mDNS query", host: nil),
            .init(kind: .ok, text: "✓ found \(known.count) host(s)", host: nil)
        ]

        for line in script {
            lines.append(line)
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        if known.isEmpty {
            lines.append(.init(kind: .warn, text: "· no hosts on this network", host: nil))
            foundNoHosts = true
            return
        }

        for (i, host) in known.enumerated() {
            let latency = String(format: "%.1f ms", Double(i) * 0.5 + 0.4)
            let text = "\(host.displayName.padding(toLength: 28, withPad: " ", startingAt: 0)) \(host.model.padding(toLength: 9, withPad: " ", startingAt: 0)) \(latency)"
            lines.append(.init(kind: .host, text: text, host: host))
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        try? await Task.sleep(nanoseconds: 550_000_000)
        lines.append(.init(kind: .prompt, text: "> select host:", host: nil))
    }

    func pick(_ host: Host) async {
        guard pickedHost == nil else { return }
        pickedHost = host

        lines.append(.init(kind: .cmd, text: "$ pair \(host.id)", host: nil))
        lines.append(.init(kind: .info, text: "· requesting code on host", host: nil))

        try? await Task.sleep(nanoseconds: 600_000_000)
        lines.append(.init(kind: .code, text: "  CODE: 472913 (expires 60s)", host: nil))

        try? await Task.sleep(nanoseconds: 500_000_000)
        lines.append(.init(kind: .info, text: "· waiting for confirmation on host…", host: nil))

        for i in 1...100 {
            try? await Task.sleep(nanoseconds: 22_000_000)
            pairingProgress = Double(i) / 100.0
        }

        lines.append(.init(kind: .ok, text: "✓ trusted device added", host: nil))
        lines.append(.init(kind: .ok, text: "✓ session up · \(host.signal.rawValue)", host: nil))
        lines.append(.init(kind: .cmd, text: "$ ready", host: nil))
        pairingDone = true
    }
}
