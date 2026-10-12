import Foundation

/// Provider-native semantic events emitted before terminal rendering. These
/// events are intentionally independent from VT cells: an alternate-screen
/// repaint can never become a Chat message or mutate a task plan.
public enum ProviderSemanticEvent: Codable, Equatable, Sendable {
    case messageDelta(String)
    case thinkingDelta(String)
    case taskPlan(SessionTaskEvent)
    case permissionRequested(String?)
    case sessionIdentifier(String)
    case completed
    case failed(String?)
}

public extension ProviderSemanticEvent {
    /// True only for events that conclusively end the current provider turn.
    /// Task-plan completion is deliberately separate: an agent may finish a
    /// plan and continue writing its final response.
    var isTerminalProviderEvent: Bool {
        switch self {
        case .completed, .failed: true
        default: false
        }
    }
}

public enum AgentProviderKind: String, Codable, CaseIterable, Sendable {
    case grok
    case openCode
    case claude
    case codex
    case pi
    case commandCode
    case kimi
    case qwen
    case aider
    case gemini
}

/// A Chat submission routed to a provider's machine-readable runner. The
/// provider process is separate from the tab's PTY/TUI, while both remain
/// bound to the same authenticated session, terminal and workspace.
public struct AgentPromptMessage: Codable, Equatable, Sendable {
    public static let maxPromptBytes = 64 * 1024
    public let sessionID: UUID
    public let terminalID: UUID
    public let provider: AgentProviderKind
    public let prompt: String
    public let workingDirectory: String?

    public init(sessionID: UUID, terminalID: UUID, provider: AgentProviderKind, prompt: String, workingDirectory: String?) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.provider = provider
        self.prompt = prompt
        self.workingDirectory = workingDirectory
    }
}

public struct ProviderSemanticEventMessage: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let terminalID: UUID
    public let provider: AgentProviderKind
    public let event: ProviderSemanticEvent
    /// Monotonic host journal sequence (step D). Lets a reconnecting client
    /// dedupe live events against its last-applied baseline. 0 when the host
    /// predates sequencing (or the event was never journaled).
    public var journalSequence: UInt64

    public init(sessionID: UUID, terminalID: UUID, provider: AgentProviderKind, event: ProviderSemanticEvent, journalSequence: UInt64 = 0) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.provider = provider
        self.event = event
        self.journalSequence = journalSequence
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, terminalID, provider, event, journalSequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        terminalID = try container.decode(UUID.self, forKey: .terminalID)
        provider = try container.decode(AgentProviderKind.self, forKey: .provider)
        event = try container.decode(ProviderSemanticEvent.self, forKey: .event)
        journalSequence = try container.decodeIfPresent(UInt64.self, forKey: .journalSequence) ?? 0
    }
}

public protocol ProviderSemanticAdapter: AnyObject, Sendable {
    func consume(_ data: Data, sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent]
    func finish(sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent]
}

/// Incremental NDJSON framing shared by all provider adapters. JSON objects,
/// UTF-8 scalars, and escape sequences may span arbitrary pipe/read chunks.
final class NDJSONFramer: @unchecked Sendable {
    private var bytes = Data()

    func append(_ data: Data) -> [[String: Any]] {
        bytes.append(data)
        var values: [[String: Any]] = []
        while let newline = bytes.firstIndex(of: 0x0A) {
            let line = bytes[..<newline]
            bytes.removeSubrange(...newline)
            if let value = Self.decode(Data(line)) { values.append(value) }
        }
        return values
    }

    func flush() -> [[String: Any]] {
        defer { bytes.removeAll(keepingCapacity: true) }
        guard let value = Self.decode(bytes) else { return [] }
        return [value]
    }

    private static func decode(_ data: Data) -> [String: Any]? {
        let trimmed = data.drop { $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }
        guard !trimmed.isEmpty,
              let value = try? JSONSerialization.jsonObject(with: Data(trimmed)),
              let object = value as? [String: Any] else { return nil }
        return object
    }
}

