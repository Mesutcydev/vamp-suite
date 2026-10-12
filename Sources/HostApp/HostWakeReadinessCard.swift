import SwiftUI
import AppKit

@MainActor
final class HostWakeReadinessViewModel: ObservableObject {
    @Published private(set) var readiness: HostWakeReadiness = .unknown
    @Published private(set) var isBusy = false
    @Published private(set) var lastActionMessage: String?

    /// Only non-sandboxed builds can read or change `pmset`; sandboxed builds guide manually.
    var canManage: Bool { !HostWakeReadinessDetector.isSandboxed }

    func refresh() async {
        readiness = await Task.detached(priority: .utility) {
            HostWakeReadinessDetector.detect()
        }.value
    }

    func enable() async {
        guard canManage else { return }
        isBusy = true
        lastActionMessage = nil
        let ok = await Task.detached(priority: .userInitiated) {
            HostWakeReadinessDetector.enableWakeOnNetwork()
        }.value
        await refresh()
        isBusy = false
        lastActionMessage = ok
            ? (readiness.isWakeable ? "Wake for network access is now on." : "Ran, but the setting didn’t change.")
            : "Authorization was cancelled or the change failed."
    }
}

/// Host settings card surfacing whether this Mac will wake for network access (the prerequisite for
/// the iOS client's Wake-on-LAN), with a one-tap enable on non-sandboxed builds and guidance always.
struct HostWakeReadinessCard: View {
    @StateObject private var model = HostWakeReadinessViewModel()

    var body: some View {
        HostSurfaceCard(
            title: "Wake on LAN",
            subtitle: "Let a paired client Mac wake this Mac from sleep.",
            systemImage: "powersleep",
            accent: accentColor
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HostInfoRow(label: "Wake for network", value: statusText(model.readiness.wakeOnNetwork))
                HostInfoRow(label: "Keep TCP alive", value: statusText(model.readiness.tcpKeepAlive))

                Text(guidanceText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if model.canManage && !model.readiness.isWakeable {
                        HostActionButton("Enable Wake", systemImage: "bolt.fill", role: .primary) {
                            Task { await model.enable() }
                        }
                        .disabled(model.isBusy)
                    }
                    HostActionButton("Open System Settings", systemImage: "gearshape", role: .secondary) {
                        openEnergySettings()
                    }
                    if model.canManage {
                        HostActionButton("Recheck", systemImage: "arrow.clockwise", role: .secondary) {
                            Task { await model.refresh() }
                        }
                        .disabled(model.isBusy)
                    }
                }
                .padding(.top, 2)

                if let message = model.lastActionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(model.readiness.isWakeable ? AppColor.success : AppColor.warning)
                }
            }
        }
        .task { await model.refresh() }
    }

    private var accentColor: Color {
        switch model.readiness.wakeOnNetwork {
        case .enabled: return AppColor.success
        case .disabled: return AppColor.warning
        case .unknown: return AppColor.primaryAccent
        }
    }

    private func statusText(_ state: HostWakeReadiness.State) -> String {
        switch state {
        case .enabled: return "On"
        case .disabled: return "Off"
        case .unknown: return "Unknown"
        }
    }

    private var guidanceText: String {
        let sleepProxyNote = "Apple-Silicon Macs on Wi-Fi also need a Sleep Proxy on the network (an Apple TV, HomePod, or an always-on Mac)."
        if model.readiness.isWakeable {
            return "This Mac is set to wake for network access. \(sleepProxyNote)"
        }
        if HostWakeReadinessDetector.isSandboxed {
            return "Turn on System Settings → Battery (or Energy Saver) → Options → “Wake for network access”. \(sleepProxyNote)"
        }
        return "“Wake for network access” is off, so a paired client Mac can’t wake this Mac from sleep. Turn it on below. \(sleepProxyNote)"
    }

    private func openEnergySettings() {
        // Best-effort deep link to the Battery / Energy pane; falls back across macOS versions.
        let candidates = [
            "x-apple.systempreferences:com.apple.Battery-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.battery",
            "x-apple.systempreferences:com.apple.preference.energysaver"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}
