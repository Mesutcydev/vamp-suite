import Foundation
import SharedModels
import os

/// Connection-loss debugger shared by the host and client apps.
///
/// Records a rolling timeline of connection-related signals (connection state,
/// data-channel state, network path, quality, lifecycle markers). When the
/// connection drops, `connectionLost(reason:metadata:)` dumps a report combining
/// the recent timeline with a live snapshot of transport counters, so "why did it
/// drop" can be answered after the fact from the in-app event log or Console.app
/// (`log stream --predicate 'category CONTAINS "ConnDebug"'`).
@MainActor
public final class ConnectionDebugger {
    public struct Entry: Sendable {
        public let timestamp: Date
        public let signal: String
        public let value: String
        public let metadata: [String: String]
    }

    /// Live transport counters gathered at dump time (latency, frame counts, …).
    /// Set by the owning coordinator after construction.
    public var snapshotProvider: (() -> [String: String])?

    private let role: String
    private let eventLogStore: any EventLogStoreProtocol
    private let logger: Logger
    private let timelineLimit: Int
    private var timeline: [Entry] = []
    private var lastValueBySignal: [String: String] = [:]
    private var lastConnectedAt: Date?
    private var lastReportAt: Date?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public init(
        role: String,
        eventLogStore: any EventLogStoreProtocol,
        timelineLimit: Int = 200
    ) {
        self.role = role
        self.eventLogStore = eventLogStore
        self.timelineLimit = timelineLimit
        self.logger = Logger(subsystem: "com.remotedesktop.diagnostics", category: "ConnDebug-\(role)")
    }

    /// Record a signal transition. Consecutive duplicates per signal are dropped
    /// so periodic observers can call this unconditionally.
    public func record(_ signal: String, _ value: String, metadata: [String: String] = [:]) {
        guard lastValueBySignal[signal] != value else { return }
        lastValueBySignal[signal] = value

        if signal == "connection", value == "connected" {
            lastConnectedAt = Date()
        }

        let entry = Entry(timestamp: Date(), signal: signal, value: value, metadata: metadata)
        timeline.append(entry)
        if timeline.count > timelineLimit {
            timeline.removeFirst(timeline.count - timelineLimit)
        }

        let suffix = metadata.isEmpty
            ? ""
            : " [" + metadata.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ") + "]"
        logger.notice("\(signal, privacy: .public) → \(value, privacy: .public)\(suffix, privacy: .public)")

        Task {
            await eventLogStore.append(EventLogItem(
                severity: .debug,
                category: "ConnDebug",
                message: "[\(role)] \(signal) → \(value)",
                metadata: metadata
            ))
        }
    }

    /// Record a one-off lifecycle marker (always logged, never deduped).
    public func mark(_ message: String, metadata: [String: String] = [:]) {
        lastValueBySignal["lifecycle"] = nil
        record("lifecycle", message, metadata: metadata)
    }

    /// Dump a connection-lost report: live snapshot + the recent signal timeline.
    /// Rate-limited so a disconnect followed by an immediate failure produces one
    /// report, not two.
    public func connectionLost(reason: String, metadata: [String: String] = [:]) {
        if let last = lastReportAt, Date().timeIntervalSince(last) < 2 {
            return
        }
        lastReportAt = Date()

        var combined = metadata
        if let snapshot = snapshotProvider?() {
            combined.merge(snapshot) { current, _ in current }
        }
        if let connectedAt = lastConnectedAt {
            combined["uptimeSeconds"] = String(format: "%.1f", Date().timeIntervalSince(connectedAt))
        }
        combined["timeline"] = timelineText(maxEntries: 30)

        let summary = "CONNECTION LOST (\(role)): \(reason)"
        let detailLines = combined
            .sorted(by: { $0.key < $1.key })
            .filter { $0.key != "timeline" }
            .map { "  \($0.key) = \($0.value)" }
        logger.error("""
        \(summary, privacy: .public)
        \(detailLines.joined(separator: "\n"), privacy: .public)
        Recent timeline:
        \(combined["timeline"] ?? "(empty)", privacy: .public)
        """)

        Task {
            await eventLogStore.append(EventLogItem(
                severity: .error,
                category: "ConnDebug",
                message: summary,
                metadata: combined
            ))
        }
    }

    /// Recent timeline entries, newest last. Exposed for diagnostics UI.
    public func recentEntries() -> [Entry] {
        timeline
    }

    private func timelineText(maxEntries: Int) -> String {
        let entries = timeline.suffix(maxEntries)
        guard !entries.isEmpty else { return "(empty)" }
        return entries.map { entry in
            let time = Self.timeFormatter.string(from: entry.timestamp)
            let suffix = entry.metadata.isEmpty
                ? ""
                : " [" + entry.metadata.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ") + "]"
            return "\(time) \(entry.signal) → \(entry.value)\(suffix)"
        }.joined(separator: "\n")
    }
}
