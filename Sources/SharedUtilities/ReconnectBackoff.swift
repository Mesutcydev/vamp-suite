import Foundation

/// Pure-logic exponential backoff calculator. Fully testable, no side effects.
public struct ReconnectBackoff: Sendable, Hashable {

    /// Configuration for backoff behavior.
    public struct Configuration: Sendable, Hashable {
        public var baseDelay: TimeInterval
        public var maxDelay: TimeInterval
        public var multiplier: Double
        public var jitterFraction: Double
        public var maxAttempts: Int

        public init(
            baseDelay: TimeInterval = 1.0,
            maxDelay: TimeInterval = 30.0,
            multiplier: Double = 2.0,
            jitterFraction: Double = 0.15,
            maxAttempts: Int = 10
        ) {
            self.baseDelay = baseDelay
            self.maxDelay = maxDelay
            self.multiplier = multiplier
            self.jitterFraction = jitterFraction
            self.maxAttempts = maxAttempts
        }
    }

    public private(set) var attempt: Int = 0
    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Core Logic

    /// Compute the delay for the current attempt number (without jitter).
    /// Formula: min(baseDelay * multiplier^attempt, maxDelay)
    public func delay(for attempt: Int) -> TimeInterval {
        guard attempt >= 0 else { return configuration.baseDelay }
        let raw = configuration.baseDelay * pow(configuration.multiplier, Double(attempt))
        return min(raw, configuration.maxDelay)
    }

    /// Compute the delay with deterministic jitter applied.
    /// Jitter range: [delay * (1 - jitterFraction), delay * (1 + jitterFraction)]
    public func delayWithJitter(for attempt: Int, randomSeed: Double = 0.5) -> TimeInterval {
        let base = delay(for: attempt)
        let jitter = base * configuration.jitterFraction
        // randomSeed in [0, 1] → maps to [-jitter, +jitter]
        let offset = jitter * (2.0 * randomSeed - 1.0)
        return max(0, base + offset)
    }

    /// The delay for the current attempt.
    public var currentDelay: TimeInterval {
        delay(for: attempt)
    }

    /// Whether the maximum number of attempts has been reached.
    public var isExhausted: Bool {
        attempt >= configuration.maxAttempts
    }

    /// Whether any attempts have been made.
    public var hasAttempted: Bool {
        attempt > 0
    }

    // MARK: - Mutation

    /// Record a failed attempt and advance the counter.
    public mutating func recordFailure() {
        attempt += 1
    }

    /// Reset the backoff state (e.g., after a successful reconnect).
    public mutating func reset() {
        attempt = 0
    }

    // MARK: - Convenience

    /// Sequence of delays for all attempts up to maxAttempts.
    public var allDelays: [TimeInterval] {
        (0..<configuration.maxAttempts).map { delay(for: $0) }
    }
}
