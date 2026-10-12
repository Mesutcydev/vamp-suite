import Foundation

/// Favourites and recents for the app browsers, keyed by bundle identifier.
///
/// Both browsers — the Vamp Sync one (`AppStreamBrowserView`) and the Vamp Assistant one
/// (`VampAssistantApplicationBrowser`) — read and write the same two lists. `RemoteApplication.id`
/// and `BeetCodeRemoteApplication.id` are both the bundle identifier, so "Safari is a favourite"
/// means the same thing on either kind of Mac and the list follows the user between them.
///
/// The lists are stored as JSON arrays of ids in `UserDefaults`, which is the format the Sync
/// browser already wrote; existing favourites survive.
enum AppStreamAppShortlists {
    static let favoritesKey = "vampstream.favoriteApps"
    static let recentsKey = "vampstream.recentApps"

    /// How many recents to keep. Beyond this the list stops being "recent" and starts being
    /// a second, worse copy of All Apps.
    static let recentLimit = 10

    static func decode(_ value: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? []
    }

    static func encode(_ ids: [String]) -> String {
        (try? String(decoding: JSONEncoder().encode(ids), as: UTF8.self)) ?? "[]"
    }

    /// Add or remove `id`, preserving the order of everything else.
    static func toggled(_ id: String, in encoded: String) -> String {
        let ids = decode(encoded)
        return encode(ids.contains(id) ? ids.filter { $0 != id } : ids + [id])
    }

    /// Move `id` to the front and trim to `recentLimit`.
    static func promoting(_ id: String, in encoded: String) -> String {
        encode(Array(([id] + decode(encoded).filter { $0 != id }).prefix(recentLimit)))
    }
}
