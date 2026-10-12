#if os(iOS)
import AVFoundation
import Foundation
import Speech

/// On-device dictation so the user can "type" into the remote Mac by voice — the transcript is
/// injected as text input on the host. Uses `requiresOnDeviceRecognition` so audio never leaves
/// the phone.
/// ponytail: SFSpeechRecognizer on-device is the stable path; iOS 26 SpeechAnalyzer/SpeechTranscriber
/// is the modern upgrade once its asset-install + streaming surface earns its keep.
@MainActor
final class VoiceDictationService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?

    /// Emitted with the final transcript when recording stops, for injection into the host.
    var onText: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        guard !isRecording else { return }
        guard await Self.authorize() else {
            errorMessage = "Allow Speech Recognition in Settings to dictate."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn’t available right now."
            return
        }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            self.request = request

            let input = audioEngine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()

            transcript = ""
            errorMessage = nil
            isRecording = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                // The recognition callback fires on an arbitrary queue; hop to the main actor
                // before touching @Published state on this @MainActor service.
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if error != nil || (result?.isFinal ?? false) { self.teardown() }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            teardown()
        }
    }

    /// Stop and emit whatever has been recognized so far (don't wait for a final result —
    /// the user tapped stop because they're done speaking).
    func stop() {
        guard isRecording else { return }
        let final = transcript
        teardown()
        if !final.isEmpty { onText?(final) }
    }

    private func teardown() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorize() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }
}
#endif