class BaseProviderAdapter: @unchecked Sendable {
    let framer = NDJSONFramer()
    private var taskIDs: [String: UUID] = [:]
    private var currentPlanID: UUID?
    private var currentTasks: [SessionTask] = []
    private var lastSessionIdentifier: String?

    func sessionIdentifierEvent(_ value: String?) -> ProviderSemanticEvent? {
        guard let value, !value.isEmpty, value != lastSessionIdentifier else { return nil }
        lastSessionIdentifier = value
        return .sessionIdentifier(value)
    }

    func taskID(_ externalID: String?, fallbackKey: String) -> UUID {
        if let externalID, let existing = taskIDs[externalID] {
            taskIDs[fallbackKey] = existing
            return existing
        }
        if let existing = taskIDs[fallbackKey] {
            if let externalID { taskIDs[externalID] = existing }
            return existing
        }
        let value = UUID()
        taskIDs[fallbackKey] = value
        if let externalID { taskIDs[externalID] = value }
        return value
    }

    func planEvents(
        from object: [String: Any],
        sessionID: UUID,
        terminalID: UUID
    ) -> [ProviderSemanticEvent] {
        guard let payload = Self.taskPayload(in: object) else { return [] }
        let parsed = Self.taskRows(from: payload)
        guard !parsed.isEmpty else { return [] }

        var tasks: [SessionTask] = []
        for (index, row) in parsed.enumerated() {
            let fallbackKey = "\(index):\(row.title)"
            tasks.append(SessionTask(
                id: taskID(row.id, fallbackKey: fallbackKey),
                order: index + 1,
                title: row.title,
                detail: row.detail,
                status: row.status
            ))
        }
        let state: TaskPlanState = tasks.allSatisfy { $0.status == .completed || $0.status == .skipped }
            ? .completed
            : .running
        guard tasks != currentTasks || currentPlanID == nil else { return [] }
        let plan = SessionTaskPlan(
            id: currentPlanID ?? UUID(),
            sessionID: sessionID,
            terminalID: terminalID,
            title: "Agent plan",
            tasks: tasks,
            state: state,
            source: .adapter
        )
        let event: SessionTaskEvent = currentPlanID == nil ? .planCreated(plan) : .planUpdated(plan)
        currentPlanID = plan.id
        currentTasks = tasks
        return [.taskPlan(event)]
    }

    private struct TaskRow {
        var id: String?
        var title: String
        var detail: String?
        var status: SessionTaskStatus
    }

    private static func taskPayload(in value: Any) -> Any? {
        if let object = value as? [String: Any] {
            let type = string(object["type"])?.lowercased() ?? ""
            let name = string(object["name"])?.lowercased()
                ?? string(object["tool"])?.lowercased()
                ?? string(object["tool_name"])?.lowercased()
                ?? string(object["toolName"])?.lowercased()
                ?? string(nested(object, "function", "name"))?.lowercased()
                ?? ""
            let subtype = string(object["subtype"])?.lowercased() ?? ""
            let isTaskEvent = [type, name, subtype].contains { token in
                token.contains("todo") || token.contains("task") || token.contains("plan")
            }
            if isTaskEvent {
                for key in ["tasks", "todos", "entries", "plan", "input", "arguments", "rawInput", "rawOutput", "state", "metadata", "data", "content", "part", "item"] {
                    if let candidate = object[key], !taskRows(from: candidate).isEmpty { return candidate }
                }
                if !taskRows(from: object).isEmpty { return object }
            }
            for key in ["event", "part", "item", "message", "data", "sessionUpdate", "update", "rawInput", "rawOutput", "state", "metadata", "input", "output", "content"] {
                if let nested = object[key], let result = taskPayload(in: nested) { return result }
            }
        } else if let array = value as? [Any] {
            for nested in array where taskPayload(in: nested) != nil { return nested }
        }
        return nil
    }

