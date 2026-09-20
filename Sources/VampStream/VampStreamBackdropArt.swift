import SwiftUI

/// Full corridor artwork, rendered from the high-resolution master without stretching.
struct VampStreamEnvironmentBackdrop: View {
    @Environment(\.colorSchemeContrast) private var readingContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { proxy in
            VampStreamArtwork(size: proxy.size)
                .overlay(Color.black.opacity(readingContrast == .increased || reduceTransparency ? 0.35 : 0))
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.82), location: 0),
                            .init(color: .black.opacity(0.72), location: 0.35),
                            .init(color: .black.opacity(0.72), location: 0.70),
                            .init(color: .black.opacity(0.82), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct VampStreamArtwork: View {
    let size: CGSize

    var body: some View {
        Image("VampStreamBackdrop")
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: max(size.width, 1), height: max(size.height, 1))
            .clipped()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// Stream's dark artwork surfaces share readable foreground states.
enum StreamReading {
    static let primary = Color.primary
    static let secondary = Color.primary.opacity(0.82)
    static let disabled = Color.primary.opacity(0.60)
    static let surface = Color.black.opacity(0.90)
}
