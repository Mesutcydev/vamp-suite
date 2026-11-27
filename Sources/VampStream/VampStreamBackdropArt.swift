import SwiftUI

/// Stream's look, chosen in Settings. Dark is the default because it is what every existing
/// install has always shown; the video surface stays dark in every mode, like any player.
enum VampStreamAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "vampstream.appearance"
    /// Whether the background artwork sits behind the UI. Off gives a plain system background.
    static let backgroundArtKey = "vampstream.showsBackgroundArt"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// One continuous canvas across home, pairing, settings and both app libraries.
struct VampStreamEnvironmentBackdrop: View {
    @AppStorage(VampStreamAppearance.backgroundArtKey) private var showsArt = true

    var body: some View {
        StreamAtmosphere(decorative: showsArt)
    }

}

/// Stream's artwork surfaces share readable foreground states in both schemes.
enum StreamReading {
    static let primary = StreamDesign.text
    static let secondary = StreamDesign.secondary
    static let disabled = StreamDesign.secondary
    /// The plate under every glass surface while the artwork is on (`prGlassBacking`), so labels
    /// never sit on the artwork's bright curves.
    static let surface = StreamDesign.readingPlate
}
