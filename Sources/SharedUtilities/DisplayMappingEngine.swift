import Foundation
import SharedModels

public struct DesktopEdgeInsets: Codable, Hashable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static let zero = DesktopEdgeInsets()
}

/// Pure stream-to-display mapping used by the client to keep the rendered video,
/// letterbox math, and host input coordinates aligned.
public struct DisplayMappingEngine: Sendable, Hashable {
    private enum RotationTransform: Sendable, Hashable {
        case none
        case quarterTurnClockwise
        case quarterTurnCounterclockwise
        case halfTurn
    }

    public enum DisplayMode: String, Codable, CaseIterable, Sendable, Hashable {
        case fitDisplay
        case fillScreen
        case actualSize

        public var title: String {
            switch self {
            case .fitDisplay: return "Fit Display"
            case .fillScreen: return "Fill Screen"
            case .actualSize: return "Actual Size"
            }
        }
    }

    public var display: DisplayDescriptor
    public var streamConfiguration: DisplayStreamConfiguration?
    public var viewSize: DesktopSize
    public var viewInsets: DesktopEdgeInsets
    public var viewPixelScale: Double
    public var displayMode: DisplayMode

    public init(
        display: DisplayDescriptor,
        streamConfiguration: DisplayStreamConfiguration? = nil,
        viewSize: DesktopSize,
        viewInsets: DesktopEdgeInsets = .zero,
        viewPixelScale: Double = 1,
        displayMode: DisplayMode = .fitDisplay
    ) {
        self.display = display
        self.streamConfiguration = streamConfiguration
        self.viewSize = viewSize
        self.viewInsets = viewInsets
        self.viewPixelScale = max(viewPixelScale, 1)
        self.displayMode = displayMode
    }

    public var availableRect: DesktopRect {
        let width = max(0, viewSize.width - viewInsets.leading - viewInsets.trailing)
        let height = max(0, viewSize.height - viewInsets.top - viewInsets.bottom)
        return DesktopRect(
            origin: DesktopPoint(x: viewInsets.leading, y: viewInsets.top),
            size: DesktopSize(width: width, height: height)
        )
    }

    public var sourceDisplayLogicalSize: DesktopSize {
        streamConfiguration?.sourceDisplayLogicalSize ?? display.frame.size
    }

    public var streamSize: DesktopSize {
        let configSize = streamConfiguration?.streamSize ?? .zero
        if configSize.width > 0, configSize.height > 0 {
            return configSize
        }
        let pixelSize = display.pixelSize
        if pixelSize.width > 0, pixelSize.height > 0 {
            return pixelSize
        }
        return display.frame.size
    }

    public var captureRect: DesktopRect {
        streamConfiguration?.captureRect ?? DisplayStreamConfiguration.fullDisplayCaptureRect(for: display)
    }

    private var displayRotationDegrees: Double {
        streamConfiguration?.rotation ?? display.rotation
    }

    private var normalizedRotationDegrees: Int {
        let normalized = Int(displayRotationDegrees.rounded()) % 360
        return normalized >= 0 ? normalized : normalized + 360
    }

    private var quarterTurnRotationNeedsTransform: Bool {
        let capture = captureRect.size
        let stream = streamSize
        guard capture.width > 0, capture.height > 0, stream.width > 0, stream.height > 0 else {
            return false
        }
        let streamAspect = stream.width / stream.height
        let captureAspect = capture.width / capture.height
        let rotatedAspect = capture.height / capture.width
        return abs(streamAspect - rotatedAspect) + 0.01 < abs(streamAspect - captureAspect)
    }

    private var rotationTransform: RotationTransform {
        switch normalizedRotationDegrees {
        case 90:
            return quarterTurnRotationNeedsTransform ? .quarterTurnClockwise : .none
        case 180:
            return .halfTurn
        case 270:
            return quarterTurnRotationNeedsTransform ? .quarterTurnCounterclockwise : .none
        default:
            return .none
        }
    }

    public var contentRect: DesktopRect {
        let available = availableRect
        let stream = streamSize
        guard available.size.width > 0, available.size.height > 0, stream.width > 0, stream.height > 0 else {
            return available
        }

        let streamAspect = stream.width / stream.height
        let availableAspect = available.size.width / available.size.height

        switch displayMode {
        case .fitDisplay:
            return aspectFitRect(in: available)

        case .fillScreen:
            let width: Double
            let height: Double
            if streamAspect > availableAspect {
                height = available.size.height
                width = height * streamAspect
            } else {
                width = available.size.width
                height = width / streamAspect
            }
            return centeredRect(width: width, height: height, in: available)

        case .actualSize:
            // 1:1 pixel size in view points. When the stream is smaller than the
            // viewport the content is centered at native size; when it is larger,
            // scale down uniformly so the content rect never overflows the view.
            // The render layer must use this exact rect (see RemoteStreamNSView),
            // otherwise the visual video and the input mapping disagree and the
            // remote pointer lands offset from the local one.
            let width = stream.width / viewPixelScale
            let height = stream.height / viewPixelScale
            if width <= available.size.width, height <= available.size.height {
                return centeredRect(width: width, height: height, in: available)
            }
            return aspectFitRect(in: available)
        }
    }

