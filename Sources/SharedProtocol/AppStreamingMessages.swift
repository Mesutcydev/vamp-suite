import Foundation

// App Streaming reuses the entire display-streaming pipeline (capture → encode →
// WebRTC → decode → input). The only new wire concepts are: (1) an application
// registry the host publishes, and (2) a polymorphic "what is the live stream
// pointing at" target that generalises the existing single-display switch. These
// types deliberately mirror `DisplaySwitchMessages` so the host/client routing is
// a near-copy of the display-switch path that already ships.

/// What the live video stream is currently sourced from. Generalises the existing
/// `selectedDisplayID` so one session can retarget between a whole display, a single
/// window, or an application's front window without tearing down the WebRTC session.
public enum StreamTargetKind: String, Codable, Hashable, Sendable {
    case display
    case window
    case application
}

public struct StreamTarget: Codable, Hashable, Sendable {
    public var kind: StreamTargetKind
    /// `display`: `CGDirectDisplayID` as a string (wire-compatible with `selectedDisplayID`).
    /// `window`: `CGWindowID` as a string.
    /// `application`: bundle identifier.
    public var identifier: String

    public init(kind: StreamTargetKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }

    public static func display(_ displayID: String) -> StreamTarget {
        StreamTarget(kind: .display, identifier: displayID)
    }

    public static func window(_ windowID: String) -> StreamTarget {
        StreamTarget(kind: .window, identifier: windowID)
    }

    public static func application(_ bundleIdentifier: String) -> StreamTarget {
        StreamTarget(kind: .application, identifier: bundleIdentifier)
    }
}

/// One entry in the host's application registry, projected to the client's app browser.
public struct RemoteApplication: Codable, Hashable, Sendable, Identifiable {
    /// Bundle identifier — stable key across launches.
    // ponytail: bundleID is the identity. A second instance of the same app (rare on
    // macOS) would collide; switch to a per-instance id if multi-instance streaming matters.
    public var id: String { bundleIdentifier }
    public var bundleIdentifier: String
    public var name: String
    public var isRunning: Bool
    /// True when this app owns the frontmost (active) application on the Mac.
    public var isActive: Bool
    /// Base64-encoded small PNG (nil when unavailable or intentionally omitted).
    public var iconPNGBase64: String?
    /// `CGWindowID`s (as strings) of this app's on-screen windows, if running.
    public var windowIDs: [String]
    public var windowTitles: [String: String]?

    public init(
        bundleIdentifier: String,
        name: String,
        isRunning: Bool,
        isActive: Bool,
        iconPNGBase64: String? = nil,
        windowIDs: [String] = [],
        windowTitles: [String: String]? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.isRunning = isRunning
        self.isActive = isActive
        self.iconPNGBase64 = iconPNGBase64
        self.windowIDs = windowIDs
        self.windowTitles = windowTitles
    }

    /// The same entry with its icon dropped, so a large inventory can be shed down to fit
    /// the control channel's per-message budget instead of being silently discarded.
    public var withoutIcon: RemoteApplication {
        var copy = self
        copy.iconPNGBase64 = nil
        return copy
    }
}

/// Client → host: give me your current application registry.
public struct ApplicationListRequestMessage: Codable, Hashable, Sendable {
    public var offset: Int?
    public var sessionID: UUID
    public var senderDeviceID: UUID
    public var requestedAt: Date

    public init(sessionID: UUID, senderDeviceID: UUID, requestedAt: Date = Date(), offset: Int? = nil) {
        self.offset = offset
        self.sessionID = sessionID
        self.senderDeviceID = senderDeviceID
        self.requestedAt = requestedAt
    }
}

/// Host → client: the current application registry.
public struct ApplicationListSnapshotMessage: Codable, Hashable, Sendable {
    public var offset: Int?
    public var nextOffset: Int?
    public var sessionID: UUID
    public var senderDeviceID: UUID
    public var applications: [RemoteApplication]
    public var capturedAt: Date

    public init(
        sessionID: UUID,
        senderDeviceID: UUID,
        applications: [RemoteApplication],
        capturedAt: Date = Date(),
        offset: Int? = nil,
        nextOffset: Int? = nil
    ) {
        self.sessionID = sessionID
        self.senderDeviceID = senderDeviceID
        self.applications = applications
        self.capturedAt = capturedAt
        self.offset = offset
        self.nextOffset = nextOffset
    }
}

/// Client → host: point the live stream at `target`. For an application target that
/// is not running, the host launches/activates it and resolves its front window
/// when `launchIfNeeded` is true.
public enum AppWindowSizingMode: String, Codable, Hashable, Sendable {
    case adaptive
    case original
}

public struct StreamTargetSwitchRequestMessage: Codable, Hashable, Sendable {
    public var requestID: UUID?
    public var sessionID: UUID
    public var target: StreamTarget
    public var launchIfNeeded: Bool
    public var senderDeviceID: UUID
    public var requestedAt: Date
    /// The client's viewport aspect ratio (width / height, landscape). When present, the host
    /// resizes the streamed window to this aspect so it fills the phone with no letterbox bars.
    /// Optional → old clients omit it (decodes to nil) and the window is captured as-is.
    public var clientViewportAspect: Double?
    public var viewportWidth: Double?
    public var viewportHeight: Double?
    public var sizingMode: AppWindowSizingMode?

