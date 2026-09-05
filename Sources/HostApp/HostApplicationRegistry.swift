#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import SharedModels
import SharedProtocol
@preconcurrency import ScreenCaptureKit

/// One on-screen window, with bounds in the same coordinate space the input translator
/// uses (`DisplayDescriptor.frame`): points, global, top-left origin — exactly what
/// `CGWindowListCopyWindowInfo`'s `kCGWindowBounds` returns.
public struct WindowInfo: Sendable, Hashable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    public let bounds: DesktopRect

    public var area: Double { bounds.size.width * bounds.size.height }
}

/// Discovers the macOS applications a client can stream and resolves an application to a
/// concrete streamable window. Running apps come from `NSWorkspace`; installed apps from a
/// shallow scan of the standard application directories (never a full-filesystem walk);
/// windows and their bounds from CoreGraphics.
public final class HostApplicationRegistry {
    private let lock = NSLock()
    /// bundleID → base64 PNG. Icons rarely change, so encode once and reuse — the app list
    /// is re-requested on every reconnect/refresh and re-encoding every icon each time is waste.
    private var iconCache: [String: String] = [:]

    public init() {}

    /// A live snapshot of streamable applications, ordered for the client's app browser.
    /// Running apps (which own on-screen windows) first, then other installed apps.
    public func snapshot(includeIcons: Bool = true) -> [RemoteApplication] {
        let running = runningApplications(includeIcons: includeIcons)
        let installed = installedApplications(includeIcons: includeIcons)
        return Self.sortedForBrowser(Self.dedupedByBundleID(running + installed))
    }

    // MARK: - Running / installed discovery

