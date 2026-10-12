import Foundation

/// The lifecycle of a streamed agent plan. A plan is deliberately separate
/// from the VT screen: terminal repainting must never mutate these states.
public enum TaskPlanState: String, Codable, Hashable, Sendable {
    case planning
    case running
    case paused
    case completed
    case failed
    case cancelled
}

public enum SessionTaskStatus: String, Codable, Hashable, Sendable {
    case pending
    case running
    case completed
    case failed
    case skipped
}

public enum TaskSource: String, Codable, Hashable, Sendable {
    case native
    case adapter
    case inferred
}

public struct SessionTask: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var order: Int
    public var title: String
    public var detail: String?
    public var status: SessionTaskStatus
    public var failureReason: String?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        order: Int,
        title: String,
        detail: String? = nil,
        status: SessionTaskStatus = .pending,
        failureReason: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.order = order
        self.title = title
        self.detail = detail
        self.status = status
        self.failureReason = failureReason
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public struct SessionTaskPlan: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let terminalID: UUID
    public var title: String?
    public var tasks: [SessionTask]
    public var state: TaskPlanState
    public var source: TaskSource
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        terminalID: UUID,
        title: String? = nil,
        tasks: [SessionTask],
        state: TaskPlanState = .planning,
        source: TaskSource,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.title = title
        self.tasks = tasks.sorted { $0.order < $1.order }
        self.state = state
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var completedCount: Int {
        tasks.filter { $0.status == .completed || $0.status == .skipped }.count
    }

    /// Human progress is ordinal rather than percentage-based. A running task
    /// is the visible step; a completed plan reports its final total.
    public var progressPosition: Int {
        if let running = tasks.first(where: { $0.status == .running }) {
            return max(1, tasks.firstIndex(where: { $0.id == running.id }).map { $0 + 1 } ?? 1)
        }
        if state == .completed { return tasks.count }
        return min(tasks.count, max(1, completedCount + 1))
    }

    public var progressLabel: String {
        "\(progressPosition) of \(tasks.count)"
    }

    public var isActive: Bool {
        state == .planning || state == .running || state == .paused
    }
}

/// Incremental mutations are small so one task transition does not resend the
/// full plan or reset SwiftUI identity. The plan-created event is the only
/// event that carries the complete initial task list.
public enum SessionTaskEvent: Codable, Hashable, Sendable {
    case planCreated(SessionTaskPlan)
    case planUpdated(SessionTaskPlan)
    case taskAdded(SessionTask)
    case taskRemoved(UUID)
    case taskRenamed(id: UUID, title: String, detail: String?)
    case taskReordered(id: UUID, order: Int)
    case taskStarted(UUID)
    case taskCompleted(UUID)
    case taskFailed(id: UUID, reason: String?)
    case taskSkipped(UUID)
    case planPaused
    case planResumed
    case planCompleted
    case planFailed
    case planCancelled

