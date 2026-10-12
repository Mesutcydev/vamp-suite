import Foundation
import SharedUtilities
import SwiftUI

struct MacConnectionPreferences: Codable, Equatable {
    var displayModeRaw = DisplayMappingEngine.DisplayMode.fitDisplay.rawValue
    var keepsDisplayShortcutsLocal = true
    var quickActionID = "none"
}

/// Local preferences only. Never stores tokens, credentials or remote content.
struct MacConnectionPreferenceStore {
    var defaults: UserDefaults = .standard
    private let prefix = "vampcontrol.connection.preferences."

    func load(for key: String) -> MacConnectionPreferences {
        if let data = defaults.data(forKey: prefix + key),
           var value = try? JSONDecoder().decode(MacConnectionPreferences.self, from: data) {
            if DisplayMappingEngine.DisplayMode(rawValue: value.displayModeRaw) == nil {
                value.displayModeRaw = DisplayMappingEngine.DisplayMode.fitDisplay.rawValue
            }
            return value
        }
        var value = MacConnectionPreferences()
        // Seed existing installations once from their previous global preference.
        if let raw = defaults.string(forKey: "client.displayMode"),
           DisplayMappingEngine.DisplayMode(rawValue: raw) != nil {
            value.displayModeRaw = raw
        }
        return value
    }

    func save(_ value: MacConnectionPreferences, for key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: prefix + key)
    }

    static func assistantKey(address: String) -> String {
        guard let url = URLComponents(string: address), let host = url.host else {
            return "assistant:" + address.lowercased()
        }
        return "assistant:\(url.scheme?.lowercased() ?? "http")://\(host.lowercased()):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }
}

private struct RemoteDisplayModeFocusKey: FocusedValueKey {
    typealias Value = Binding<String>
}
private struct RemoteDisplayShortcutsFocusKey: FocusedValueKey {
    typealias Value = Bool
}
extension FocusedValues {
    var remoteDisplayMode: Binding<String>? {
        get { self[RemoteDisplayModeFocusKey.self] }
        set { self[RemoteDisplayModeFocusKey.self] = newValue }
    }
    var keepsDisplayShortcutsLocal: Bool? {
        get { self[RemoteDisplayShortcutsFocusKey.self] }
        set { self[RemoteDisplayShortcutsFocusKey.self] = newValue }
    }
}
