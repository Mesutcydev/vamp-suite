import Combine
import Foundation
import Discovery

/// Local, per-Mac names for hosts.
///
/// A host advertises whatever its owner called the machine ("Mesut's Mac mini"),
/// which is not always what *you* want to see in your list. Nicknames live only
/// on this Mac — renaming never touches the remote host or its advertisement.
///
/// Keyed by the host's pinned public key when there is one, so a rename survives
/// the Mac changing address; otherwise by address, which is the best identity a
/// manually-added host has.
@MainActor
final class MacHostNicknameStore: ObservableObject {
    static let shared = MacHostNicknameStore()

    private let defaultsKey = "vampcontrol.hosts.nicknames"
    private let defaults: UserDefaults
    @Published private var nicknames: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        nicknames = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    nonisolated static func key(for endpoint: ResolvedHostEndpoint) -> String {
        if let fingerprint = endpoint.metadata.publicKeyFingerprint,
           !fingerprint.isEmpty {
            return "fp:" + fingerprint.lowercased()
        }
        return "addr:\(endpoint.hostname.lowercased()):\(endpoint.port)"
    }

    func nickname(for endpoint: ResolvedHostEndpoint) -> String? {
        nicknames[Self.key(for: endpoint)]
    }

    /// The name to show for this host: the nickname if one is set, else the name
    /// the host advertises.
    func displayName(for endpoint: ResolvedHostEndpoint) -> String {
        nickname(for: endpoint) ?? endpoint.metadata.displayName
    }

    /// Empty or whitespace-only clears the nickname and restores the advertised
    /// name — that is the "Reset" path, so it must not store a blank.
    func setNickname(_ name: String?, for endpoint: ResolvedHostEndpoint) {
        let key = Self.key(for: endpoint)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == endpoint.metadata.displayName {
            nicknames.removeValue(forKey: key)
        } else {
            nicknames[key] = trimmed
        }
        defaults.set(nicknames, forKey: defaultsKey)
    }
}
