import Foundation
import SharedModels

/// Thread-safe holder for the synthetic single-"display" layout describing the window currently
/// being streamed. The host input path reads this so pointer coordinates map into the window
/// (origin offset + size) through the existing `InputCoordinateTranslator` — no separate
/// coordinate abstraction, one pipeline for display and window targets. Nil ⇒ not window
/// streaming ⇒ input translates against the real display layout.
public final class StreamWindowGeometryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _windowLayout: DisplayLayout?

    public init() {}

    public var windowLayout: DisplayLayout? {
        lock.lock(); defer { lock.unlock() }
        return _windowLayout
    }

    public func set(_ layout: DisplayLayout?) {
        lock.lock(); _windowLayout = layout; lock.unlock()
    }
}

#if os(macOS)
import CoreGraphics

/// The window the session is currently streaming. Held by the coordinator so it can keep the
/// input geometry aligned as the window moves and detect when the window/app disappears.
struct WindowStreamTarget: Sendable {
    var windowID: CGWindowID
    var ownerPID: pid_t
    var bundleIdentifier: String
    var descriptor: DisplayDescriptor
}
#endif