    private static func taskRows(from value: Any) -> [TaskRow] {
        if let array = value as? [Any] {
            return array.compactMap(taskRow)
        }
        if let object = value as? [String: Any] {
            for key in ["tasks", "todos", "items", "entries", "steps", "plan", "state", "input", "metadata"] {
                if let nested = object[key] {
                    let rows = taskRows(from: nested)
                    if !rows.isEmpty { return rows }
                }
            }
            if let row = taskRow(object) { return [row] }
        }
        return []
    }

    private static func taskRow(_ value: Any) -> TaskRow? {
        if let title = value as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return TaskRow(id: nil, title: title, detail: nil, status: .pending)
        }
        guard let object = value as? [String: Any] else { return nil }
        let title = string(object["title"])
            ?? string(object["content"])
            ?? string(object["text"])
            ?? string(object["description"])
            ?? string(object["subject"])
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let rawStatus = (string(object["status"]) ?? string(object["state"]) ?? "pending").lowercased()
        let status: SessionTaskStatus
        if (object["completed"] as? Bool) == true || rawStatus.contains("complete") || rawStatus == "done" { status = .completed }
        else if rawStatus.contains("progress") || rawStatus.contains("running") || rawStatus == "active" { status = .running }
        else if rawStatus.contains("fail") || rawStatus.contains("error") { status = .failed }
        else if rawStatus.contains("skip") || rawStatus.contains("cancel") { status = .skipped }
        else { status = .pending }
        return TaskRow(
            id: string(object["id"]) ?? string(object["task_id"]) ?? string(object["taskId"]),
            title: title,
            detail: string(object["detail"]) ?? string(object["activeForm"]),
            status: status
        )
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return nil
        }
    }

    static func nested(_ object: [String: Any], _ path: String...) -> Any? {
        var value: Any = object
        for component in path {
            guard let dictionary = value as? [String: Any], let next = dictionary[component] else { return nil }
            value = next
        }
        return value
    }
}

public final class GrokAdapter: ProviderSemanticAdapter, @unchecked Sendable {
    private let base = BaseProviderAdapter()
    public init() {}

    public func consume(_ data: Data, sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.append(data).flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }

    public func finish(sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.flush().flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }

    private func parse(_ object: [String: Any], sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        var events = base.planEvents(from: object, sessionID: sessionID, terminalID: terminalID)
        switch BaseProviderAdapter.string(object["type"])?.lowercased() {
        case "text": if let text = BaseProviderAdapter.string(object["data"]) { events.append(.messageDelta(text)) }
        case "thought", "thinking": if let text = BaseProviderAdapter.string(object["data"]) { events.append(.thinkingDelta(text)) }
        case "end":
            if let event = base.sessionIdentifierEvent(BaseProviderAdapter.string(object["sessionId"])) { events.append(event) }
            events.append(.completed)
        case "error": events.append(.failed(BaseProviderAdapter.string(object["message"]) ?? BaseProviderAdapter.string(object["data"])))
        default: break
        }
        return events
    }
}

public final class OpenCodeAdapter: ProviderSemanticAdapter, @unchecked Sendable {
    private let base = BaseProviderAdapter()
    private var didCompleteTurn = false
    public init() {}
    public func consume(_ data: Data, sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.append(data).flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }
    public func finish(sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.flush().flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }
    private func parse(_ object: [String: Any], sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        var events = base.planEvents(from: object, sessionID: sessionID, terminalID: terminalID)
        let type = BaseProviderAdapter.string(object["type"])?.lowercased()
        if let event = base.sessionIdentifierEvent(BaseProviderAdapter.string(object["sessionID"])) { events.append(event) }
        if type == "text", let text = BaseProviderAdapter.string(BaseProviderAdapter.nested(object, "part", "text")) { events.append(.messageDelta(text)) }
        if type == "reasoning", let text = BaseProviderAdapter.string(BaseProviderAdapter.nested(object, "part", "text")) { events.append(.thinkingDelta(text)) }
        if type == "step_finish",
           BaseProviderAdapter.string(BaseProviderAdapter.nested(object, "part", "reason"))?.lowercased() == "stop",
           !didCompleteTurn {
            didCompleteTurn = true
            events.append(.completed)
        }
        if type == "error" { events.append(.failed(BaseProviderAdapter.string(object["error"]) ?? BaseProviderAdapter.string(object["message"]))) }
        return events
    }
}

