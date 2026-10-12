#if canImport(Vision)
import Vision
#endif
import CoreGraphics
import Foundation

/// On-device OCR of a remote-screen frame, so the user can read and copy text that is
/// otherwise trapped inside the H.265 video stream (you can't select pixels). Pure Vision
/// (`VNRecognizeTextRequest`) — runs entirely on-device, nothing leaves the device, and
/// it's available far below the deployment target so it ships on any Xcode.
public enum ScreenTextRecognizer {
    public struct Line: Sendable, Identifiable {
        public let id = UUID()
        public let text: String
        public let confidence: Float
    }

    /// Recognize text in a decoded frame. Returns lines in natural reading order
    /// (top-to-bottom), or an empty array if there's no text or Vision is unavailable.
    public static func recognize(in image: CGImage) async -> [Line] {
        #if canImport(Vision)
        await withCheckedContinuation { (continuation: CheckedContinuation<[Line], Never>) in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                // Vision boxes use a bottom-left origin, so higher maxY = higher on screen.
                let lines: [Line] = observations
                    .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                    .compactMap { obs in
                        guard let top = obs.topCandidates(1).first, !top.string.isEmpty else { return nil }
                        return Line(text: top.string, confidence: top.confidence)
                    }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
        #else
        return []
        #endif
    }

    /// All recognized text joined in reading order — the copy-everything convenience.
    public static func recognizeText(in image: CGImage) async -> String {
        await recognize(in: image).map(\.text).joined(separator: "\n")
    }
}
