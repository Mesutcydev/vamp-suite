import Foundation
import SharedModels

/// Maps touch coordinates from the iOS view-space into display-local coordinates
/// on the host, accounting for aspect ratio letterboxing and scale.
///
/// All inputs/outputs use CGFloat-compatible `Double` values.
/// The mapper is pure logic — no UIKit or SwiftUI dependency — so it is fully testable.
public struct ViewportCoordinateMapper: Sendable, Hashable {

    /// The display being controlled (host-side geometry).
    public var display: DisplayDescriptor

    /// Optional stream-specific metadata for the selected host display.
    public var streamConfiguration: DisplayStreamConfiguration?

    /// The view size in points that the remote surface occupies on the iOS device.
    public var viewSize: DesktopSize

    /// Insets within the viewport that should not participate in mapping.
    public var viewInsets: DesktopEdgeInsets

    /// Pixel density of the iOS render surface.
    public var viewPixelScale: Double

    /// Interaction mode: absolute maps touch position to display position; relative uses deltas.
    public var interactionMode: InteractionMode

    /// Render mode for the remote display surface.
    public var displayMode: DisplayMappingEngine.DisplayMode

    public enum InteractionMode: String, Sendable, Hashable {
        case absolute
        case relative
    }

    public init(
        display: DisplayDescriptor,
        streamConfiguration: DisplayStreamConfiguration? = nil,
        viewSize: DesktopSize,
        viewInsets: DesktopEdgeInsets = .zero,
        viewPixelScale: Double = 1,
        displayMode: DisplayMappingEngine.DisplayMode = .fitDisplay,
        interactionMode: InteractionMode = .absolute
    ) {
        self.display = display
        self.streamConfiguration = streamConfiguration
        self.viewSize = viewSize
        self.viewInsets = viewInsets
        self.viewPixelScale = viewPixelScale
        self.displayMode = displayMode
        self.interactionMode = interactionMode
    }

    public var mappingEngine: DisplayMappingEngine {
        DisplayMappingEngine(
            display: display,
            streamConfiguration: streamConfiguration,
            viewSize: viewSize,
            viewInsets: viewInsets,
            viewPixelScale: viewPixelScale,
            displayMode: displayMode
        )
    }

    // MARK: - Fitted Rect (letterboxed content area within the view)

    /// The rectangle within `viewSize` where the display content is rendered,
    /// preserving the display's aspect ratio. Letterbox bars are outside this rect.
    public var fittedContentRect: DesktopRect {
        mappingEngine.contentRect
    }

    // MARK: - Absolute Mapping

    /// Convert a view-space point (touch location in the iOS view) to a
    /// display-local point (in the host display's coordinate system, in points).
    ///
    /// Returns `nil` if the touch is in the letterbox/pillarbox area.
    public func viewToDisplayLocal(_ viewPoint: DesktopPoint) -> DesktopPoint? {
        mappingEngine.viewPointToDisplayLogical(viewPoint)
    }

    /// Convert a display-local point back to view-space coordinates.
    public func displayLocalToView(_ displayLocal: DesktopPoint) -> DesktopPoint? {
        mappingEngine.displayLogicalToViewPoint(displayLocal)
    }

    // MARK: - Relative Mapping

    /// Convert a view-space delta (drag translation) into a display-space delta,
    /// scaled by the ratio of display size to fitted content size.
    public func viewDeltaToDisplayDelta(dx: Double, dy: Double) -> DesktopPoint {
        mappingEngine.viewDeltaToDisplayDelta(dx: dx, dy: dy)
    }

    // MARK: - Hit Testing

    /// Whether a view-space point lies within the fitted content area.
    public func isInsideContent(_ viewPoint: DesktopPoint) -> Bool {
        fittedContentRect.contains(viewPoint)
    }
}