    /// How a streamed picture should be sized inside the surface it is drawn in.
    ///
    /// A Mac app can decline the exact shape it was asked for by a small margin — an app minimum,
    /// or a screen whose visible frame is shorter than its bounds — and even a fixed host can land
    /// a few percent short. Aspect-fitting that residue leaves a black band, usually between the
    /// picture and the control deck.
    ///
    /// When the *height* falls short by a little, this covers instead: the picture is scaled until
    /// its height matches the surface exactly, which overflows and crops the **left and right**
    /// edges slightly. Nothing is lost vertically — the streamed app's own bottom controls (a
    /// composer, a send button) stay exactly where they were, clear of the deck — and the black
    /// band disappears. A shortfall past `maxCropFraction` keeps an honest aspect-fit rather than
    /// zooming into the middle of a window that kept a completely different shape.
    ///
    /// A surface that is *narrower* than the picture is left alone: covering there would crop the
    /// top and bottom, which is where window chrome and composers live.
    public struct StreamPicturePlacement: Equatable, Sendable {
        public let size: DesktopSize
        /// Fraction of the picture hidden by a cover-crop; zero when it fits inside the surface.
        public let croppedFraction: Double

        public init(size: DesktopSize, croppedFraction: Double) {
            self.size = size
            self.croppedFraction = croppedFraction
        }
    }

    /// - Parameter maxCropFraction: the largest shortfall, as a fraction of the surface's height,
    ///   absorbed by covering rather than letterboxing.
    public static func placePicture(
        streamSize: DesktopSize,
        container: DesktopSize,
        maxCropFraction: Double = 0.12
    ) -> StreamPicturePlacement {
        guard streamSize.width > 0, streamSize.height > 0,
              container.width > 0, container.height > 0,
              streamSize.width.isFinite, streamSize.height.isFinite,
              container.width.isFinite, container.height.isFinite else {
            return StreamPicturePlacement(size: container, croppedFraction: 0)
        }
        let streamAspect = streamSize.width / streamSize.height
        let containerAspect = container.width / container.height
        let fit = streamAspect > containerAspect
            ? DesktopSize(width: container.width, height: container.width / streamAspect)
            : DesktopSize(width: container.height * streamAspect, height: container.height)
        let shortfall = max(0, container.height - fit.height) / container.height
        guard shortfall > 0.001, shortfall <= maxCropFraction else {
            return StreamPicturePlacement(size: fit, croppedFraction: 0)
        }
        // Cover the height; the width overflows and is cropped evenly on both sides.
        let covered = DesktopSize(
            width: container.height * streamAspect, height: container.height)
        let cropped = max(0, covered.width - container.width) / covered.width
        return StreamPicturePlacement(size: covered, croppedFraction: cropped)
    }

    /// Aspect-fit `streamSize` inside `container`, returned as a size.
    ///
    /// A caller that draws the picture itself uses this to give the render layer exactly the
    /// fitted rect. The layer's own video gravity centers its content, so a layer larger than the
    /// picture splits the letterbox evenly and shows a black band *above* the picture. Sizing the
    /// layer to this value hands the slack back to the caller, which places it below the picture
    /// where the control deck already floats.
    public static func aspectFitSize(streamSize: DesktopSize, container: DesktopSize) -> DesktopSize {
        guard streamSize.width > 0, streamSize.height > 0,
              container.width > 0, container.height > 0 else { return container }
        let streamAspect = streamSize.width / streamSize.height
        if streamAspect > container.width / container.height {
            return DesktopSize(width: container.width, height: container.width / streamAspect)
        }
        return DesktopSize(width: container.height * streamAspect, height: container.height)
    }

    /// Aspect-fit rect of the stream inside `rect` (fitDisplay / actualSize fallback).
    private func aspectFitRect(in rect: DesktopRect) -> DesktopRect {
        let stream = streamSize
        guard rect.size.width > 0, rect.size.height > 0, stream.width > 0, stream.height > 0 else {
            return rect
        }
        let streamAspect = stream.width / stream.height
        let rectAspect = rect.size.width / rect.size.height
        let width: Double
        let height: Double
        if streamAspect > rectAspect {
            width = rect.size.width
            height = width / streamAspect
        } else {
            height = rect.size.height
            width = height * streamAspect
        }
        return centeredRect(width: width, height: height, in: rect)
    }

