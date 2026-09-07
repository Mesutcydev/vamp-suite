import Foundation

/// Shared capture/encode dimension scaling — the single source of truth.
///
/// Capture (`CaptureConfiguration`) and encode (`EncoderConfiguration`) MUST produce
/// identical frame dimensions; otherwise VideoToolbox rescales mismatched input,
/// wasting bandwidth and blurring the image. Both delegate here so the rules can
/// never drift apart.
public enum StreamScaling {
    /// 4K width cap used for `balanced`/`quality` when high resolution is allowed.
    public static let highResolutionMaxWidth = 3840
    /// 1080p width cap used for `balanced`/`quality` otherwise — the limit H.264
    /// hardware decoders on the client can reliably handle.
    public static let standardMaxWidth = 1920

    /// Encode/capture dimensions for a preset given the native display size.
    ///
    /// - Parameter allowsHighResolution: when `true` (HEVC negotiated and supported by
    ///   both ends), `balanced`/`quality` cap at 4K width instead of 1080p, since HEVC
    ///   is hardware-decoded at 4K on all supported clients. `false` keeps the 1920px
    ///   cap H.264 hardware decoders require. `performance` and `ultra` are unaffected.
    public static func scaledDimensions(
        preset: StreamQualityPreset,
        nativeWidth: Int,
        nativeHeight: Int,
        allowsHighResolution: Bool
    ) -> (width: Int, height: Int) {
        switch preset {
        case .performance:
            // Half-resolution, but never above the codec's reliable hardware-decode
            // width. On a large display (e.g. 6K Pro Display XDR) half-res is still
            // ~3008px wide — above the 1920px H.264 limit — which causes the client
            // to fall back to software decode or fail outright on the *lightest*
            // preset. Clamp to the same caps balanced/quality use.
            let halfWidth = nativeWidth / 2
            let cap = allowsHighResolution ? highResolutionMaxWidth : standardMaxWidth
            guard halfWidth > cap else {
                // Both axes must be even for H.264/HEVC 4:2:0 luma. The previous return
                // passed `halfWidth` (exact /2, possibly odd) for width while rounding
                // height to /4*2 — different scale factors and an odd width could slip
                // through. Round both to the same even half-scale so dimensions stay
                // valid and proportional.
                return ((nativeWidth / 2 / 2) * 2, (nativeHeight / 2 / 2) * 2)
            }
            let scale = Double(cap) / Double(nativeWidth)
            let height = Int((Double(nativeHeight) * scale).rounded() / 2) * 2
            return (cap, height)
        case .balanced, .quality:
            let maxWidth = allowsHighResolution ? highResolutionMaxWidth : standardMaxWidth
            guard nativeWidth > maxWidth else {
                return (nativeWidth, nativeHeight)
            }
            let scale = Double(maxWidth) / Double(nativeWidth)
            let height = Int((Double(nativeHeight) * scale).rounded() / 2) * 2
            return (maxWidth, height)
        case .ultra:
            return (nativeWidth, nativeHeight)
        }
    }
}


/// Window layout is independent of capture resolution. The streamed window is reshaped to the
/// client viewport's exact aspect ratio, then scaled to fill the host display, so the phone shows
/// edge-to-edge video with no letterbox bars.
///
/// This is the one contract that keeps Vamp Stream's picture correct: any width floor above
/// `height * aspect` makes the window wider than the viewport, and an aspect-fit renderer then
/// shrinks it into a horizontal strip with black bars above and below.
public enum AdaptiveWindowSizing {
    /// Longest edge in points. A phone screen is at most ~1320x2868 px, so 1400 points already
    /// covers it on a 2x Mac; without the cap a 5K/6K display would produce a capture taller
    /// than the client's hardware decoder accepts.
    public static let maxEdgePoints: Double = 1400

    /// - Parameter bundleIdentifier: retained for source compatibility with the host and client
    ///   call sites. Sizing is deliberately app-agnostic — matching the viewport aspect is what
    ///   fills the phone, and per-app width exceptions reintroduce the letterbox bars.
    public static func size(original: DesktopSize, available: DesktopSize,
                            viewport: DesktopSize, bundleIdentifier: String) -> DesktopSize {
        guard original.width.isFinite, original.height.isFinite,
              available.width.isFinite, available.height.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              original.width > 0, original.height > 0, available.width > 0,
              available.height > 0, viewport.width > 0, viewport.height > 0 else { return original }
        let aspect = min(max(viewport.width / viewport.height, 0.25), 4)
        // Clamp first so the aspect match starts from a shape the display can actually hold.
        let currentWidth = min(max(original.width, 1), available.width)
        let currentHeight = min(max(original.height, 1), available.height)
        let currentAspect = currentWidth / currentHeight
        // Match the viewport aspect exactly: shrink the long axis toward the requested shape.
        let matchedWidth = aspect < currentAspect ? currentHeight * aspect : currentWidth
        let matchedHeight = aspect < currentAspect ? currentHeight : currentWidth / aspect
        // Then scale that shape *into* the display instead of leaving it small. Shrink-only
        // turned a small source window — Terminal's default is about 528x374 — into roughly
        // 172x374, which the phone then upscaled nearly 3x: giant text and ~31 columns.
        let fitScale = min(
            min(available.width / matchedWidth, available.height / matchedHeight),
            maxEdgePoints / max(matchedWidth, matchedHeight))
        return DesktopSize(
            width: max(1, floor(matchedWidth * fitScale)),
            height: max(1, floor(matchedHeight * fitScale)))
    }
}