public final class ClaudeAdapter: ProviderSemanticAdapter, @unchecked Sendable {
    private let base = BaseProviderAdapter()
    private var didEmitMessage = false
    private struct ClaudeTask {
        var title: String
        var status: String
    }
    private var taskOrder: [String] = []
    private var tasks: [String: ClaudeTask] = [:]
    public init() {}
    public func consume(_ data: Data, sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.append(data).flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }
    public func finish(sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.flush().flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }
    private func parse(_ object: [String: Any], sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        var events = base.planEvents(from: object, sessionID: sessionID, terminalID: terminalID)
        if let result = object["tool_use_result"] as? [String: Any] {
            if let task = result["task"] as? [String: Any],
               let id = BaseProviderAdapter.string(task["id"]),
               let title = BaseProviderAdapter.string(task["subject"]) ?? BaseProviderAdapter.string(task["title"]) {
                if tasks[id] == nil { taskOrder.append(id) }
                tasks[id] = ClaudeTask(title: title, status: BaseProviderAdapter.string(task["status"]) ?? "pending")
                events += taskPlanEvents(sessionID: sessionID, terminalID: terminalID)
            } else if let id = BaseProviderAdapter.string(result["taskId"]),
                      let status = BaseProviderAdapter.string(BaseProviderAdapter.nested(result, "statusChange", "to")) {
                if var task = tasks[id] {
                    task.status = status
                    tasks[id] = task
                    events += taskPlanEvents(sessionID: sessionID, terminalID: terminalID)
                }
            }
        }
        if let event = base.sessionIdentifierEvent(BaseProviderAdapter.string(object["session_id"])) { events.append(event) }
        let type = BaseProviderAdapter.string(object["type"])?.lowercased()
        let deltaType = BaseProviderAdapter.string(BaseProviderAdapter.nested(object, "event", "delta", "type"))?.lowercased()
        if deltaType == "text_delta", let text = BaseProviderAdapter.string(BaseProviderAdapter.nested(object, "event", "delta", "text")) {
            didEmitMessage = true
            events.append(.messageDelta(text))
        } else if deltaType == "thinking_delta", let text = BaseProviderAdapter.string(BaseProviderAdapter.nested(object, "event", "delta", "thinking")) {
            events.append(.thinkingDelta(text))
        }
        if type == "result" {
            if (object["is_error"] as? Bool) == true { events.append(.failed(BaseProviderAdapter.string(object["result"]))) }
            else {
                // Some Claude versions emit only a final `result` record even
                // when stream-json was requested. Preserve streaming deltas
                // when available, but use the final result as an honest
                // fallback so Chat never completes with an empty reply.
                if !didEmitMessage,
                   let result = BaseProviderAdapter.string(object["result"]),
                   !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    didEmitMessage = true
                    events.append(.messageDelta(result))
                }
                events.append(.completed)
            }
        }
        return events
    }

    private func taskPlanEvents(sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        let entries: [[String: Any]] = taskOrder.compactMap { id in
            guard let task = tasks[id] else { return nil }
            return ["id": id, "content": task.title, "status": task.status]
        }
        return base.planEvents(
            from: ["type": "plan", "entries": entries],
            sessionID: sessionID,
            terminalID: terminalID
        )
    }
}

