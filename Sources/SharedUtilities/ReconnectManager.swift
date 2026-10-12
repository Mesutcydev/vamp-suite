import Foundation
import SharedModels

/// The reconnect manager's state, visible to UI layers.
public enum ReconnectPhase: String, Sendable, Hashable, CaseIterable {
    /// No reconnect in progress; connected or idle.
    case connected
    /// Connection was lost; evaluating whether to reconnect.
    case evaluating
    /// Actively attempting to reconnect (includes attempt number).
    case reconnecting
    /// Waiting for the backoff delay before the next attempt.
    case waitingToRetry
    /// All retry attempts exhausted.
    case gaveUp
}

/// Snapshot of reconnect state for UI display.
public struct ReconnectStatus: Sendable, Hashable {
    public var phase: ReconnectPhase
    public var attempt: Int
    public var maxAttempts: Int
    public var nextRetryDelay: TimeInterval?
    public var lastError: String?
    public var lastConnectedHostName: String?

    public init(
        phase: ReconnectPhase = .connected,
        attempt: Int = 0,
        maxAttempts: Int = 10,
        nextRetryDelay: TimeInterval? = nil,
        lastError: String? = nil,
        lastConnectedHostName: String? = nil
    ) {
        self.phase = phase
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.nextRetryDelay = nextRetryDelay
        self.lastError = lastError
        self.lastConnectedHostName = lastConnectedHostName
    }
}

/// Protocol that the reconnect manager calls to actually perform reconnect operations.
/// Implemented by the app layer (client or host).
public protocol ReconnectDelegate: AnyObject, Sendable {
    /// Attempt to re-establish the session. Throw on failure.
    func performReconnect(attempt: Int) async throws

    /// Called when reconnect succeeds.
    func reconnectDidSucceed() async

    /// Called when all attempts are exhausted.
    func reconnectDidGiveUp(after attempts: Int) async

    /// Called when reconnect phase changes (for logging / event store).
    func reconnectPhaseDidChange(_ phase: ReconnectPhase, attempt: Int) async
}

/// Manages reconnection attempts with exponential backoff.
/// Fully `@MainActor` so UI state updates are safe.
///
/// Usage:
/// 1. Create with a `ReconnectBackoff.Configuration` and a delegate.
/// 2. Call `connectionLost(reason:hostName:)` when a disconnect is detected.
/// 3. The manager will automatically retry via the delegate.
/// 4. Call `connectionRestored()` on successful reconnect.
/// 5. Call `cancel()` or `reset()` to stop.
@MainActor
public final class ReconnectManager: ObservableObject {

    @Published public private(set) var status: ReconnectStatus

    public var backoff: ReconnectBackoff
    private weak var delegate: (any ReconnectDelegate)?
    private var retryTask: Task<Void, Never>?

    public init(
        configuration: ReconnectBackoff.Configuration = ReconnectBackoff.Configuration(),
        delegate: (any ReconnectDelegate)? = nil
    ) {
        self.backoff = ReconnectBackoff(configuration: configuration)
        self.delegate = delegate
        self.status = ReconnectStatus(maxAttempts: configuration.maxAttempts)
    }

    public func setDelegate(_ delegate: any ReconnectDelegate) {
        self.delegate = delegate
    }

    // MARK: - Trigger

    /// Call when connection is lost. Begins the reconnect loop.
    public func connectionLost(reason: String? = nil, hostName: String? = nil) {
        guard status.phase == .connected else { return }
        backoff.reset()
        status.phase = .evaluating
        status.lastError = reason
        if let hostName { status.lastConnectedHostName = hostName }
        Task { await delegate?.reconnectPhaseDidChange(.evaluating, attempt: 0) }
        startRetryLoop()
    }

    /// Call when the connection is restored externally (e.g., by the session itself).
    public func connectionRestored() {
        retryTask?.cancel()
        retryTask = nil
        backoff.reset()
        status = ReconnectStatus(
            phase: .connected,
            maxAttempts: backoff.configuration.maxAttempts,
            lastConnectedHostName: status.lastConnectedHostName
        )
        Task { await delegate?.reconnectDidSucceed() }
    }

    /// Cancel all retry attempts and go to gaveUp.
    public func cancel() {
        retryTask?.cancel()
        retryTask = nil
        if status.phase != .connected {
            status.phase = .gaveUp
            status.lastError = "Cancelled by user"
            Task { await delegate?.reconnectDidGiveUp(after: backoff.attempt) }
        }
    }

    /// Full reset to connected state.
    public func reset() {
        retryTask?.cancel()
        retryTask = nil
        backoff.reset()
        status = ReconnectStatus(maxAttempts: backoff.configuration.maxAttempts)
    }

    // MARK: - Retry Loop

    private func startRetryLoop() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled && !self.backoff.isExhausted {
                // Wait for backoff delay
                let delay = self.backoff.currentDelay
                self.status.phase = .waitingToRetry
                self.status.nextRetryDelay = delay
                self.status.attempt = self.backoff.attempt
                await self.delegate?.reconnectPhaseDidChange(.waitingToRetry, attempt: self.backoff.attempt)

                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return // Cancelled
                }

                guard !Task.isCancelled else { return }

                // Attempt reconnect
                self.status.phase = .reconnecting
                self.status.attempt = self.backoff.attempt + 1
                await self.delegate?.reconnectPhaseDidChange(.reconnecting, attempt: self.backoff.attempt + 1)

                do {
                    try await self.delegate?.performReconnect(attempt: self.backoff.attempt + 1)
                    // Success
                    self.connectionRestored()
                    return
                } catch {
                    self.backoff.recordFailure()
                    self.status.lastError = error.localizedDescription
                }
            }

            // Exhausted
            if !Task.isCancelled {
                self.status.phase = .gaveUp
                await self.delegate?.reconnectDidGiveUp(after: self.backoff.attempt)
            }
        }
    }
}
