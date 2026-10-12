#if canImport(FoundationModels)
import FoundationModels
#endif
import Foundation
import SharedModels

/// On-device terminal helper: explains recent terminal output and suggests the next command.
/// Same on-device Foundation Models scaffold as `LogExplainer` (nothing leaves the device).
public enum TerminalAssistant {
    public static var availability: LogExplainer.Availability { LogExplainer.availability }

    /// Explain `output` (the recent terminal buffer); `question` is optional ("why did this fail?").
    public static func explain(output: String, question: String? = nil) async -> String? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let answer = try await session.respond(to: Self.prompt(output: text, question: question)).content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return answer.isEmpty ? nil : answer
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    private static let instructions = """
    You are a command-line assistant inside a remote-desktop app. Given recent terminal output \
    (and maybe a question), explain in 1 to 3 plain sentences what happened, then suggest the single \
    most useful next command on its own line prefixed with "Try: ". Base everything ONLY on the \
    output. If it looks fine, say so. Never invent file names or errors that aren't shown.
    """

    private static func prompt(output: String, question: String?) -> String {
        let tail = String(output.suffix(4000))   // recent output is what matters; bound the context
        if let q = question, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Recent terminal output:\n\(tail)\n\nQuestion: \(q)"
        }
        return "Recent terminal output:\n\(tail)"
    }
}

/// On-device session summary: turns a connection/event log into a short, friendly recap.
public enum SessionSummarizer {
    public static var availability: LogExplainer.Availability { LogExplainer.availability }

    public static func summarize(_ items: [EventLogItem]) async -> String? {
        guard !items.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let answer = try await session.respond(to: Self.prompt(for: items)).content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return answer.isEmpty ? nil : answer
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    private static let instructions = """
    Summarize a remote-desktop session from its event log in 2 to 4 friendly, plain sentences: \
    what happened over the session, how the connection behaved, and any issues worth noting. \
    Base it only on the log; don't invent events.
    """

    private static func prompt(for items: [EventLogItem]) -> String {
        let recent = items.sorted { $0.timestamp < $1.timestamp }.suffix(80)
        let lines = recent.map { "[\($0.severity.rawValue)] \($0.category): \($0.message)" }
        return "Session event log (oldest to newest):\n\(lines.joined(separator: "\n"))"
    }
}
