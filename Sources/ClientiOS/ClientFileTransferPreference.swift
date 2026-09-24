import Foundation

/// Shared preference for enabling file transfers in Vamp Control clients.
///
/// Keep the settings UI and transfer manager on one key so disabling transfers
/// also rejects incoming offers instead of only hiding the send control.
enum ClientFileTransferPreference {
    static let storageKey = "com.mesutcy.remotedesktop.client.filetransfer.enabled"
    static let legacyMacStorageKey = "com.remotedesktop.client.filetransfer.enabled"
    private static let legacyManagerStorageKey = "com.mesutcy.remotedesktop.terminal.filetransfer.enabled"

    /// Preserve opt-outs written by older client builds before the UI and
    /// transfer manager shared one preference key.
    static func migrateLegacySettings(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: storageKey) == nil else { return }
        let previousValue = defaults.object(forKey: legacyMacStorageKey) as? Bool
            ?? defaults.object(forKey: legacyManagerStorageKey) as? Bool
        if let previousValue {
            defaults.set(previousValue, forKey: storageKey)
        }
    }

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        migrateLegacySettings(in: defaults)
        return defaults.object(forKey: storageKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: storageKey)
    }
}
