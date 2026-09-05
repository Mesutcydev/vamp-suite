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


/// Window layout is independent of capture resolution. Preserve useful content width even
/// when a portrait phone cannot accommodate a desktop app at its exact aspect ratio.
public enum AdaptiveWindowSizing {
    public static func size(original: DesktopSize, available: DesktopSize,
                            viewport: DesktopSize, bundleIdentifier: String) -> DesktopSize {
        guard original.width.isFinite, original.height.isFinite,
              available.width.isFinite, available.height.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              original.width > 0, original.height > 0, available.width > 0,
              available.height > 0, viewport.width > 0, viewport.height > 0 else { return original }
        let aspect = min(max(viewport.width / viewport.height, 0.25), 4)
        let maxHeight = min(available.height, 1400)
        let flexible = bundleIdentifier.lowercased() == "com.apple.safari"
        let minimumWidth = min(available.width, flexible ? min(original.width, 600) : original.width)
        let height = min(maxHeight, available.width / aspect)
        let width = min(available.width, max(minimumWidth, height * aspect))
        return DesktopSize(width: floor(width), height: floor(height))
    }
}
