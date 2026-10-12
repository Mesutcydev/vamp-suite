import Foundation
import SharedModels

/// Resolution-first defaults for the focused Vamp Stream client.
///
/// Vamp Stream has no general-purpose quality settings screen. Its historical
/// shared-client default therefore left existing installs at Balanced, while the
/// Assistant HTTP path was separately pinned to 1080p. Promote both paths once;
/// host-side thermal and network adaptation remain authoritative at runtime.
enum VampStreamStreamingQualityPolicy {
    static let assistantResolutionKey = "vampstream.assistant.resolution"
    static let assistantNativeMigrationKey = "vampstream.assistant.nativeResolution.v1"

    static func preferredPreset(
        current: StreamQualityPreset,
        supportsUltra: Bool
    ) -> StreamQualityPreset {
        let recommended: StreamQualityPreset = supportsUltra ? .ultra : .quality
        return rank(current) >= rank(recommended) ? current : recommended
    }

    static func migrateAssistantResolution(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: assistantNativeMigrationKey) else { return }

        let stored = defaults.string(forKey: assistantResolutionKey)
        if stored == nil || stored == "1080p" {
            defaults.set("native", forKey: assistantResolutionKey)
        }
        defaults.set(true, forKey: assistantNativeMigrationKey)
    }

    private static func rank(_ preset: StreamQualityPreset) -> Int {
        switch preset {
        case .performance: 0
        case .balanced: 1
        case .quality: 2
        case .ultra: 3
        }
    }
}
