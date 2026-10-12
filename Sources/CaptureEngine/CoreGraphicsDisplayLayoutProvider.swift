#if os(macOS)
import AppKit
import Foundation
import IOKit.pwr_mgt
import SharedModels
import os

public final class CoreGraphicsDisplayLayoutProvider: DisplayLayoutObserving {
    private static let logger = Logger(subsystem: "com.remotedesktop.host", category: "DisplayLayout")
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<DisplayLayout>.Continuation] = [:]
    private var notificationObserver: Any?

    public init() {
        notificationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notifyLayoutChanged()
        }
    }

    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        lock.lock()
        continuations.values.forEach { $0.finish() }
        continuations.removeAll()
        lock.unlock()
    }

    // MARK: - DisplayLayoutProviding

    public func currentDisplayLayout() async throws -> DisplayLayout {
        let layout = queryDisplayLayout()
        guard layout.displays.isEmpty else { return layout }

        wakeDisplay()
        var retriedLayout = layout
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            retriedLayout = queryDisplayLayout()
            if !retriedLayout.displays.isEmpty {
                return retriedLayout
            }
        }
        return retriedLayout
    }

    // MARK: - DisplayLayoutObserving

    public func layoutChanges() -> AsyncStream<DisplayLayout> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    // MARK: - Private

    private func notifyLayoutChanged() {
        let layout = queryDisplayLayout()
        lock.lock()
        let conts = Array(continuations.values)
        lock.unlock()
        conts.forEach { $0.yield(layout) }
    }

    func queryDisplayLayout() -> DisplayLayout {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else {
            return DisplayLayout(displays: [], primaryDisplayID: nil, virtualBounds: .zero)
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let result = CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
        guard result == .success else {
            return DisplayLayout(displays: [], primaryDisplayID: nil, virtualBounds: .zero)
        }

        let mainDisplayID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainDisplayID)
        let screens = NSScreen.screens

        // Drop mirror-set members. A mirrored display shows the SAME content as its master and
        // can't be captured independently by ScreenCaptureKit, so reporting it as a second display
        // handed the client a phantom "waiting for display…" slot and a display switcher that
        // showed the same screen for both. `CGDisplayMirrorsDisplay` returns the master's ID for a
        // mirror member and 0 (kCGNullDirectDisplay) for an independent display — keep only the latter.
        let allActive = Array(displayIDs.prefix(Int(displayCount)))
        let activeIDs = allActive.filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        if activeIDs.count != allActive.count {
            Self.logger.info("Display layout: \(allActive.count, privacy: .public) active, kept \(activeIDs.count, privacy: .public) after dropping \(allActive.count - activeIDs.count, privacy: .public) mirror member(s)")
        }

        let displays: [DisplayDescriptor] = activeIDs.map { cgDisplayID in
            let bounds = CGDisplayBounds(cgDisplayID)
            let pixelWidth = CGDisplayPixelsWide(cgDisplayID)
            let pixelHeight = CGDisplayPixelsHigh(cgDisplayID)
            let isPrimary = cgDisplayID == mainDisplayID

            let matchingScreen = screens.first { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == cgDisplayID
            }

            let scaleFactor: Double = {
                if let screen = matchingScreen {
                    return Double(screen.backingScaleFactor)
                }
                guard bounds.width > 0 else { return 1.0 }
                return Double(pixelWidth) / bounds.width
            }()

            let name = matchingScreen?.localizedName ?? "Display \(cgDisplayID)"

            let visibleFrame: DesktopRect?
            if let screen = matchingScreen {
                let nsVisible = screen.visibleFrame
                let cgVisibleY = mainBounds.height - nsVisible.origin.y - nsVisible.height
                visibleFrame = DesktopRect(
                    origin: DesktopPoint(x: nsVisible.origin.x, y: cgVisibleY),
                    size: DesktopSize(width: nsVisible.width, height: nsVisible.height)
                )
            } else {
                visibleFrame = nil
            }

            let mode = CGDisplayCopyDisplayMode(cgDisplayID)
            let refreshRate: Double? = {
                guard let rate = mode?.refreshRate, rate > 0 else { return nil }
                return rate
            }()
            let rotation = CGDisplayRotation(cgDisplayID)

            return DisplayDescriptor(
                id: String(cgDisplayID),
                name: name,
                frame: DesktopRect(
                    origin: DesktopPoint(x: bounds.origin.x, y: bounds.origin.y),
                    size: DesktopSize(width: bounds.width, height: bounds.height)
                ),
                visibleFrame: visibleFrame,
                pixelSize: DesktopSize(width: Double(pixelWidth), height: Double(pixelHeight)),
                scaleFactor: scaleFactor,
                refreshRate: refreshRate,
                rotation: rotation,
                isPrimary: isPrimary,
                isActive: true
            )
        }

        return .computed(from: displays)
    }

    private func wakeDisplay() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Vamp display layout query" as CFString, kIOPMUserActiveLocal, &id)
    }
}
#endif
