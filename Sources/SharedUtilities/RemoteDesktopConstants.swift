import Foundation
import SharedModels

public enum RemoteDesktopConstants {
    public static let protocolVersion = 1
    public static let bonjourServiceType = "_screenharbor._tcp."
    public static let defaultSignalingPort: UInt16 = 9471
    public static let defaultDataPort: UInt16 = 9472
    public static let defaultTLSSignalingPort: UInt16 = 9473
    public static let eventLogLimit = 500

    // Timeouts
    public static let signalingConnectTimeout: TimeInterval = 10
    public static let manualSignalingConnectTimeout: TimeInterval = 30
    public static let negotiationTimeout: TimeInterval = 65  // Must exceed trustPromptTimeout so host can approve
    /// Negotiation ceiling for AUTOMATIC reconnects to an already-trusted host (no fresh
    /// trust prompt expected). Much shorter than `negotiationTimeout` so a stalled candidate
    /// advances the sweep quickly instead of freezing a reconnect for up to a minute.
    public static let reconnectNegotiationTimeout: TimeInterval = 15
    public static let trustPromptTimeout: TimeInterval = 60
    public static let reconnectMaxAttempts = 5

    // Streaming
    public static let targetFrameRate = 30
    public static let maxBitrateKbps = 8000
    public static let stallDetectionInterval: TimeInterval = 3
    public static let heartbeatInterval: TimeInterval = 5

    /// A host fingerprint is advertised as a lowercase SHA-256 hex digest. Keep this
    /// validation in the shared layer so listener startup and Bonjour metadata cannot
    /// disagree about whether TLS is available.
    public static func isValidPublicKeyFingerprint(_ value: String) -> Bool {
        PublicKeyFingerprint.isValid(value)
    }
}

public enum RemoteDesktopError: Error, LocalizedError {
    case timeout(String)
    case connectionFailed(String)
    case signalingFailed(String)
    case negotiationFailed(String)
    case pipelineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let ctx): return "Timeout: \(ctx)"
        case .connectionFailed(let ctx): return "Connection failed: \(ctx)"
        case .signalingFailed(let ctx): return "Signaling failed: \(ctx)"
        case .negotiationFailed(let ctx): return "Negotiation failed: \(ctx)"
        case .pipelineFailed(let ctx): return "Pipeline failed: \(ctx)"
        }
    }
}

public func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw RemoteDesktopError.timeout("Operation timed out after \(Int(seconds))s")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
