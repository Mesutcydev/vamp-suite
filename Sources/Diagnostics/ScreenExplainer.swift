#if canImport(FoundationModels)
import FoundationModels
#endif
import CoreGraphics
import Foundation
import os

/// Answers a natural-language question about what's currently on the remote screen.
///
/// Privacy-first by construction: the frame is OCR'd on-device (`ScreenTextRecognizer`) and the
/// extracted text is reasoned over by the **on-device** language model — nothing about the remote
/// screen leaves the device. Reuses `LogExplainer`'s availability gating and result types. We
/// deliberately use the text path (OCR → on-device LLM) rather than the multimodal image API:
/// it ships on the GM Xcode today and remote screens are overwhelmingly text (code, terminals,
/// dialogs, settings).
public enum ScreenExplainer {
    private static let logger = Logger(subsystem: "com.remotedesktop.client", category: "ScreenAI")

    /// Whether an on-device model is usable right now (same check as the log explainer).
    public static var availability: LogExplainer.Availability { LogExplainer.availability }

    /// Answer `question` about already-extracted on-screen `screenText`. Returns nil if no model
    /// is available or the screen has no text.
    public static func answer(question: String, screenText: String) async -> LogExplainer.Explanation? {
        let text = screenText.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !q.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let answer = try await session.respond(to: Self.prompt(question: q, screenText: text)).content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return answer.isEmpty ? nil : LogExplainer.Explanation(text: answer, engine: .onDevice)
            } catch {
                logger.error("ScreenExplainer.answer failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        #endif
        return nil
    }

    /// Convenience: OCR the frame on-device, then answer the question about it.
    public static func answer(question: String, about image: CGImage) async -> LogExplainer.Explanation? {
        let screenText = await ScreenTextRecognizer.recognizeText(in: image)
        return await answer(question: question, screenText: screenText)
    }

    private static let instructions = """
    You are an assistant inside "Vamp Control", a Mac remote-control app. The user is looking at a remote \
    Mac screen and asks a question about it. You are given the on-screen text extracted by OCR \
    (it may be noisy or partial). Answer concisely — 1 to 4 sentences — based ONLY on that text. \
    If the text doesn't contain the answer, say the screen doesn't show enough to tell. Do not \
    invent UI that isn't in the text. For code or errors, explain plainly what it means and the \
    single most useful next step.
    """

    private static func prompt(question: String, screenText: String) -> String {
        // Bound the text so a dense screen can't blow the context window.
        let bounded = String(screenText.prefix(6000))
        return """
        On-screen text (OCR, reading order):
        \(bounded)

        Question: \(question)
        """
    }
}