public final class CodexAdapter: ProviderSemanticAdapter, @unchecked Sendable {
    private let base = BaseProviderAdapter()
    public init() {}
    public func consume(_ data: Data, sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.append(data).flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }
    public func finish(sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.flush().flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }
    private func parse(_ object: [String: Any], sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        var events = base.planEvents(from: object, sessionID: sessionID, terminalID: terminalID)
        let type = BaseProviderAdapter.string(object["type"])?.lowercased()
        if type == "thread.started",
           let event = base.sessionIdentifierEvent(BaseProviderAdapter.string(object["thread_id"])) {
            events.append(event)
        }
        if type == "item.completed",
           BaseProviderAdapter.string(BaseProviderAdapter.nested(object, "item", "type")) == "agent_message",
           let text = BaseProviderAdapter.string(BaseProviderAdapter.nested(object, "item", "text")) {
            events.append(.messageDelta(text))
        }
        if type == "turn.completed" { events.append(.completed) }
        if type == "turn.failed" || type == "error" {
            events.append(.failed(BaseProviderAdapter.string(object["message"]) ?? BaseProviderAdapter.string(BaseProviderAdapter.nested(object, "error", "message"))))
        }
        return events
    }
}

/// Pi (`pi --mode json`) emits a documented NDJSON event stream. The session
/// header carries the resumable session id; `message_update` records carry
/// delta-only text (`assistantMessageEvent.type` + `delta`); `agent_end` marks
/// the final answer. See pi-mono `docs/json.md`.
public final class PiAdapter: ProviderSemanticAdapter, @unchecked Sendable {
    private let base = BaseProviderAdapter()
    public init() {}
    public func consume(_ data: Data, sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.append(data).flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }
    public func finish(sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.flush().flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }
    private func parse(_ object: [String: Any], sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        var events = base.planEvents(from: object, sessionID: sessionID, terminalID: terminalID)
        let type = BaseProviderAdapter.string(object["type"])?.lowercased()
        if type == "session",
           let event = base.sessionIdentifierEvent(BaseProviderAdapter.string(object["id"])) {
            events.append(event)
        }
        let deltaType = BaseProviderAdapter.string(BaseProviderAdapter.nested(object, "assistantMessageEvent", "type"))?.lowercased()
        if deltaType == "text_delta", let text = BaseProviderAdapter.string(BaseProviderAdapter.nested(object, "assistantMessageEvent", "delta")) {
            events.append(.messageDelta(text))
        } else if deltaType == "thinking_delta", let text = BaseProviderAdapter.string(BaseProviderAdapter.nested(object, "assistantMessageEvent", "delta")) {
            events.append(.thinkingDelta(text))
        }
        if type == "agent_end" { events.append(.completed) }
        if type == "error" {
            events.append(.failed(BaseProviderAdapter.string(object["message"]) ?? BaseProviderAdapter.string(object["error"])))
        }
        return events
    }
}

/// CommandCode print mode (`command-code -p`) streams the agent's answer as
/// plain text on stdout, so a line-oriented text adapter is the honest
/// projection. `command-code -p` runs the full tool loop non-interactively and
/// exits once the answer is complete.
public final class CommandCodeAdapter: ProviderSemanticAdapter, @unchecked Sendable {
    private var partial = Data()
    public init() {}
    public func consume(_ data: Data, sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        partial.append(data)
        let lines = partial.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return [] }
        // The final segment is either the trailing empty string (the data
        // ended with a newline, so every line is complete) or a partial line.
        // In both cases it stays buffered for the next chunk; only complete
        // lines are emitted.
        let complete = lines.dropLast()
        partial = Data(lines.last!)
        var events: [ProviderSemanticEvent] = []
        var buffer = ""
        for line in complete {
            buffer += (String(data: Data(line), encoding: .utf8) ?? "").replacingOccurrences(of: "\r", with: "")
            buffer += "\n"
            if buffer.count >= 512 {
                events.append(.messageDelta(buffer))
                buffer = ""
            }
        }
        if !buffer.isEmpty { events.append(.messageDelta(buffer)) }
        return events
    }
    public func finish(sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        guard !partial.isEmpty,
              let text = String(data: partial, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        partial = Data()
        return [.messageDelta(text.replacingOccurrences(of: "\r", with: ""))]
    }
}

