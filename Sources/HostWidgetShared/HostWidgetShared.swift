import Foundation

/// Shared contract between the Mac host app and its desktop widget extension.
///
/// The host app writes a `HostWidgetSnapshot` into a shared App Group whenever
/// its session state changes; the widget reads it to render. The widget's
/// stop/restart/start buttons write a `HostWidgetAction` back and post a Darwin
/// notification so a running host app applies it immediately.
///
/// This file is compiled into BOTH the `MacHostApp` and `HostWidget` targets, so
/// it must not depend on anything outside Foundation.
public enum HostWidgetConstants {
    /// Shared App Group used by signed Vamp Host/widget builds. Unsigned builds
    /// fall back to the Vamp Host Application Support directory below.
    public static let appGroup = "PUH4GMFV56.com.mesutcy.remotedesktop"

    /// UserDefaults key holding the JSON-encoded `HostWidgetSnapshot`.
    public static let snapshotKey = "host.widget.snapshot"

    /// UserDefaults key holding the JSON-encoded pending `HostWidgetAction`.
    public static let pendingActionKey = "host.widget.pendingAction"
    /// Fingerprint-bound approval written by `vamp` after an independent check.
    public static let pendingTrustKey = "host.widget.pendingTrust"

    /// Darwin notification posted by the widget when the user taps a button,
    /// observed by the running host app to apply the action without delay.
    public static let actionDarwinName = "com.mesutcy.remotedesktop.widget.action"

    /// The widget's `kind` identifier (used for reload + install detection).
    public static let widgetKind = "HostStatusWidget"

    /// The host app's bundle identifier (used by the widget to launch the app).
    public static let hostBundleIdentifier = "com.mesutcy.remotedesktop.host"

    /// Custom URL scheme the host app registers; the widget's control buttons use
    /// `vamphost://action/<start|stop|restart>` links, which the app handles in
    /// `onOpenURL`. This is far more reliable on macOS desktop widgets than an
    /// in-extension AppIntent.
    public static let urlScheme = "vamphost"
    /// Accepted for existing widgets and older CLI installations.
    public static let legacyURLScheme = "screenharbor"
    public static let urlActionHost = "action"

    /// App-local (standard defaults) cache of whether the widget is installed, so
    /// the app can decide at launch — before the async WidgetCenter query returns —
    /// whether to stay in the menu bar instead of showing the floating window.
    public static let installedCacheKey = "host.widget.installed"
}

/// A coarse session phase the widget can render without importing the app's
/// internal `SessionPhase`.
public enum HostWidgetPhase: String, Codable, Sendable {
    case idle       // runtime stopped
    case ready      // advertising / awaiting client
    case connecting // signaling / negotiating
    case live       // streaming to a client
    case error
    case setup      // permissions required
}

/// A device waiting for host approval before it can pair and connect.
public struct HostWidgetPendingPairingRequest: Codable, Equatable, Sendable {
    public var displayName: String
    public var fingerprint: String
    /// When the request auto-rejects if the host does not act.
    public var deadline: Date

    public init(displayName: String, fingerprint: String, deadline: Date) {
        self.displayName = displayName
        self.fingerprint = fingerprint
        self.deadline = deadline
    }
}

/// Immutable status snapshot the host app shares with the widget.
public struct HostWidgetSnapshot: Codable, Equatable, Sendable {
    public var phase: HostWidgetPhase
    /// Human-readable status line, e.g. "ready", "connected to client Mac".
    public var statusTitle: String
    /// Display name of this Mac host.
    public var hostName: String
    /// Primary connect address, e.g. "192.168.1.148:9471" (nil when stopped).
    public var primaryAddress: String?
    /// Short label for the address, e.g. "lan" or "tailscale".
    public var addressLabel: String?
    /// Connected client name when streaming, otherwise nil.
    public var connectedClient: String?
    /// Device waiting for pairing / connection approval, otherwise nil.
    public var pendingPairingRequest: HostWidgetPendingPairingRequest?
    /// When this snapshot was produced.
    public var updatedAt: Date

    public init(
        phase: HostWidgetPhase,
        statusTitle: String,
        hostName: String,
        primaryAddress: String?,
        addressLabel: String?,
        connectedClient: String?,
        pendingPairingRequest: HostWidgetPendingPairingRequest? = nil,
        updatedAt: Date
    ) {
        self.phase = phase
        self.statusTitle = statusTitle
        self.hostName = hostName
        self.primaryAddress = primaryAddress
        self.addressLabel = addressLabel
        self.connectedClient = connectedClient
        self.pendingPairingRequest = pendingPairingRequest
        self.updatedAt = updatedAt
    }