    /// Full-plan events carry their own identity because they may be persisted
    /// or forwarded independently of the transport envelope. Consumers must
    /// verify both identities before applying them to a live tab.
    public func isBound(toSessionID sessionID: UUID, terminalID: UUID) -> Bool {
        switch self {
        case .planCreated(let plan), .planUpdated(let plan):
            return plan.sessionID == sessionID && plan.terminalID == terminalID
        case .taskAdded, .taskRemoved, .taskRenamed, .taskReordered,
             .taskStarted, .taskCompleted, .taskFailed, .taskSkipped,
             .planPaused, .planResumed, .planCompleted, .planFailed, .planCancelled:
            return true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, plan, task, id, title, detail, order, reason
    }

    private enum Kind: String, Codable {
        case planCreated, planUpdated, taskAdded, taskRemoved, taskRenamed
        case taskReordered, taskStarted, taskCompleted, taskFailed, taskSkipped
        case planPaused, planResumed, planCompleted, planFailed, planCancelled
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .planCreated(let plan):
            try container.encode(Kind.planCreated, forKey: .kind)
            try container.encode(plan, forKey: .plan)
        case .planUpdated(let plan):
            try container.encode(Kind.planUpdated, forKey: .kind)
            try container.encode(plan, forKey: .plan)
        case .taskAdded(let task):
            try container.encode(Kind.taskAdded, forKey: .kind)
            try container.encode(task, forKey: .task)
        case .taskRemoved(let id):
            try container.encode(Kind.taskRemoved, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .taskRenamed(let id, let title, let detail):
            try container.encode(Kind.taskRenamed, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(detail, forKey: .detail)
        case .taskReordered(let id, let order):
            try container.encode(Kind.taskReordered, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(order, forKey: .order)
        case .taskStarted(let id):
            try container.encode(Kind.taskStarted, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .taskCompleted(let id):
            try container.encode(Kind.taskCompleted, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .taskFailed(let id, let reason):
            try container.encode(Kind.taskFailed, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(reason, forKey: .reason)
        case .taskSkipped(let id):
            try container.encode(Kind.taskSkipped, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .planPaused:
            try container.encode(Kind.planPaused, forKey: .kind)
        case .planResumed:
            try container.encode(Kind.planResumed, forKey: .kind)
        case .planCompleted:
            try container.encode(Kind.planCompleted, forKey: .kind)
        case .planFailed:
            try container.encode(Kind.planFailed, forKey: .kind)
        case .planCancelled:
            try container.encode(Kind.planCancelled, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .planCreated: self = .planCreated(try container.decode(SessionTaskPlan.self, forKey: .plan))
        case .planUpdated: self = .planUpdated(try container.decode(SessionTaskPlan.self, forKey: .plan))
        case .taskAdded: self = .taskAdded(try container.decode(SessionTask.self, forKey: .task))
        case .taskRemoved: self = .taskRemoved(try container.decode(UUID.self, forKey: .id))
        case .taskRenamed:
            self = .taskRenamed(
                id: try container.decode(UUID.self, forKey: .id),
                title: try container.decode(String.self, forKey: .title),
                detail: try container.decodeIfPresent(String.self, forKey: .detail)
            )
        case .taskReordered:
            self = .taskReordered(
                id: try container.decode(UUID.self, forKey: .id),
                order: try container.decode(Int.self, forKey: .order)
            )
        case .taskStarted: self = .taskStarted(try container.decode(UUID.self, forKey: .id))
        case .taskCompleted: self = .taskCompleted(try container.decode(UUID.self, forKey: .id))
        case .taskFailed:
            self = .taskFailed(
                id: try container.decode(UUID.self, forKey: .id),
                reason: try container.decodeIfPresent(String.self, forKey: .reason)
            )
        case .taskSkipped: self = .taskSkipped(try container.decode(UUID.self, forKey: .id))
        case .planPaused: self = .planPaused
        case .planResumed: self = .planResumed
        case .planCompleted: self = .planCompleted
        case .planFailed: self = .planFailed
        case .planCancelled: self = .planCancelled
        }
    }
}

/// Host/client transport for semantic plan events. It is intentionally not a
/// terminal-output message: consumers must route it by both session and tab.
public struct SessionTaskEventMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let terminalID: UUID
    public let event: SessionTaskEvent
    /// Monotonic host journal sequence (step D). Lets a reconnecting client
    /// dedupe live events against its last-applied baseline. 0 when the host
    /// predates sequencing (or the event was never journaled).
    public var journalSequence: UInt64

    public init(sessionID: UUID, terminalID: UUID, event: SessionTaskEvent, journalSequence: UInt64 = 0) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.event = event
        self.journalSequence = journalSequence
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, terminalID, event, journalSequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        terminalID = try container.decode(UUID.self, forKey: .terminalID)
        event = try container.decode(SessionTaskEvent.self, forKey: .event)
        journalSequence = try container.decodeIfPresent(UInt64.self, forKey: .journalSequence) ?? 0
    }
}

/// Pure reducer used by iOS, host adapters, and tests. It owns task identity
/// and never reads terminal cells or PTY repaint output.
public struct SessionTaskCoordinator: Codable, Hashable, Sendable {
    public private(set) var plan: SessionTaskPlan?

    public init(plan: SessionTaskPlan? = nil) {
        self.plan = plan
    }

    @discardableResult
    public mutating func apply(_ event: SessionTaskEvent) -> SessionTaskPlan? {
        switch event {
        case .planCreated(let value), .planUpdated(let value):
            plan = value
        case .taskAdded(let task):
            guard var value = plan, !value.tasks.contains(where: { $0.id == task.id }) else { return plan }
            value.tasks.append(task)
            value.tasks.sort { $0.order < $1.order }
            value.updatedAt = .now
            plan = value
        case .taskRemoved(let id):
            guard var value = plan else { return nil }
            value.tasks.removeAll { $0.id == id }
            value.updatedAt = .now
            plan = value
        case .taskRenamed(let id, let title, let detail):
            updateTask(id) { $0.title = title; $0.detail = detail }
        case .taskReordered(let id, let order):
            updateTask(id) { $0.order = order }
            plan?.tasks.sort { $0.order < $1.order }
        case .taskStarted(let id):
            updateTask(id) { task in
                task.status = .running
                task.failureReason = nil
                task.startedAt = task.startedAt ?? .now
                task.completedAt = nil
            }
            plan?.state = .running
        case .taskCompleted(let id):
            updateTask(id) { task in
                task.status = .completed
                task.failureReason = nil
                task.completedAt = task.completedAt ?? .now
            }
            if let plan, plan.tasks.allSatisfy({ $0.status == .completed || $0.status == .skipped }) {
                self.plan?.state = .completed
            } else {
                self.plan?.state = .running
            }
        case .taskFailed(let id, let reason):
            updateTask(id) { task in
                task.status = .failed
                task.failureReason = reason.map { String($0.prefix(500)) }
                task.completedAt = nil
            }
            plan?.state = .failed
        case .taskSkipped(let id):
            updateTask(id) { task in
                task.status = .skipped
                task.failureReason = nil
                task.completedAt = task.completedAt ?? .now
            }
            if let plan, plan.tasks.allSatisfy({ $0.status == .completed || $0.status == .skipped }) {
                self.plan?.state = .completed
            }
        case .planPaused: plan?.state = .paused
        case .planResumed: plan?.state = .running
        case .planCompleted: plan?.state = .completed
        case .planFailed: plan?.state = .failed
        case .planCancelled: plan?.state = .cancelled
        }
        if plan != nil { plan?.updatedAt = .now }
        return plan
    }

    private mutating func updateTask(_ id: UUID, _ update: (inout SessionTask) -> Void) {
        guard var value = plan, let index = value.tasks.firstIndex(where: { $0.id == id }) else { return }
        update(&value.tasks[index])
        value.updatedAt = .now
        plan = value
    }
}

/// Conservative fallback for stable semantic agent blocks. Callers must pass
/// a block from an agent adapter, never the VT screen or a terminal packet.
public enum SessionTaskPlanDetector {
    public static func infer(
        from semanticText: String,
        sessionID: UUID,
        terminalID: UUID,
        title: String? = nil
    ) -> SessionTaskPlan? {
        guard !semanticText.contains("\u{1B}") else { return nil }
        let lines = semanticText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }

        var parsed: [(Int, String, SessionTaskStatus)] = []
        var sawChecklist = false
        for line in lines {
            if let numbered = parseNumbered(line) {
                parsed.append((numbered.number, numbered.title, .pending))
            } else if let checklist = parseChecklist(line) {
                sawChecklist = true
                parsed.append((0, checklist.title, checklist.status))
            }
        }
        guard parsed.count >= 2 else { return nil }
        let numbers = parsed.map { $0.0 }
        let isChecklist = sawChecklist && parsed.allSatisfy { $0.0 == 0 }
        let isSequential = !sawChecklist && numbers == Array(1...parsed.count)
        let lowercased = semanticText.lowercased()
        let hasPlanMarker = lowercased.range(of: #"\b(plan|steps|checklist|todo|implementation)\b"#, options: .regularExpression) != nil
        // Two numbered paragraphs are common prose. Require an explicit plan
        // marker unless the agent used a checklist syntax, which is already a
        // strong task-plan signal.
        guard isSequential || isChecklist,
              isChecklist || hasPlanMarker else { return nil }
        let tasks = parsed.enumerated().map { index, item in
            SessionTask(order: index + 1, title: String(item.1.prefix(240)), status: item.2)
        }
        return SessionTaskPlan(
            sessionID: sessionID,
            terminalID: terminalID,
            title: title ?? "Inferred plan",
            tasks: tasks,
            state: tasks.contains(where: { $0.status == .completed }) ? .running : .planning,
            source: .inferred
        )
    }

    private static func parseNumbered(_ line: String) -> (number: Int, title: String)? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index].isNumber { index += 1 }
        guard index > 0, index < characters.count,
              characters[index] == "." || characters[index] == ")" else { return nil }
        let number = Int(String(characters[..<index])) ?? 0
        let remainder = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)
        guard number > 0, remainder.count >= 4, !remainder.hasPrefix("http") else { return nil }
        return (number, remainder)
    }

    private static func parseChecklist(_ line: String) -> (title: String, status: SessionTaskStatus)? {
        guard line.hasPrefix("- [") || line.hasPrefix("* [") else { return nil }
        let chars = Array(line)
        guard chars.count > 6, chars[0] == "-" || chars[0] == "*", chars[2] == "[", chars[4] == "]" else { return nil }
        let status: SessionTaskStatus = (chars[3] == "x" || chars[3] == "X") ? .completed : .pending
        let title = String(chars.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard title.count >= 4 else { return nil }
        return (title, status)
    }
}
