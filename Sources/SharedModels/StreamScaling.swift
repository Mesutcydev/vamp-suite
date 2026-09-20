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
    /// Floor for `performance` on *window* streams. A window's pixel size is its
    /// point size × the display backing scale — already small compared with a full
    /// display — so the standard half-resolution rule quartered an already-small
    /// stream (an 836×1812 window encoded at 418×906 and then upscaled ~3× on a
    /// phone). Performance keeps its bandwidth saving, but never falls below this
    /// long edge, and never scales past the window's own backing pixels.
    public static let windowPerformanceMinLongEdge = 1080

    /// Hard ceiling for a *window* stream, in pixels: one 4K UHD frame (3840×2160,
    /// 8.29 MP) and a 3840-pixel long edge.
    ///
    /// This is the envelope both ends of the supported pair can actually exchange:
    /// an iPhone 17 Pro Max (A19 Pro) hardware-decodes H.264 up to level 5.2
    /// (4096×2304) and HEVC well past 4K, while the M4 media engine encodes
    /// H.264/HEVC up to 4K60. `ultra` is otherwise unbounded — it passes the
    /// source's native pixels straight through — so on a 5K/6K display, or on a
    /// window grown past the phone's screen, it can build a frame the client cannot
    /// decode and the stream fails to a black picture. The ceiling only ever shrinks
    /// a result, never upscales, and display streams (which pass `minLongEdge == 0`)
    /// are untouched: there the display *is* the intended resolution.
    public static let windowMaximumLongEdge = 3840
    public static let windowMaximumPixels = 3_840 * 2_160

    /// Encode/capture dimensions for a preset given the native display size.
    ///
    /// - Parameter allowsHighResolution: when `true` (HEVC negotiated and supported by
    ///   both ends), `balanced`/`quality` cap at 4K width instead of 1080p, since HEVC
    ///   is hardware-decoded at 4K on all supported clients. `false` keeps the 1920px
    ///   cap H.264 hardware decoders require. `performance` and `ultra` are unaffected.
    /// - Parameter minLongEdge: optional floor on the longest encoded edge. Applied
    ///   after the preset rule and clamped to the native long edge, so it raises
    ///   low presets toward legibility without ever upscaling past the source.
    ///   Capture and encode call sites MUST pass the same value or VideoToolbox
    ///   rescales the mismatch. Zero disables the floor. A non-zero value also marks
    ///   the stream as a *window* stream, which is what opts it into the
    ///   `windowMaximumLongEdge` / `windowMaximumPixels` decoder ceiling.
    public static func scaledDimensions(
        preset: StreamQualityPreset,
        nativeWidth: Int,
        nativeHeight: Int,
        allowsHighResolution: Bool,
        minLongEdge: Int = 0
    ) -> (width: Int, height: Int) {
        let base: (width: Int, height: Int)
        switch preset {
        case .performance:
            // Half-resolution, but never above the codec's reliable hardware-decode
            // width. On a large display (e.g. 6K Pro Display XDR) half-res is still
            // ~3008px wide — above the 1920px H.264 limit — which causes the client
            // to fall back to software decode or fail outright on the *lightest*
            // preset. Clamp to the same caps balanced/quality use.
            let halfWidth = nativeWidth / 2
            let cap = allowsHighResolution ? highResolutionMaxWidth : standardMaxWidth
            if halfWidth > cap {
                let scale = Double(cap) / Double(nativeWidth)
                let height = Int((Double(nativeHeight) * scale).rounded() / 2) * 2
                base = (cap, height)
            } else {
                // Both axes must be even for H.264/HEVC 4:2:0 luma. The previous return
                // passed `halfWidth` (exact /2, possibly odd) for width while rounding
                // height to /4*2 — different scale factors and an odd width could slip
                // through. Round both to the same even half-scale so dimensions stay
                // valid and proportional.
                base = ((nativeWidth / 2 / 2) * 2, (nativeHeight / 2 / 2) * 2)
            }
        case .balanced, .quality:
            let maxWidth = allowsHighResolution ? highResolutionMaxWidth : standardMaxWidth
            if nativeWidth > maxWidth {
                let scale = Double(maxWidth) / Double(nativeWidth)
                let height = Int((Double(nativeHeight) * scale).rounded() / 2) * 2
                base = (maxWidth, height)
            } else {
                base = (nativeWidth, nativeHeight)
            }
        case .ultra:
            base = (nativeWidth, nativeHeight)
        }
        return decoderCeiling(
            floorDimensions(
                base, preset: preset, nativeWidth: nativeWidth,
                nativeHeight: nativeHeight, minLongEdge: minLongEdge),
            minLongEdge: minLongEdge)
    }

    /// Shrinks a *window* stream (the only caller that passes a non-zero `minLongEdge`) into
    /// the hardware envelope of `windowMaximumLongEdge` / `windowMaximumPixels`. Preserves
    /// aspect, keeps both axes even, and never upscales. Display streams are returned as-is.
    private static func decoderCeiling(
        _ dims: (width: Int, height: Int),
        minLongEdge: Int
    ) -> (width: Int, height: Int) {
        guard minLongEdge > 0, dims.width > 0, dims.height > 0 else { return dims }
        let longEdge = max(dims.width, dims.height)
        let pixels = dims.width * dims.height
        let edgeScale = Double(windowMaximumLongEdge) / Double(longEdge)
        let pixelScale = (Double(windowMaximumPixels) / Double(pixels)).squareRoot()
        let scale = min(1, edgeScale, pixelScale)
        guard scale < 1 else { return dims }
        let width = max((Int((Double(dims.width) * scale).rounded()) / 2) * 2, 2)
        let height = max((Int((Double(dims.height) * scale).rounded()) / 2) * 2, 2)
        return (width, height)
    }

    /// Raises a preset's dimensions so the longest edge reaches `minLongEdge`, keeping
    /// aspect and even axes, without ever exceeding the native (backing) size. Only
    /// meaningful where "small" means illegible rather than efficient — the window
    /// path, whose native pixels are a fraction of a display stream's.
    private static func floorDimensions(
        _ dims: (width: Int, height: Int),
        preset: StreamQualityPreset,
        nativeWidth: Int,
        nativeHeight: Int,
        minLongEdge: Int
    ) -> (width: Int, height: Int) {
        guard minLongEdge > 0 else { return dims }
        let longEdge = max(dims.width, dims.height)
        let nativeLongEdge = max(nativeWidth, nativeHeight)
        // The floor can only lift a downscaled result, and never past the source's
        // own pixels: upscaling beyond the backing store spends encode bandwidth on
        // zero extra information.
        let target = min(max(minLongEdge, 2), nativeLongEdge)
        guard preset != .ultra, longEdge > 0, longEdge < target, nativeLongEdge > 0 else {
            return dims
        }
        let scale = Double(target) / Double(longEdge)
        let width = max((Int((Double(dims.width) * scale).rounded()) / 2) * 2, 2)
        let height = max((Int((Double(dims.height) * scale).rounded()) / 2) * 2, 2)
        return (width, height)
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
    /// Longest edge in points. The target phone is an iPhone 17 Pro Max at 1320×2868 px, so a
    /// 2x Mac needs 1434 points to hand it native pixels; 1440 points is 2880 px, just over that,
    /// while still staying inside the decoder envelope. Without the cap a 5K/6K display would
    /// produce a capture taller than the client's hardware decoder accepts.
    public static let maxEdgePoints: Double = 1440

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