/// Kimi's `--prompt --output-format stream-json` mode emits one JSON message
/// per line. Kimi intentionally keeps thinking/progress on stderr, so only
/// assistant content is projected into Chat.
public final class KimiAdapter: ProviderSemanticAdapter, @unchecked Sendable {
    private let base = BaseProviderAdapter()
    public init() {}

    public func consume(_ data: Data, sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.append(data).flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }

    public func finish(sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.flush().flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }

    private func parse(_ object: [String: Any], sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        var events = base.planEvents(from: object, sessionID: sessionID, terminalID: terminalID)
        let identifier = BaseProviderAdapter.string(object["session_id"])
            ?? BaseProviderAdapter.string(object["sessionId"])
            ?? BaseProviderAdapter.string(BaseProviderAdapter.nested(object, "session", "id"))
        if let event = base.sessionIdentifierEvent(identifier) { events.append(event) }

        let role = BaseProviderAdapter.string(object["role"])?.lowercased()
        if role == "assistant" {
            events += contentEvents(object["content"])
        }
        let type = BaseProviderAdapter.string(object["type"])?.lowercased()
        if type == "error" { events.append(.failed(BaseProviderAdapter.string(object["message"]) ?? BaseProviderAdapter.string(object["error"]))) }
        if type == "end" || type == "completed" || type == "result" { events.append(.completed) }
        return events
    }

    private func contentEvents(_ value: Any?) -> [ProviderSemanticEvent] {
        if let text = BaseProviderAdapter.string(value), !text.isEmpty { return [.messageDelta(text)] }
        guard let parts = value as? [[String: Any]] else { return [] }
        return parts.compactMap { part in
            guard let text = BaseProviderAdapter.string(part["text"]), !text.isEmpty else { return nil }
            let type = BaseProviderAdapter.string(part["type"])?.lowercased()
            return type == "thinking" || type == "reasoning" ? .thinkingDelta(text) : .messageDelta(text)
        }
    }
}

/// Qwen's `--prompt --output-format stream-json --include-partial-messages`
/// uses Claude-compatible partial event names for live content and emits a
/// final result record containing the resumable project session ID.
public final class QwenAdapter: ProviderSemanticAdapter, @unchecked Sendable {
    private let base = BaseProviderAdapter()
    private var didEmitMessage = false
    public init() {}

    public func consume(_ data: Data, sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.append(data).flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }

    public func finish(sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.flush().flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }

    private func parse(_ object: [String: Any], sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        var events = base.planEvents(from: object, sessionID: sessionID, terminalID: terminalID)
        let identifier = BaseProviderAdapter.string(object["session_id"])
            ?? BaseProviderAdapter.string(object["sessionId"])
        if let event = base.sessionIdentifierEvent(identifier) { events.append(event) }

        let type = BaseProviderAdapter.string(object["type"])?.lowercased()
        if type == "assistant" {
            if let message = object["message"] as? [String: Any] { events += contentEvents(message["content"]) }
            else { events += contentEvents(object["content"]) }
        }
        if type == "stream_event" {
            let event = object["event"] as? [String: Any]
            let delta = event?["delta"] ?? object["delta"]
            let deltaType = BaseProviderAdapter.string(BaseProviderAdapter.nested(event ?? [:], "delta", "type"))?.lowercased()
            if let text = BaseProviderAdapter.string(delta) {
                events.append(deltaType == "thinking_delta" ? .thinkingDelta(text) : .messageDelta(text))
                didEmitMessage = didEmitMessage || deltaType != "thinking_delta"
            } else if let deltaObject = delta as? [String: Any], let text = BaseProviderAdapter.string(deltaObject["text"]) {
                events.append(deltaType == "thinking_delta" ? .thinkingDelta(text) : .messageDelta(text))
                didEmitMessage = didEmitMessage || deltaType != "thinking_delta"
            }
        }
        if type == "result" {
            if !didEmitMessage, let result = BaseProviderAdapter.string(object["result"]), !result.isEmpty {
                didEmitMessage = true
                events.append(.messageDelta(result))
            }
            events.append((object["is_error"] as? Bool) == true
                ? .failed(BaseProviderAdapter.string(object["result"]))
                : .completed)
        }
        if type == "error" { events.append(.failed(BaseProviderAdapter.string(object["message"]) ?? BaseProviderAdapter.string(object["error"]))) }
        return events
    }

