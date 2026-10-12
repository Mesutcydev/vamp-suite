#if canImport(FoundationModels)
import FoundationModels
#endif
import Foundation
import os

/// Turns a natural-language instruction ("type my email then press enter") into a **reviewable**
/// list of keyboard steps for the remote Mac. The plan is always shown to the user before anything
/// runs — nothing is injected without explicit confirmation. Fully on-device.
///
/// v1 is intentionally conservative: TYPE text and the Return/Tab/Escape keys, assuming the right
/// app/field is already focused. (App launching via Spotlight + modifiers is a deliberate v2.)
public enum RemoteActionPlanner {
    public struct Step: Sendable, Identifiable {
        public enum Kind: String, Sendable { case type, key }
        public let id = UUID()
        public let kind: Kind
        public let value: String
        public var display: String { kind == .type ? "Type “\(value)”" : "Press \(value.capitalized)" }
    }

    public static var availability: LogExplainer.Availability { LogExplainer.availability }

    public static func plan(instruction: String) async -> [Step] {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let raw = try await session.respond(to: "Instruction: \(trimmed)").content
                return parse(raw)
            } catch {
                Logger(subsystem: "com.remotedesktop.client", category: "ScreenAI")
                    .error("RemoteActionPlanner.plan failed: \(error.localizedDescription, privacy: .public)")
                return []
            }
        }
        #endif
        return []
    }

    private static let instructions = """
    You convert a user's instruction into a short list of keyboard steps for a Mac that is already \
    focused on the right app and field. Output ONLY lines, each exactly one of:
    TYPE: <text to type>
    KEY: <return|tab|escape>
    Keep it minimal and literal — usually a single TYPE, optionally followed by KEY: return. Never \
    add steps the user didn't ask for. No explanations, no other text.
    """

    private static func parse(_ raw: String) -> [Step] {
        var steps: [Step] = []
        for rawLine in raw.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let value = prefixValue(line, "TYPE:"), !value.isEmpty {
                steps.append(Step(kind: .type, value: value))
            } else if let value = prefixValue(line, "KEY:")?.lowercased(),
                      ["return", "tab", "escape"].contains(value) {
                steps.append(Step(kind: .key, value: value))
            }
        }
        return steps
    }

    private static func prefixValue(_ line: String, _ prefix: String) -> String? {
        guard line.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
