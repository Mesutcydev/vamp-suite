import Foundation

/// Stream-specific geometry for the currently selected host display.
/// `captureRect` is expressed in display-local logical coordinates so the client can
/// convert stream taps directly into host-event coordinates before the host re-applies
/// the display's global origin.
public struct DisplayStreamConfiguration: Codable, Hashable, Sendable {
    public var displayID: String
    public var displayName: String
    public var pixelWidth: Double
    public var pixelHeight: Double
    public var logicalWidth: Double
    public var logicalHeight: Double
    public var backingScaleFactor: Double
    public var originX: Double
    public var originY: Double
    public var rotation: Double
    public var isMain: Bool
    public var isActive: Bool
    public var streamWidth: Double
    public var streamHeight: Double
    public var captureRect: DesktopRect
    public var visibleFrame: DesktopRect?

    public init(
        displayID: String,
        displayName: String,
        pixelWidth: Double,
        pixelHeight: Double,
        logicalWidth: Double,
        logicalHeight: Double,
        backingScaleFactor: Double,
        originX: Double,
        originY: Double,
        rotation: Double,
        isMain: Bool,
        isActive: Bool,
        streamWidth: Double,
        streamHeight: Double,
        captureRect: DesktopRect,
        visibleFrame: DesktopRect? = nil
    ) {
        self.displayID = displayID
        self.displayName = displayName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.backingScaleFactor = backingScaleFactor
        self.originX = originX
        self.originY = originY
        self.rotation = rotation
        self.isMain = isMain
        self.isActive = isActive
        self.streamWidth = streamWidth
        self.streamHeight = streamHeight
        self.captureRect = captureRect
        self.visibleFrame = visibleFrame
    }

    public init(
        display: DisplayDescriptor,
        streamWidth: Double,
        streamHeight: Double,
        captureRect: DesktopRect? = nil
    ) {
        self.init(
            displayID: display.id,
            displayName: display.name,
            pixelWidth: display.pixelSize.width,
            pixelHeight: display.pixelSize.height,
            logicalWidth: display.frame.size.width,
            logicalHeight: display.frame.size.height,
            backingScaleFactor: display.scaleFactor,
            originX: display.frame.origin.x,
            originY: display.frame.origin.y,
            rotation: display.rotation,
            isMain: display.isPrimary,
            isActive: display.isActive,
            streamWidth: streamWidth,
            streamHeight: streamHeight,
            captureRect: captureRect ?? Self.fullDisplayCaptureRect(for: display),
            visibleFrame: display.visibleFrame
        )
    }

    public var streamSize: DesktopSize {
        DesktopSize(width: streamWidth, height: streamHeight)
    }

    public var sourceDisplayPixelSize: DesktopSize {
        DesktopSize(width: pixelWidth, height: pixelHeight)
    }

    public var sourceDisplayLogicalSize: DesktopSize {
        DesktopSize(width: logicalWidth, height: logicalHeight)
    }

    public var displayOrigin: DesktopPoint {
        DesktopPoint(x: originX, y: originY)
    }

    public var sourceDisplayFrame: DesktopRect {
        DesktopRect(origin: displayOrigin, size: sourceDisplayLogicalSize)
    }

    public static func fullDisplayCaptureRect(for display: DisplayDescriptor) -> DesktopRect {
        DesktopRect(origin: .zero, size: display.frame.size)
    }
}