    public init(
        sessionID: UUID,
        target: StreamTarget,
        launchIfNeeded: Bool = true,
        senderDeviceID: UUID,
        requestedAt: Date = Date(),
        clientViewportAspect: Double? = nil,
        viewportWidth: Double? = nil,
        viewportHeight: Double? = nil,
        sizingMode: AppWindowSizingMode? = nil,
        requestID: UUID? = nil
    ) {
        self.sessionID = sessionID
        self.target = target
        self.launchIfNeeded = launchIfNeeded
        self.senderDeviceID = senderDeviceID
        self.requestedAt = requestedAt
        self.clientViewportAspect = clientViewportAspect
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.sizingMode = sizingMode
        self.requestID = requestID
    }
}

/// Host → client: the outcome of a target switch. Also sent *unsolicited* with
/// `status == .failed` when a live window disappears (window closed / app quit) so
/// the client can drop back to the app browser instead of freezing on a dead frame.
public struct StreamTargetSwitchResultMessage: Codable, Hashable, Sendable {
    public var appliedSizingMode: AppWindowSizingMode?
    public var requestID: UUID?
    public var sessionID: UUID
    public var resolvedTarget: StreamTarget
    public var senderDeviceID: UUID
    public var status: DisplaySwitchStatus
    public var reason: String?
    /// Resolved capture surface size in points, when known (window bounds or display size).
    public var width: Int?
    public var height: Int?
    /// Backing scale of the resolved surface (Retina), when known.
    public var scaleFactor: Double?
    public var startedAt: Date
    public var completedAt: Date

    public init(
        sessionID: UUID,
        resolvedTarget: StreamTarget,
        senderDeviceID: UUID,
        status: DisplaySwitchStatus,
        reason: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        scaleFactor: Double? = nil,
        startedAt: Date,
        completedAt: Date = Date(),
        requestID: UUID? = nil,
        appliedSizingMode: AppWindowSizingMode? = nil
    ) {
        self.appliedSizingMode = appliedSizingMode
        self.sessionID = sessionID
        self.resolvedTarget = resolvedTarget
        self.senderDeviceID = senderDeviceID
        self.status = status
        self.reason = reason
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.requestID = requestID
    }
}

/// Client → host: ask the Mac to quit a running application. The host uses a
/// normal terminate (the same request as Quit in the Dock), never a force-kill.
public struct ApplicationCloseRequestMessage: Codable, Hashable, Sendable {
    public var requestID: UUID?
    public var sessionID: UUID
    public var bundleIdentifier: String
    public var senderDeviceID: UUID
    public var requestedAt: Date

    public init(
        sessionID: UUID,
        bundleIdentifier: String,
        senderDeviceID: UUID,
        requestedAt: Date = Date(),
        requestID: UUID? = nil
    ) {
        self.sessionID = sessionID
        self.bundleIdentifier = bundleIdentifier
        self.senderDeviceID = senderDeviceID
        self.requestedAt = requestedAt
        self.requestID = requestID
    }
}

/// Host → client: outcome of a quit request.
public struct ApplicationCloseResultMessage: Codable, Hashable, Sendable {
    public var requestID: UUID?
    public var sessionID: UUID
    public var bundleIdentifier: String
    public var senderDeviceID: UUID
    public var status: DisplaySwitchStatus
    public var reason: String?
    public var completedAt: Date

    public init(
        sessionID: UUID,
        bundleIdentifier: String,
        senderDeviceID: UUID,
        status: DisplaySwitchStatus,
        reason: String? = nil,
        completedAt: Date = Date(),
        requestID: UUID? = nil
    ) {
        self.sessionID = sessionID
        self.bundleIdentifier = bundleIdentifier
        self.senderDeviceID = senderDeviceID
        self.status = status
        self.reason = reason
        self.completedAt = completedAt
        self.requestID = requestID
    }
}

/// Shared allow-list for remote quit. System shells and Vamp hosts stay off-limits.
public enum ApplicationClosePolicy {
    public static let protectedBundleIdentifiers: Set<String> = [
        "com.mesutcy.remotedesktop.minhost",
        "com.mesutcy.remotedesktop.host",
        "com.mesutcy.remotedesktop.terminalhost",
        "com.apple.loginwindow",
        "com.apple.WindowServer",
        "com.apple.dock",
        "com.apple.finder",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.UserNotificationCenter",
        "com.apple.SecurityAgent",
    ]

    public static func normalizedBundleIdentifier(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...256).contains(trimmed.count) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        guard trimmed.contains(".") else { return nil }
        return trimmed
    }

    public static func canClose(_ raw: String, hostBundleIdentifier: String? = nil) -> Bool {
        guard let identifier = normalizedBundleIdentifier(raw) else { return false }
        let lower = identifier.lowercased()
        if protectedBundleIdentifiers.contains(where: { $0.lowercased() == lower }) {
            return false
        }
        if let host = hostBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty,
           host.lowercased() == lower {
            return false
        }
        return true
    }
}
