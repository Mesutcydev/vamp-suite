import Foundation

public struct DesktopPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct DesktopSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct DesktopRect: Codable, Hashable, Sendable {
    public var origin: DesktopPoint
    public var size: DesktopSize

    public init(origin: DesktopPoint, size: DesktopSize) {
        self.origin = origin
        self.size = size
    }
}

public struct DisplayDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var frame: DesktopRect
    public var visibleFrame: DesktopRect?
    public var pixelSize: DesktopSize
    public var scaleFactor: Double
    public var refreshRate: Double?
    public var rotation: Double
    public var isPrimary: Bool
    public var isActive: Bool

    public init(
        id: String,
        name: String,
        frame: DesktopRect,
        visibleFrame: DesktopRect? = nil,
        pixelSize: DesktopSize,
        scaleFactor: Double,
        refreshRate: Double? = nil,
        rotation: Double = 0,
        isPrimary: Bool,
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.pixelSize = pixelSize
        self.scaleFactor = scaleFactor
        self.refreshRate = refreshRate
        self.rotation = rotation
        self.isPrimary = isPrimary
        self.isActive = isActive
    }
}

public struct DisplayLayout: Codable, Hashable, Sendable {
    public var displays: [DisplayDescriptor]
    public var primaryDisplayID: String?
    public var virtualBounds: DesktopRect

    public init(
        displays: [DisplayDescriptor],
        primaryDisplayID: String?,
        virtualBounds: DesktopRect
    ) {
        self.displays = displays
        self.primaryDisplayID = primaryDisplayID
        self.virtualBounds = virtualBounds
    }
}

// MARK: - DesktopPoint Helpers

extension DesktopPoint {
    public static let zero = DesktopPoint(x: 0, y: 0)

    public func offset(dx: Double, dy: Double) -> DesktopPoint {
        DesktopPoint(x: x + dx, y: y + dy)
    }

    public func scaled(by factor: Double) -> DesktopPoint {
        DesktopPoint(x: x * factor, y: y * factor)
    }
}

// MARK: - DesktopSize Helpers

extension DesktopSize {
    public static let zero = DesktopSize(width: 0, height: 0)

    public func scaled(by factor: Double) -> DesktopSize {
        DesktopSize(width: width * factor, height: height * factor)
    }
}

// MARK: - DesktopRect Helpers

extension DesktopRect {
    public static let zero = DesktopRect(origin: .zero, size: .zero)

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }

    public func contains(_ point: DesktopPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    public func union(_ other: DesktopRect) -> DesktopRect {
        let newMinX = min(self.minX, other.minX)
        let newMinY = min(self.minY, other.minY)
        let newMaxX = max(self.maxX, other.maxX)
        let newMaxY = max(self.maxY, other.maxY)
        return DesktopRect(
            origin: DesktopPoint(x: newMinX, y: newMinY),
            size: DesktopSize(width: newMaxX - newMinX, height: newMaxY - newMinY)
        )
    }
}

// MARK: - DisplayLayout Factory & Coordinate Mapping

extension DisplayLayout {
    public static func computed(from displays: [DisplayDescriptor]) -> DisplayLayout {
        guard !displays.isEmpty else {
            return DisplayLayout(displays: [], primaryDisplayID: nil, virtualBounds: .zero)
        }
        let primaryID = displays.first(where: \.isPrimary)?.id ?? displays.first?.id
        var bounds = displays[0].frame
        for display in displays.dropFirst() {
            bounds = bounds.union(display.frame)
        }
        return DisplayLayout(displays: displays, primaryDisplayID: primaryID, virtualBounds: bounds)
    }

    public func display(withID id: String) -> DisplayDescriptor? {
        displays.first { $0.id == id }
    }

    public func display(containing point: DesktopPoint) -> DisplayDescriptor? {
        displays.first { $0.frame.contains(point) }
    }

    public func globalToLocal(_ point: DesktopPoint, displayID: String) -> DesktopPoint? {
        guard let display = display(withID: displayID) else { return nil }
        return DesktopPoint(
            x: point.x - display.frame.origin.x,
            y: point.y - display.frame.origin.y
        )
    }

    public func localToGlobal(_ point: DesktopPoint, displayID: String) -> DesktopPoint? {
        guard let display = display(withID: displayID) else { return nil }
        return DesktopPoint(
            x: point.x + display.frame.origin.x,
            y: point.y + display.frame.origin.y
        )
    }

    public func globalToPixel(_ point: DesktopPoint, displayID: String) -> DesktopPoint? {
        guard let display = display(withID: displayID),
              let local = globalToLocal(point, displayID: displayID) else { return nil }
        return local.scaled(by: display.scaleFactor)
    }

    public func pixelToGlobal(_ pixel: DesktopPoint, displayID: String) -> DesktopPoint? {
        guard let display = display(withID: displayID) else { return nil }
        let local = pixel.scaled(by: 1.0 / display.scaleFactor)
        return localToGlobal(local, displayID: displayID)
    }

    public func normalizedPoint(_ globalPoint: DesktopPoint, in displayID: String) -> DesktopPoint? {
        guard let display = display(withID: displayID),
              let local = globalToLocal(globalPoint, displayID: displayID) else { return nil }
        guard display.frame.size.width > 0, display.frame.size.height > 0 else { return nil }
        return DesktopPoint(
            x: local.x / display.frame.size.width,
            y: local.y / display.frame.size.height
        )
    }

    public func globalPoint(fromNormalized normalized: DesktopPoint, in displayID: String) -> DesktopPoint? {
        guard let display = display(withID: displayID) else { return nil }
        let local = DesktopPoint(
            x: normalized.x * display.frame.size.width,
            y: normalized.y * display.frame.size.height
        )
        return localToGlobal(local, displayID: displayID)
    }
}