    private func runningApplications(includeIcons: Bool) -> [RemoteApplication] {
        let windowsByPID = onScreenWindowIDsByPID()
        let descriptions = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let titles = descriptions.reduce(into: [String: String]()) { result, info in
            if let id = info[kCGWindowNumber as String] as? NSNumber,
               let title = info[kCGWindowName as String] as? String, !title.isEmpty {
                result[id.stringValue] = title
            }
        }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            // `.regular` == a normal windowed app in the Dock; skips agents/UIElements
            // that have no user-facing window to stream.
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  let name = app.localizedName else { return nil }
            let windowIDs = (windowsByPID[app.processIdentifier] ?? []).map(String.init)
            return RemoteApplication(
                bundleIdentifier: bundleID,
                name: name,
                isRunning: true,
                isActive: app.processIdentifier == frontmostPID,
                iconPNGBase64: includeIcons ? iconBase64(bundleID: bundleID) { app.icon } : nil,
                windowIDs: windowIDs,
                windowTitles: titles.filter { windowIDs.contains($0.key) }
            )
        }
    }

    /// Installed apps from the standard locations only — not a recursive filesystem walk.
    private func installedApplications(includeIcons: Bool) -> [RemoteApplication] {
        var results: [RemoteApplication] = []
        for directory in Self.applicationDirectories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension.lowercased() == "app" {
                guard let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier,
                      Self.hasUserFacingWindows(bundle) else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                results.append(RemoteApplication(
                    bundleIdentifier: bundleID,
                    name: name,
                    isRunning: false,
                    isActive: false,
                    // Use the same small cached representation as running apps. This keeps the
                    // All Apps section recognizable without adding a second icon protocol.
                    iconPNGBase64: includeIcons ? iconBase64(bundleID: bundleID) {
                        NSWorkspace.shared.icon(forFile: url.path)
                    } : nil,
                    windowIDs: []
                ))
            }
        }
        // Finder is user-facing but lives outside the standard Applications folders. Include
        // this fixed location without recursively exposing every CoreServices helper.
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        if let bundle = Bundle(url: finderURL), let bundleID = bundle.bundleIdentifier {
            results.append(RemoteApplication(
                bundleIdentifier: bundleID,
                name: (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? "Finder",
                isRunning: false,
                isActive: false,
                iconPNGBase64: includeIcons ? iconBase64(bundleID: bundleID) {
                    NSWorkspace.shared.icon(forFile: finderURL.path)
                } : nil,
                windowIDs: []
            ))
        }
        return results
    }

    /// Agents and background-only bundles never open a normal window, so listing them only
    /// fills the browser with rows whose launch is guaranteed to time out.
    private static func hasUserFacingWindows(_ bundle: Bundle) -> Bool {
        let info = bundle.infoDictionary ?? [:]
        return !isEnabled(info["LSUIElement"]) && !isEnabled(info["LSBackgroundOnly"])
    }

    /// These Info.plist keys are written both as booleans and as the strings "1"/"YES".
    private static func isEnabled(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["1", "true", "yes"].contains(string.lowercased()) }
        return false
    }

    /// Standard app locations. `/System/Applications/Utilities` is one level deeper but is a
    /// fixed, well-known directory — not an open-ended recursive scan.
    private static let applicationDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    ]

    // MARK: - Window discovery / resolution

    /// The best window to stream for a running application (by PID). Selection policy in
    /// `chooseWindow(from:)`. Returns nil when the app has no on-screen normal window yet
    /// (e.g. still launching, or only a menu-bar presence).
    public func streamableWindow(forPID pid: pid_t) -> WindowInfo? {
        Self.chooseWindow(from: onScreenWindows().filter { $0.ownerPID == pid && $0.area > 0 })
    }

    /// Prefer a window created by the current launch action. This matters for apps that already
    /// own a hidden/background document and then present a welcome panel or compose window.
    public func streamableWindow(forPID pid: pid_t, excluding previousWindowIDs: Set<CGWindowID>) -> WindowInfo? {
        let windows = onScreenWindows().filter { $0.ownerPID == pid && $0.area > 0 }
        let newlyCreated = windows.filter { !previousWindowIDs.contains($0.windowID) }
        return Self.chooseWindow(from: newlyCreated) ?? Self.chooseWindow(from: windows)
    }

    public func newlyCreatedStreamableWindow(
        forPID pid: pid_t,
        excluding previousWindowIDs: Set<CGWindowID>
    ) -> WindowInfo? {
        Self.chooseWindow(from: onScreenWindows().filter {
            $0.ownerPID == pid && $0.area > 0 && !previousWindowIDs.contains($0.windowID)
        })
    }

    public func streamableWindowIDs(forPID pid: pid_t) -> Set<CGWindowID> {
        Set(onScreenWindows().lazy.filter { $0.ownerPID == pid }.map(\.windowID))
    }

    /// ScreenCaptureKit is authoritative for whether a CoreGraphics window
    /// can actually be captured. Vamp Assistant performs the same check before
    /// returning a launch result.
    public func isShareableWindow(_ windowID: CGWindowID) async -> Bool {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) else { return false }
        return content.windows.contains { $0.windowID == windowID && $0.isOnScreen }
    }

    /// Look up a specific window's current bounds (for a `.window` target and for keeping the
    /// input mapping aligned as the window moves).
    public func windowInfo(windowID: CGWindowID) -> WindowInfo? {
        onScreenWindows().first { $0.windowID == windowID }
    }

    /// All on-screen normal-layer windows with bounds. CoreGraphics is synchronous and needs
    /// no ScreenCaptureKit round-trip; window numbers and bounds are readable without
    /// screen-recording consent (pixels are not).
    func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return infoList.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let windowNumber = info[kCGWindowNumber as String] as? CGWindowID,
                  // Layer 0 == normal application windows; higher layers are menus, the Dock,
                  // status items, and overlays — not streamable content.
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return WindowInfo(
                windowID: windowNumber,
                ownerPID: pid,
                bounds: DesktopRect(
                    origin: DesktopPoint(x: cgBounds.origin.x, y: cgBounds.origin.y),
                    size: DesktopSize(width: cgBounds.size.width, height: cgBounds.size.height)
                )
            )
        }
    }

    func onScreenWindowIDsByPID() -> [pid_t: [CGWindowID]] {
        var map: [pid_t: [CGWindowID]] = [:]
        for window in onScreenWindows() {
            map[window.ownerPID, default: []].append(window.windowID)
        }
        return map
    }

    /// Backing scale of the window's screen (Retina), for pixel-dimension math. Falls back to
    /// the main screen, then 2.0 — never 1.0-by-default, which would under-size a Retina capture.
    public func windowScaleFactor(bounds: DesktopRect) -> Double {
        // Window bounds are CG top-left; NSScreen.frame is bottom-left. Compare by the point
        // that is unambiguous under either convention: does a screen's frame contain the
        // window's center once flipped into that screen's space? Simplest robust proxy: match
        // the screen whose CG frame contains the window origin.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let centerXTopLeft = bounds.origin.x + bounds.size.width / 2
        let centerYTopLeft = bounds.origin.y + bounds.size.height / 2
        for screen in NSScreen.screens {
            let f = screen.frame // bottom-left origin
            let cgY = mainHeight - f.origin.y - f.height // convert to top-left
            let cgRect = CGRect(x: f.origin.x, y: cgY, width: f.width, height: f.height)
            if cgRect.contains(CGPoint(x: centerXTopLeft, y: centerYTopLeft)) {
                return Double(screen.backingScaleFactor)
            }
        }
        return Double(NSScreen.main?.backingScaleFactor ?? 2.0)
    }

    // MARK: - Icon cache

    private func iconBase64(bundleID: String, icon: () -> NSImage?) -> String? {
        if let cached = lock.withLock({ iconCache[bundleID] }) { return cached }
        guard let encoded = Self.encodeIcon(icon()) else { return nil }
        lock.withLock { iconCache[bundleID] = encoded }
        return encoded
    }

    private static func encodeIcon(_ icon: NSImage?) -> String? {
        guard let icon else { return nil }
        // Downscale to a small tile so a whole app list stays well under the 1 MB data-channel
        // cap; the client only renders these at list-row size.
        let side = 32
        let target = NSImage(size: NSSize(width: side, height: side))
        target.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return png.base64EncodedString()
    }

    // MARK: - Pure ordering / selection (unit-tested)

    /// Collapse duplicate bundle identifiers, keeping the richer entry — active wins, else the
    /// one exposing more windows, else a running instance over an installed-only duplicate.
    static func dedupedByBundleID(_ apps: [RemoteApplication]) -> [RemoteApplication] {
        var byID: [String: RemoteApplication] = [:]
        for app in apps {
            guard let existing = byID[app.bundleIdentifier] else {
                byID[app.bundleIdentifier] = app
                continue
            }
            let incomingWins = (app.isActive && !existing.isActive)
                || (app.isActive == existing.isActive && app.isRunning && !existing.isRunning)
                || (app.isActive == existing.isActive && app.isRunning == existing.isRunning
                    && app.windowIDs.count > existing.windowIDs.count)
            if incomingWins { byID[app.bundleIdentifier] = app }
        }
        return Array(byID.values)
    }

    /// Browser order: the active app first, then running apps, then alphabetical.
    static func sortedForBrowser(_ apps: [RemoteApplication]) -> [RemoteApplication] {
        apps.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Deterministic default window: the largest on-screen window, ties broken by the lower
    /// window ID. Largest-area is a robust "main content window" heuristic and is stable for
    /// tests (unlike front-to-back list order). Callers pass windows already filtered to one
    /// app and to non-zero area.
    static func chooseWindow(from windows: [WindowInfo]) -> WindowInfo? {
        windows.max { lhs, rhs in
            if lhs.area != rhs.area { return lhs.area < rhs.area }
            // Areas tie: treat the higher ID as "less" so `max` returns the lower ID.
            return lhs.windowID > rhs.windowID
        }
    }

    /// Fit into the host display while preserving the window's useful content width.
    static func targetWindowFrame(
        current: CGRect,
        display: CGRect,
        requestedAspect: Double
    ) -> CGRect {
        guard requestedAspect.isFinite, requestedAspect > 0 else { return current }
        let aspect = min(max(CGFloat(requestedAspect), 0.25), 4)
        let available = CGRect(
            x: display.minX + 24,
            y: display.minY + 52,
            width: max(display.width - 48, 1),
            height: max(display.height - 76, 1)
        )
        let fitted = AdaptiveWindowSizing.size(
            original: DesktopSize(width: current.width, height: current.height),
            available: DesktopSize(width: available.width, height: available.height),
            viewport: DesktopSize(width: aspect, height: 1), bundleIdentifier: "")
        let size = CGSize(width: fitted.width, height: fitted.height)
        let maxX = max(available.minX, available.maxX - size.width)
        let maxY = max(available.minY, available.maxY - size.height)
        return CGRect(
            x: min(max(current.minX, available.minX), maxX),
            y: min(max(current.minY, available.minY), maxY),
            width: size.width,
            height: size.height
        )
    }

    /// A bounds match must be unique. Never guess the focused window when AX and
    /// the capture inventory disagree (or two windows have identical bounds).
    static func matchingWindowIndex(frames: [CGRect?], target: CGRect) -> Int? {
        let matches = frames.indices.filter { index in
            guard let frame = frames[index] else { return false }
            return abs(frame.minX - target.minX) < 2 && abs(frame.minY - target.minY) < 2
                && abs(frame.width - target.width) < 2 && abs(frame.height - target.height) < 2
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func displayBounds(containing window: CGRect) -> CGRect {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        return displays.prefix(Int(count))
            .map(CGDisplayBounds)
            .max { lhs, rhs in
                lhs.intersection(window).area < rhs.intersection(window).area
            } ?? CGDisplayBounds(CGMainDisplayID())
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
#endif
