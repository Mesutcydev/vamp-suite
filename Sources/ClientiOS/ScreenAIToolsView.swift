#if os(iOS)
import CoreImage
import CoreVideo
import Diagnostics
import SwiftUI
import Translation
import UIKit

/// "Screen AI" tools over the live remote stream — all on-device:
///  1. Read screen text (Vision OCR) so you can copy text that's otherwise trapped in the video.
///  2. Ask about this screen (OCR → on-device Foundation Model).
///  3. Translate the screen text (Apple's Translation framework).
///  4. Dictate to the remote Mac (on-device speech → injected as text input on the host).
///  5. Automate — plan a few input steps and run them on the host after review.
///
/// The frame is snapshotted when the sheet opens (and on demand) so every tool has a stable
/// image to work on, and on-device-AI availability is shown up front so the LLM tools never
/// just silently do nothing.
struct ScreenAIToolsView: View {
    /// Supplies the current decoded frame (the renderer's latest pixel buffer).
    let frameProvider: () -> CVPixelBuffer?
    /// Sends recognized speech / typed text to the host as keyboard text.
    let onSendText: (String) -> Void
    /// Sends a single key press (full down+up) to the host, e.g. Return (36).
    let onSendKey: (UInt16) -> Void

    @StateObject private var voice = VoiceDictationService()
    @Environment(\.dismiss) private var dismiss

    /// The screen image the tools analyze — captured when the sheet opens, refreshable.
    @State private var snapshot: UIImage?

    @State private var ocrText = ""
    @State private var isRecognizing = false
    @State private var question = ""
    @State private var answer = ""
    @State private var isAsking = false

    @State private var translatedText = ""
    @State private var isTranslating = false
    @State private var pendingTranslationText = ""
    @State private var translationConfig: TranslationSession.Configuration?

    @State private var instruction = ""
    @State private var plan: [RemoteActionPlanner.Step] = []
    @State private var isPlanning = false
    @State private var planError = ""

    private static let ciContext = CIContext()