    public func viewPointToNormalizedStream(_ viewPoint: DesktopPoint) -> DesktopPoint? {
        let rect = contentRect
        guard rect.size.width > 0, rect.size.height > 0 else { return nil }
        guard viewPoint.x >= rect.minX, viewPoint.x <= rect.maxX,
              viewPoint.y >= rect.minY, viewPoint.y <= rect.maxY else {
            return nil
        }
        let nx = (viewPoint.x - rect.origin.x) / rect.size.width
        let ny = (viewPoint.y - rect.origin.y) / rect.size.height
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return nil }
        return DesktopPoint(x: nx, y: ny)
    }

    public func normalizedStreamToDisplayLogical(_ normalized: DesktopPoint) -> DesktopPoint? {
        let rect = captureRect
        guard rect.size.width > 0, rect.size.height > 0 else { return nil }
        let captureNormalized = streamNormalizedToCaptureNormalized(normalized)
        return DesktopPoint(
            x: rect.origin.x + captureNormalized.x * rect.size.width,
            y: rect.origin.y + captureNormalized.y * rect.size.height
        )
    }

    public func displayLogicalToHostEventCoordinate(_ point: DesktopPoint) -> DesktopPoint {
        point
    }

    public func viewPointToDisplayLogical(_ viewPoint: DesktopPoint) -> DesktopPoint? {
        guard let normalized = viewPointToNormalizedStream(viewPoint),
              let logical = normalizedStreamToDisplayLogical(normalized) else {
            return nil
        }
        return displayLogicalToHostEventCoordinate(logical)
    }

    public func displayLogicalToViewPoint(_ logicalPoint: DesktopPoint) -> DesktopPoint? {
        let rect = captureRect
        guard rect.size.width > 0, rect.size.height > 0 else { return nil }
        let captureNormalized = DesktopPoint(
            x: (logicalPoint.x - rect.origin.x) / rect.size.width,
            y: (logicalPoint.y - rect.origin.y) / rect.size.height
        )
        let streamNormalized = captureNormalizedToStreamNormalized(captureNormalized)
        let nx = streamNormalized.x
        let ny = streamNormalized.y
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return nil }

        let content = contentRect
        return DesktopPoint(
            x: content.origin.x + nx * content.size.width,
            y: content.origin.y + ny * content.size.height
        )
    }

    public func viewDeltaToDisplayDelta(dx: Double, dy: Double) -> DesktopPoint {
        let rect = contentRect
        let capture = captureRect
        guard rect.size.width > 0, rect.size.height > 0 else { return .zero }
        let scaled = DesktopPoint(
            x: dx * (capture.size.width / rect.size.width),
            y: dy * (capture.size.height / rect.size.height)
        )
        return rotateDisplayDeltaIfNeeded(scaled)
    }

    private func centeredRect(width: Double, height: Double, in rect: DesktopRect) -> DesktopRect {
        DesktopRect(
            origin: DesktopPoint(
                x: rect.origin.x + (rect.size.width - width) / 2,
                y: rect.origin.y + (rect.size.height - height) / 2
            ),
            size: DesktopSize(width: width, height: height)
        )
    }

    private func streamNormalizedToCaptureNormalized(_ normalized: DesktopPoint) -> DesktopPoint {
        switch rotationTransform {
        case .none:
            return normalized
        case .quarterTurnClockwise:
            return DesktopPoint(x: normalized.y, y: 1 - normalized.x)
        case .quarterTurnCounterclockwise:
            return DesktopPoint(x: 1 - normalized.y, y: normalized.x)
        case .halfTurn:
            return DesktopPoint(x: 1 - normalized.x, y: 1 - normalized.y)
        }
    }

    private func captureNormalizedToStreamNormalized(_ normalized: DesktopPoint) -> DesktopPoint {
        switch rotationTransform {
        case .none:
            return normalized
        case .quarterTurnClockwise:
            return DesktopPoint(x: 1 - normalized.y, y: normalized.x)
        case .quarterTurnCounterclockwise:
            return DesktopPoint(x: normalized.y, y: 1 - normalized.x)
        case .halfTurn:
            return DesktopPoint(x: 1 - normalized.x, y: 1 - normalized.y)
        }
    }

    private func rotateDisplayDeltaIfNeeded(_ delta: DesktopPoint) -> DesktopPoint {
        switch rotationTransform {
        case .none:
            return delta
        case .quarterTurnClockwise:
            return DesktopPoint(x: delta.y, y: -delta.x)
        case .quarterTurnCounterclockwise:
            return DesktopPoint(x: -delta.y, y: delta.x)
        case .halfTurn:
            return DesktopPoint(x: -delta.x, y: -delta.y)
        }
    }
}
