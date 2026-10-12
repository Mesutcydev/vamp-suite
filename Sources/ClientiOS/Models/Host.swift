import Foundation
import Discovery

struct Host: Identifiable, Hashable {
    let id: String
    let displayName: String
    let ip: String
    let model: String
    let signal: Signal
    let fingerprint: String
    let endpoint: ResolvedHostEndpoint

    enum Signal: String, Hashable {
        case lan = "LAN"
        case wan = "WAN"
        case relay = "RELAY"
    }

    static func from(_ row: DiscoveredHostRow) -> Host {
        let hostID = row.endpoint.metadata.hostID.uuidString
        let signal: Signal = row.endpoint.hostname.contains("ts.net") || row.endpoint.hostname.hasPrefix("100.") ? .relay : .lan
        return Host(
            id: hostID,
            displayName: row.endpoint.metadata.displayName,
            ip: row.endpoint.hostname,
            model: row.endpoint.metadata.appVersion,
            signal: signal,
            fingerprint: "SHA256:\(hostID.prefix(8))…\(hostID.suffix(4))",
            endpoint: row.endpoint
        )
    }
}