    /// Reason the on-device model can't run (device/Settings), or nil when it's ready. Ask &
    /// Automate need it; OCR, Translate and Dictate don't.
    private var aiUnavailableReason: String? {
        if case .unavailable(let why) = LogExplainer.availability { return why }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                captureSection
                if let reason = aiUnavailableReason {
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: { Text("On-device AI") }
                }
                readSection
                askSection
                translateSection
                dictateSection
                automateSection
            }
            .navigationTitle("Screen AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { voice.onText = onSendText; captureScreen() }
            .onDisappear { if voice.isRecording { voice.stop() } }
            .translationTask(translationConfig) { session in
                do {
                    let response = try await session.translate(pendingTranslationText)
                    await MainActor.run { translatedText = response.targetText; isTranslating = false }
                } catch {
                    await MainActor.run { translatedText = "Couldn’t translate this screen."; isTranslating = false }
                }
            }
        }
    }

    // MARK: - Sections

    private var captureSection: some View {
        Section {
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 130)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button { captureScreen() } label: {
                    Label("Recapture screen", systemImage: "arrow.clockwise")
                }
            } else {
                Label("Waiting for the screen — keep this open and tap Recapture.", systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button { captureScreen() } label: {
                    Label("Recapture screen", systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text("Screen snapshot")
        } footer: {
            Text("Everything below runs on-device on this snapshot of the remote screen.")
        }
    }

    private var readSection: some View {
        Section("Read text on the screen") {
            Button { recognize() } label: {
                row("Read screen text", system: "text.viewfinder", busy: isRecognizing, busyLabel: "Reading…")
            }
            .disabled(isRecognizing || snapshot == nil)
            if !ocrText.isEmpty {
                Text(ocrText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Button { UIPasteboard.general.string = ocrText } label: {
                    Label("Copy all", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var askSection: some View {
        Section("Ask about this screen") {
            TextField("e.g. What does this error mean?", text: $question, axis: .vertical)
            Button { ask() } label: {
                row("Ask", system: "sparkles", busy: isAsking, busyLabel: "Thinking…")
            }
            .disabled(isAsking || snapshot == nil || aiUnavailableReason != nil
                      || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !answer.isEmpty {
                Text(answer).textSelection(.enabled)
                Text("On-device · Apple Intelligence")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var translateSection: some View {
        Section("Translate this screen") {
            Button { translate() } label: {
                row("Translate screen text", system: "character.book.closed", busy: isTranslating, busyLabel: "Translating…")
            }
            .disabled(isTranslating || snapshot == nil)
            if !translatedText.isEmpty {
                Text(translatedText).textSelection(.enabled)
            }
        }
    }

    private var dictateSection: some View {
        Section("Dictate to the remote Mac") {
            Button { voice.toggle() } label: {
                Label(voice.isRecording ? "Stop & send" : "Start dictation",
                      systemImage: voice.isRecording ? "stop.circle.fill" : "mic.fill")
                    .foregroundStyle(voice.isRecording ? Color.red : Color.accentColor)
            }
            if voice.isRecording || !voice.transcript.isEmpty {
                Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                    .foregroundStyle(.secondary)
            }
            if let err = voice.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var automateSection: some View {
        Section("Automate — review before it runs") {
            TextField("e.g. type my email then press enter", text: $instruction, axis: .vertical)
            Button { makePlan() } label: {
                row("Plan steps", system: "wand.and.stars", busy: isPlanning, busyLabel: "Planning…")
            }
            .disabled(isPlanning || aiUnavailableReason != nil
                      || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ForEach(plan) { step in
                Label(step.display, systemImage: step.kind == .type ? "text.cursor" : "return")
                    .font(.footnote)
            }
            if !plan.isEmpty {
                Button(role: .destructive) { runPlan() } label: {
                    Label("Run on Mac", systemImage: "play.fill")
                }
            }
            if !planError.isEmpty {
                Text(planError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// A button label with an inline spinner while the action runs.
    private func row(_ title: String, system: String, busy: Bool, busyLabel: String) -> some View {
        HStack {
            Label(busy ? busyLabel : title, systemImage: system)
            if busy { Spacer(); ProgressView() }
        }
    }

    // MARK: - Frame capture

    /// Grab the current decoded frame into `snapshot`. Called on appear and via "Recapture".
    private func captureScreen() {
        guard let pixelBuffer = frameProvider() else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        snapshot = UIImage(cgImage: cg)
    }

    // MARK: - Actions

    private func recognize() {
        guard let image = snapshot?.cgImage else { return }
        isRecognizing = true
        ocrText = ""
        Task {
            let text = await ScreenTextRecognizer.recognizeText(in: image)
            await MainActor.run {
                ocrText = text.isEmpty ? "No text found on this screen." : text
                isRecognizing = false
            }
        }
    }

    private func ask() {
        guard let image = snapshot?.cgImage else { return }
        let q = question
        isAsking = true
        answer = ""
        Task {
            let result = await ScreenExplainer.answer(question: q, about: image)
            await MainActor.run {
                answer = result?.text ?? "Couldn’t answer that — the on-device model didn’t respond. Try again."
                isAsking = false
            }
        }
    }

    private func translate() {
        guard let image = snapshot?.cgImage else { return }
        isTranslating = true
        translatedText = ""
        Task {
            let text = await ScreenTextRecognizer.recognizeText(in: image)
            await MainActor.run {
                guard !text.isEmpty else {
                    translatedText = "No text found on this screen."
                    isTranslating = false
                    return
                }
                pendingTranslationText = String(text.prefix(2000))
                // A fresh configuration (re)triggers the translationTask; target = device language.
                translationConfig = TranslationSession.Configuration(source: nil, target: Locale.current.language)
            }
        }
    }

    private func makePlan() {
        let text = instruction
        isPlanning = true
        plan = []
        planError = ""
        Task {
            let steps = await RemoteActionPlanner.plan(instruction: text)
            await MainActor.run {
                isPlanning = false
                if steps.isEmpty {
                    planError = "Couldn’t build a plan from that. Try rephrasing it as simple steps."
                } else {
                    plan = steps
                }
            }
        }
    }

    private func runPlan() {
        let steps = plan
        plan = []
        instruction = ""
        Task {
            for step in steps {
                switch step.kind {
                case .type:
                    onSendText(step.value)
                case .key:
                    let code: UInt16 = step.value == "return" ? 36 : (step.value == "tab" ? 48 : 53)
                    onSendKey(code)
                }
                // Small gap so the host's input pipeline preserves step order under load.
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}
#endif
