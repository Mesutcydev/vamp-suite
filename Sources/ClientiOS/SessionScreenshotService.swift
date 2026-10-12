import CoreImage
import CoreVideo
import Foundation
#if canImport(UIKit)
import UIKit
#endif

protocol SessionScreenshotCapturing {
    func capture(pixelBuffer: CVPixelBuffer) throws -> URL
}

struct SessionScreenshotService: SessionScreenshotCapturing {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func capture(pixelBuffer: CVPixelBuffer) throws -> URL {
        #if canImport(UIKit)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            throw ScreenshotError.encodingFailed
        }

        let uiImage = UIImage(cgImage: cgImage)
        guard let data = uiImage.pngData() else {
            throw ScreenshotError.encodingFailed
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let filename = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-screenshot-\(filename)")
            .appendingPathExtension("png")
        try data.write(to: url, options: .atomic)
        return url
        #else
        throw ScreenshotError.unsupportedPlatform
        #endif
    }

    enum ScreenshotError: LocalizedError {
        case encodingFailed
        case unsupportedPlatform

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Unable to encode the current frame."
            case .unsupportedPlatform:
                return "Screenshot capture is unavailable on this platform."
            }
        }
    }
}
