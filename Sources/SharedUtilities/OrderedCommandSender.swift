import Foundation

/// A bounded FIFO for discrete commands. Overflow fails the attachment explicitly;
/// it never evicts an older command (which may be a key or button release).
@MainActor
public final class OrderedCommandSender<Message: Sendable> {
    private var continuation: AsyncStream<Message>.Continuation?
    private var task: Task<Void, Never>?
    private var failed = false
    private let onFailure: (String) -> Void

    public init(
        capacity: Int = 1024,
        send: @escaping (Message) async throws -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.onFailure = onFailure
        let stream = AsyncStream<Message>(bufferingPolicy: .bufferingOldest(max(1, capacity))) {
            continuation = $0
        }
        task = Task { [weak self] in
            for await message in stream {
                guard !Task.isCancelled else { return }
                do { try await send(message) }
                catch {
                    self?.fail("Input could not be delivered: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    deinit {
        continuation?.finish()
        task?.cancel()
    }

    @discardableResult
    public func enqueue(_ message: Message) -> Bool {
        guard !failed, let continuation else { return false }
        switch continuation.yield(message) {
        case .enqueued: return true
        case .dropped:
            fail("The connection is too slow to deliver input safely. Reconnect to continue.")
        case .terminated: fail("The input connection has closed. Reconnect to continue.")
        @unknown default: fail("Input could not be queued. Reconnect to continue.")
        }
        return false
    }

    private func fail(_ reason: String) {
        guard !failed else { return }
        failed = true
        continuation?.finish()
        task?.cancel()
        onFailure(reason)
    }
}
