import Foundation
import SharedModels

public protocol EventLogExporting: Sendable {
    func export(
        items: [EventLogItem],
        destinationDirectory: URL,
        filePrefix: String
    ) throws -> URL
}

public struct EventLogExportService: EventLogExporting {
    public init() {}

    public func export(
        items: [EventLogItem],
        destinationDirectory: URL,
        filePrefix: String = "remote-desktop-event-log"
    ) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileURL = destinationDirectory
            .appendingPathComponent("\(filePrefix)-\(timestamp)")
            .appendingPathExtension("json")

        let payload = ExportPayload(
            exportedAt: formatter.string(from: Date()),
            items: items.map { ExportItem(item: $0, formatter: formatter) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}

private struct ExportPayload: Codable {
    var exportedAt: String
    var items: [ExportItem]
}

private struct ExportItem: Codable {
    var timestamp: String
    var severity: String
    var category: String
    var message: String
    var metadata: [String: String]

    init(item: EventLogItem, formatter: ISO8601DateFormatter) {
        self.timestamp = formatter.string(from: item.timestamp)
        self.severity = item.severity.rawValue
        self.category = item.category
        self.message = Self.redact(item.message)
        self.metadata = item.metadata.reduce(into: [:]) { partialResult, pair in
            partialResult[pair.key] = Self.redactMetadataValue(pair.key, value: pair.value)
        }
    }

    private static func redact(_ text: String) -> String {
        let patterns = [
            "(?i)(token|secret|password|fingerprint|sessionToken)=([^\\s,;]+)",
            "(?i)(bearer\\s+)([A-Za-z0-9._\\-]+)",
            "(?i)(key\\s*:\\s*)([A-Za-z0-9._\\-]+)"
        ]

        return patterns.reduce(text) { partial, pattern in
            partial.replacingOccurrences(
                of: pattern,
                with: "$1[REDACTED]",
                options: .regularExpression
            )
        }
    }

    private static func redactMetadataValue(_ key: String, value: String) -> String {
        let lowercaseKey = key.lowercased()
        if lowercaseKey.contains("token")
            || lowercaseKey.contains("secret")
            || lowercaseKey.contains("password")
            || lowercaseKey.contains("fingerprint")
        {
            return "[REDACTED]"
        }
        return redact(value)
    }
}
