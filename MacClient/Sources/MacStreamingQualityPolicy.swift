import Foundation
import SharedModels

/// Resolution-first defaults for Vamp Control.
///
/// The shared client settings default to `.balanced`, which is sized for a
/// phone. A Mac has the decode headroom for far more, and the factory only ever
/// raised the preset on a *fresh* install — so every Mac that had already
/// launched the app stayed pinned at Balanced no matter how capable it was.
/// Promote those installs once, exactly like Vamp Stream does on iOS. Anything
/// the user has deliberately chosen at or above the recommendation is left
/// alone, and host-side thermal and network adaptation stays authoritative at
/// runtime.
enum MacStreamingQualityPolicy {
    static let promotionKey = "vampcontrol.quality.macDefault.v1"

    /// The preset to use, given what is stored today. Never lowers a preset.
    static func preferredPreset(
        current: StreamQualityPreset,
        supportsUltra: Bool
    ) -> StreamQualityPreset {
        let recommended: StreamQualityPreset = supportsUltra ? .quality : .balanced
        return rank(current) >= rank(recommended) ? current : recommended
    }

    /// Runs the promotion at most once per install. Returns the preset to apply,
    /// or `nil` when this install has already been promoted and the stored
    /// preference should stand untouched.
    static func promotedPreset(
        current: StreamQualityPreset,
        supportsUltra: Bool,
        defaults: UserDefaults = .standard
    ) -> StreamQualityPreset? {
        guard !defaults.bool(forKey: promotionKey) else { return nil }
        defaults.set(true, forKey: promotionKey)
        let preferred = preferredPreset(current: current, supportsUltra: supportsUltra)
        return preferred == current ? nil : preferred
    }

    private static func rank(_ preset: StreamQualityPreset) -> Int {
        switch preset {
        case .performance: return 0
        case .balanced: return 1
        case .quality: return 2
        case .ultra: return 3
        }
    }
}
