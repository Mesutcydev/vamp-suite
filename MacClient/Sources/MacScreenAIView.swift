import AppKit
import CoreImage
import CoreVideo
import Diagnostics
import SwiftUI

/// "Screen AI" for the Mac client — on-device OCR (read/copy text off the live remote screen),
/// ask-about-screen, and a confirm-first automation agent. Reuses the shared `Diagnostics`
/// Foundation-Models / Vision services. (Voice dictation and translate are iOS-only for now —
/// the Translation framework needs macOS 15 and this client deploys to macOS 13.)
///
/// The frame is snapshotted when the panel opens (and on demand) so every tool has a stable
/// image, and on-device-AI availability is shown up front so the LLM tools never silently
/// do nothing.
struct MacScreenAIView: View {
    let frameProvider: () -> CVPixelBuffer?
    let onSendText: (String) -> Void
    let onSendKey: (UInt16) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var snapshot: NSImage?
    @State private var snapshotCG: CGImage?
    @State private var ocrText = ""
    @State private var isRecognizing = false
    @State private var question = ""
    @State private var answer = ""
    @State private var isAsking = false
    @State private var instruction = ""
    @State private var plan: [RemoteActionPlanner.Step] = []
    @State private var isPlanning = false
    @State private var planError = ""

    private static let ciContext = CIContext()

    /// Reason the on-device model can't run, or nil when ready. Ask & Automate need it; OCR doesn't.
    private var aiUnavailableReason: String? {
        if case .unavailable(let why) = LogExplainer.availability { return why }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Screen AI", systemImage: "sparkles").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            Form {
                Section("Screen snapshot") {
                    if let snapshot {
                        Image(nsImage: snapshot)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 120)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Label("Waiting for the screen — tap Recapture once it's live.", systemImage: "hourglass")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button { captureScreen() } label: { Label("Recapture screen", systemImage: "arrow.clockwise") }
                }

                if let reason = aiUnavailableReason {
                    Section("On-device AI") {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Read text on the screen") {
                    Button { recognize() } label: {
                        row("Read screen text", system: "text.viewfinder", busy: isRecognizing, busyLabel: "Reading…")
                    }
                    .disabled(isRecognizing || snapshotCG == nil)
                    if !ocrText.isEmpty {
                        ScrollView {
                            Text(ocrText)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 130)
                        Button { copyToPasteboard(ocrText) } label: { Label("Copy all", systemImage: "doc.on.doc") }
                    }
                }

                Section("Ask about this screen") {
                    TextField("e.g. What does this error mean?", text: $question)
                    Button { ask() } label: {
                        row("Ask", system: "sparkles", busy: isAsking, busyLabel: "Thinking…")
                    }
                    .disabled(isAsking || snapshotCG == nil || aiUnavailableReason != nil
                              || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !answer.isEmpty {
                        Text(answer).textSelection(.enabled)
                        Text("On-device · Apple Intelligence").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Section("Automate — review before it runs") {
                    TextField("e.g. type my email then press enter", text: $instruction)
                    Button { makePlan() } label: {
                        row("Plan steps", system: "wand.and.stars", busy: isPlanning, busyLabel: "Planning…")
                    }
                    .disabled(isPlanning || aiUnavailableReason != nil
                              || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(plan) { step in
                        Label(step.display, systemImage: step.kind == .type ? "text.cursor" : "return").font(.footnote)
                    }
                    if !plan.isEmpty {
                        Button(role: .destructive) { runPlan() } label: { Label("Run on Mac", systemImage: "play.fill") }
                    }
                    if !planError.isEmpty {
                        Text(planError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 640)
        .onAppear { captureScreen() }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// A button label with an inline spinner while the action runs.
    private func row(_ title: String, system: String, busy: Bool, busyLabel: String) -> some View {
        HStack {
            Label(busy ? busyLabel : title, systemImage: system)
            if busy { Spacer(); ProgressView().controlSize(.small) }
        }
    }

    /// Grab the current decoded frame into `snapshot`. Called on appear and via "Recapture".
    private func captureScreen() {
        guard let pixelBuffer = frameProvider() else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        snapshotCG = cg
        snapshot = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func recognize() {
        guard let image = snapshotCG else { return }
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
        guard let image = snapshotCG else { return }
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

    private func makePlan() {
        let text = instruction
        isPlanning = true
        plan = []
        planError = ""
        Task {
            let steps = await RemoteActionPlanner.plan(instruction: text)
            await MainActor.run {
                isPlanning = false
                if steps.isEmpty { planError = "Couldn’t build a plan from that. Try rephrasing it as simple steps." }
                else { plan = steps }
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
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}