    /// Shown in the widget gallery and before the host has published anything.
    public static func placeholder(at date: Date = Date(timeIntervalSinceReferenceDate: 0)) -> HostWidgetSnapshot {
        HostWidgetSnapshot(
            phase: .ready,
            statusTitle: "ready",
            hostName: "Vamp Host",
            primaryAddress: "192.168.1.148:9471",
            addressLabel: "lan",
            connectedClient: nil,
            pendingPairingRequest: nil,
            updatedAt: date
        )
    }
}

/// Actions the widget and `vamp` CLI can request of the host app.
public enum HostWidgetAction: String, Codable, Sendable {
    case start
    case stop
    case restart
    case approvePairing = "approve-pairing"
    case rejectPairing = "reject-pairing"
    case approveConnection = "approve-connection"
    case rejectConnection = "reject-connection"

    /// Deep link the widget button opens; the app routes it in `onOpenURL`.
    public var url: URL {
        URL(string: "\(HostWidgetConstants.urlScheme)://\(HostWidgetConstants.urlActionHost)/\(rawValue)")!
    }

    /// Parse an action from an incoming Vamp or legacy compatibility URL.
    public static func from(url: URL) -> HostWidgetAction? {
        guard (url.scheme == HostWidgetConstants.urlScheme || url.scheme == HostWidgetConstants.legacyURLScheme),
              url.host == HostWidgetConstants.urlActionHost else { return nil }
        let raw = url.lastPathComponent
        return HostWidgetAction(rawValue: raw)
    }
}

/// Reads and writes the host status snapshot used by the UI and agent CLI.
public enum HostWidgetStore {
    /// Signed widget builds use their App Group. The account-independent website
    /// build has no Apple team entitlement and uses an ordinary app support folder.
    private static func containerURL(namespace: String? = nil) -> URL? {
        // An unsigned direct-download build can still see an old on-disk App Group
        // container even though it has no application-groups entitlement. Use the
        // shared container only for sandboxed builds; otherwise keep state isolated
        // in the Vamp Host Application Support directory.
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
           var url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: HostWidgetConstants.appGroup) {
            if let namespace, !namespace.isEmpty {
                url.appendPathComponent(namespace, isDirectory: true)
            }
            return url
        }
        var url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        if let namespace, !namespace.isEmpty {
            url.appendPathComponent(namespace, isDirectory: true)
        } else {
            url.appendPathComponent("Vamp Host", isDirectory: true)
        }
        return url
    }

    private static func fileURL(_ name: String, namespace: String? = nil) -> URL? {
        guard let dir = containerURL(namespace: namespace) else { return nil }
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: Snapshot

    public static func save(_ snapshot: HostWidgetSnapshot, namespace: String? = nil) {
        guard let url = fileURL(HostWidgetConstants.snapshotKey + ".json", namespace: namespace),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func loadSnapshot(namespace: String? = nil) -> HostWidgetSnapshot? {
        guard let url = fileURL(HostWidgetConstants.snapshotKey + ".json", namespace: namespace),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(HostWidgetSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    // MARK: Pending action (widget -> app)

    public static func setPendingAction(_ action: HostWidgetAction, namespace: String? = nil) {
        guard let url = fileURL(HostWidgetConstants.pendingActionKey + ".json", namespace: namespace) else { return }
        try? Data(action.rawValue.utf8).write(to: url, options: .atomic)
    }

    /// Returns and clears the pending action, if any.
    public static func consumePendingAction(namespace: String? = nil) -> HostWidgetAction? {
        guard let url = fileURL(HostWidgetConstants.pendingActionKey + ".json", namespace: namespace),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8),
              let action = HostWidgetAction(rawValue: raw)
        else { return nil }
        try? FileManager.default.removeItem(at: url)
        return action
    }

    private struct PendingTrustApproval: Codable {
        var fingerprint: String
        var createdAt: TimeInterval
    }

    public static func setPendingTrustApproval(fingerprint: String, namespace: String? = nil) {
        let normalized = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64,
              normalized.allSatisfy(\.isHexDigit) else { return }
        guard let url = fileURL(HostWidgetConstants.pendingTrustKey + ".json", namespace: namespace) else { return }
        let payload = PendingTrustApproval(fingerprint: normalized, createdAt: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Returns and clears a fingerprint written by `vamp` if it is fresh.
    public static func consumePendingTrustApproval(namespace: String? = nil) -> String? {
        guard let url = fileURL(HostWidgetConstants.pendingTrustKey + ".json", namespace: namespace),
              let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let payload = try? JSONDecoder().decode(PendingTrustApproval.self, from: data)
        else { return nil }
        guard Date().timeIntervalSince1970 - payload.createdAt <= 60 else { return nil }
        let fingerprint = payload.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard fingerprint.count == 64, fingerprint.allSatisfy(\.isHexDigit) else { return nil }
        return fingerprint
    }
}
