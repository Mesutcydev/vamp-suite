import Foundation

/// Store branding differs from the website names while app identities and
/// transport compatibility stay stable across distribution channels.
public enum VampProductIdentity {
    public static var isStoreDistribution: Bool {
        Bundle.main.object(forInfoDictionaryKey: "VampDistributionChannel") as? String == "app-store"
    }
    public static var syncName: String { isStoreDistribution ? "App Sync" : "Vamp Sync" }
    public static var streamName: String { isStoreDistribution ? "App Stream" : "Vamp Stream" }
}

/// Stable product pages work before and after a store listing is published.
/// Store IDs and release artifact URLs belong on those pages, not in clients.
public enum VampProductLinks {
    public static let syncDownload = URL(string: "https://thevamp.app/sync/#download")!
    public static let syncEditions = URL(string: "https://thevamp.app/sync/#editions")!
    public static let stream = URL(string: "https://thevamp.app/stream/")!
    public static let privacy = URL(string: "https://thevamp.app/privacy/")!
    public static let support = URL(string: "https://github.com/Mesutcydev/vamp-suite/issues")!
}
