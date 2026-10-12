import Foundation
import os

enum CrashSafeStartupDiagnostics {
    private static let logger = Logger(subsystem: "com.mesutcy.remotedesktop.terminal", category: "Startup")

    static func mark(_ event: String, details: String? = nil) {
        if let details, !details.isEmpty {
            logger.info("[startup] \(event, privacy: .public) | \(details, privacy: .public)")
        } else {
            logger.info("[startup] \(event, privacy: .public)")
        }
    }

    static func error(_ event: String, error: Error) {
        logger.error("[startup] \(event, privacy: .public) | error=\(error.localizedDescription, privacy: .public)")
    }

    static func fault(_ event: String, message: String) {
        logger.fault("[startup] \(event, privacy: .public) | \(message, privacy: .public)")
    }
}
