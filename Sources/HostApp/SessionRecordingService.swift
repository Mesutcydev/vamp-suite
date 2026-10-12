import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
#if os(macOS)
final class SessionRecordingService: ObservableObject, @unchecked Sendable {
    enum RecordingState: Equatable {
        case idle
        case recording(URL)
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var state: RecordingState = .idle

    private let lock = NSLock()
    private var outputURL: URL?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startedAt: CMTime?
    /// Cached "is recording" flag, guarded by `lock`. `append(sampleBuffer:)` runs on the
    /// ScreenCaptureKit sample-handler queue for EVERY frame; reading the recording state must not
    /// hop to the main thread (the old `currentState` did `DispatchQueue.main.sync`, blocking the
    /// high-QoS capture queue ~60×/s even when idle — a throughput/energy/priority-inversion bug).
    private var isRecordingActive = false

    func start() throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let directory = FileManager.default.temporaryDirectory
        let url = directory
            .appendingPathComponent("session-recording-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-"))")
            .appendingPathExtension("mp4")

        lock.withLock {
            outputURL = url
            writer = nil
            writerInput = nil
            adaptor = nil
            startedAt = nil
        }

        publish(.recording(url))
        return url
    }

    func append(sampleBuffer: CMSampleBuffer) {
        guard lock.withLock({ isRecordingActive }) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        lock.lock()
        defer { lock.unlock() }

        do {
            if writer == nil {
                try configureWriterLocked(sampleBuffer: sampleBuffer, pixelBuffer: pixelBuffer)
            }

            guard
                let writer,
                let writerInput,
                let adaptor
            else {
                return
            }

            if writer.status == .unknown {
                writer.startWriting()
                writer.startSession(atSourceTime: presentationTime)
                startedAt = presentationTime
            }

            if writer.status == .failed {
                publish(.failed(writer.error?.localizedDescription ?? "Recording failed."))
                return
            }

            guard writerInput.isReadyForMoreMediaData else { return }
            _ = adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        } catch {
            publish(.failed(error.localizedDescription))
        }
    }

    @discardableResult
    func stop() async -> URL? {
        let snapshot: (AVAssetWriter?, AVAssetWriterInput?, URL?) = lock.withLock {
            let s = (writer, writerInput, outputURL)
            writer = nil
            writerInput = nil
            adaptor = nil
            outputURL = nil
            startedAt = nil
            return s
        }

        guard let writer = snapshot.0, let input = snapshot.1, let url = snapshot.2 else {
            publish(.idle)
            return nil
        }

        input.markAsFinished()

        // Use nonisolated(unsafe) to pass AVAssetWriter into @Sendable finishWriting closure.
        nonisolated(unsafe) let unsafeWriter = writer
        let didFinish: Bool = await withCheckedContinuation { continuation in
            unsafeWriter.finishWriting {
                continuation.resume(returning: unsafeWriter.status == .completed)
            }
        }

        if didFinish {
            publish(.finished(url))
            return url
        } else {
            publish(.failed(writer.error?.localizedDescription ?? "Recording finalization failed."))
            return nil
        }
    }

    private func configureWriterLocked(
        sampleBuffer: CMSampleBuffer,
        pixelBuffer: CVPixelBuffer
    ) throws {
        guard let outputURL else {
            throw RecordingError.notStarted
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: 8_000_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(pixelBuffer),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.canAdd(input) else {
            throw RecordingError.cannotAddInput
        }

        writer.add(input)
        self.writer = writer
        self.writerInput = input
        self.adaptor = adaptor
        self.startedAt = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }

    private func publish(_ newState: RecordingState) {
        // Keep the lock-guarded fast-path flag in sync with the published state so the capture
        // queue can check "are we recording?" without a main-thread hop.
        let active: Bool
        if case .recording = newState { active = true } else { active = false }
        lock.withLock { isRecordingActive = active }
        Task { @MainActor [weak self] in
            self?.state = newState
        }
    }

    enum RecordingError: LocalizedError {
        case notStarted
        case cannotAddInput

        var errorDescription: String? {
            switch self {
            case .notStarted:
                return "Recording is not active."
            case .cannotAddInput:
                return "Unable to add the video writer input."
            }
        }
    }
}
#else
final class SessionRecordingService: ObservableObject, @unchecked Sendable {
    enum RecordingState: Equatable {
        case idle
        case recording(URL)
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var state: RecordingState = .failed("Recording is only available on macOS.")

    func start() throws -> URL { throw NSError(domain: "SessionRecordingService", code: 1) }
    func append(sampleBuffer: CMSampleBuffer) {}
    func stop() async -> URL? { nil }
}
#endif
