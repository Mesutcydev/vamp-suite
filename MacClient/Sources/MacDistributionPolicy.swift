import Discovery
import Foundation

/// App Store edition policy. Guideline 4.2.7(a) limits focused app-window
/// streaming to a local LAN, so the store build refuses Tailscale destinations
/// for app windows only. The generic desktop view is not restricted.
enum MacDistributionPolicy {
    static let isAppStoreEdition: Bool = {
        #if VAMP_APP_STORE
        return true
        #else
        return false
        #endif
    }()

    /// Input, unlock, terminal, file transfer, clipboard push, and host app close
    /// exist only in the website edition. The store edition is View Only.
    static var allowsRemoteChanges: Bool { !isAppStoreEdition }

    static func allowsAppWindowStreaming(to endpoint: ResolvedHostEndpoint?) -> Bool {
        guard isAppStoreEdition else { return true }
        guard let host = endpoint?.hostname else { return false }
        return !isTailnetDestination(host)
    }

    // ponytail: checks the typed name and literal address only. A LAN-looking name
    // that resolves into the tailnet slips through; upgrade path is checking the resolved address.
    static func isTailnetDestination(_ host: String) -> Bool {
        let name = host.lowercased()
        if name.hasSuffix(".ts.net") || name.hasPrefix("fd7a:115c:a1e0") { return true }
        let octets = name.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }
}
