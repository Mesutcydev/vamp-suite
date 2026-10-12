#if os(iOS)
import AppIntents
import Foundation

/// "Wake my Mac" from Siri or the Shortcuts app — sends a Wake-on-LAN magic packet to a saved
/// host so it's awake by the time you open Vamp Control. Self-contained: it reads the saved hosts and
/// fires the packet without launching the app.
struct WakeMacIntent: AppIntent {
    // Apple rejects App Intent metadata containing reserved platform terms ("Mac") with
    // ITMS-90626, so all the static Siri-facing strings say "computer" instead.
    static var title: LocalizedStringResource = "Wake my computer"
    static var description = IntentDescription("Send a Wake-on-LAN signal to a saved computer.")
    static var openAppWhenRun = false

    @Parameter(title: "Computer name (optional)")
    var hostName: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let hosts = Self.savedHosts().filter { ($0.macAddress?.isEmpty == false) }
        guard !hosts.isEmpty else {
            return .result(dialog: "No saved computers with Wake-on-LAN set up yet.")
        }

        let targets: [SavedHost]
        if let name = hostName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let matches = hosts.filter { $0.displayName.localizedCaseInsensitiveContains(name) }
            targets = matches.isEmpty ? Array(hosts.prefix(1)) : matches
        } else {
            targets = hosts
        }

        let wol = WakeOnLANService()
        var woke: [String] = []
        for host in targets {
            guard let mac = host.macAddress else { continue }
            let reachAt = host.tailscaleHostname ?? host.tailscaleIP ?? host.hostname
            try? await wol.wake(macAddress: mac, targetHost: reachAt)
            woke.append(host.displayName)
        }

        guard !woke.isEmpty else {
            return .result(dialog: "Couldn’t wake any computers.")
        }

        return .result(dialog: "Sent a wake signal to \(woke.joined(separator: ", ")).")
    }

    private static func savedHosts() -> [SavedHost] {
        guard let data = UserDefaults.standard.data(forKey: "com.remotedesktop.savedHosts"),
              let hosts = try? JSONDecoder().decode([SavedHost].self, from: data) else { return [] }
        return hosts
    }
}

/// Exposes the app's intents to Siri / Spotlight / Shortcuts with spoken phrases.
struct VampAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WakeMacIntent(),
            phrases: [
                "Wake my computer with \(.applicationName)",
                "Wake my computer in \(.applicationName)",
                "\(.applicationName) wake my computer"
            ],
            shortTitle: "Wake my computer",
            systemImageName: "power"
        )
    }
}
#endif