    private func contentEvents(_ value: Any?) -> [ProviderSemanticEvent] {
        if let text = BaseProviderAdapter.string(value), !text.isEmpty {
            didEmitMessage = true
            return [.messageDelta(text)]
        }
        guard let parts = value as? [[String: Any]] else { return [] }
        return parts.compactMap { part in
            guard let text = BaseProviderAdapter.string(part["text"]), !text.isEmpty else { return nil }
            let type = BaseProviderAdapter.string(part["type"])?.lowercased()
            if type == "thinking" || type == "reasoning" { return .thinkingDelta(text) }
            didEmitMessage = true
            return .messageDelta(text)
        }
    }
}

/// Aider's documented `--message --stream` mode writes human-readable text,
/// not a stable JSON protocol. Keep it honest with the same bounded line
/// adapter used for other plain-text headless providers.
public final class AiderAdapter: ProviderSemanticAdapter, @unchecked Sendable {
    private var partial = Data()
    public init() {}

    public func consume(_ data: Data, sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        partial.append(data)
        let lines = partial.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return [] }
        let complete = lines.dropLast()
        partial = Data(lines.last!)
        var text = ""
        for line in complete {
            text += (String(data: Data(line), encoding: .utf8) ?? "").replacingOccurrences(of: "\r", with: "") + "\n"
        }
        return text.isEmpty ? [] : [.messageDelta(text)]
    }

    public func finish(sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        guard !partial.isEmpty,
              let text = String(data: partial, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        partial = Data()
        return [.messageDelta(text.replacingOccurrences(of: "\r", with: ""))]
    }
}

/// Gemini CLI's `--output-format stream-json` emits an `init` session record,
/// assistant messages, and a terminal `result` record.
public final class GeminiAdapter: ProviderSemanticAdapter, @unchecked Sendable {
    private let base = BaseProviderAdapter()
    public init() {}

    public func consume(_ data: Data, sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.append(data).flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }

    public func finish(sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        base.framer.flush().flatMap { parse($0, sessionID: sessionID, terminalID: terminalID) }
    }

    private func parse(_ object: [String: Any], sessionID: UUID, terminalID: UUID) -> [ProviderSemanticEvent] {
        var events = base.planEvents(from: object, sessionID: sessionID, terminalID: terminalID)
        let type = BaseProviderAdapter.string(object["type"])?.lowercased()
        let identifier = BaseProviderAdapter.string(object["session_id"])
            ?? BaseProviderAdapter.string(object["sessionId"])
        if let event = base.sessionIdentifierEvent(identifier) { events.append(event) }
        if type == "message", BaseProviderAdapter.string(object["role"])?.lowercased() == "assistant",
           let text = BaseProviderAdapter.string(object["content"]), !text.isEmpty {
            events.append(.messageDelta(text))
        }
        if type == "result" {
            if let error = BaseProviderAdapter.string(object["error"]), !error.isEmpty {
                events.append(.failed(error))
            } else {
                events.append(.completed)
            }
        }
        if type == "error" { events.append(.failed(BaseProviderAdapter.string(object["message"]) ?? BaseProviderAdapter.string(object["error"]))) }
        return events
    }
}
