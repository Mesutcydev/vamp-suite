import Foundation
import SwiftUI

enum ReceivedFileSaveError: LocalizedError, Equatable {
    case cancelled
    case noDestination

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Save canceled"
        case .noDestination:
            return "No save destination was chosen."
        }
    }
}

#if canImport(UIKit)
import UIKit

struct ReceivedFileSaveSheet: UIViewControllerRepresentable {
    let fileURL: URL
    let onCompletion: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onCompletion: (Result<URL, Error>) -> Void

        init(onCompletion: @escaping (Result<URL, Error>) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let first = urls.first {
                onCompletion(.success(first))
            } else {
                onCompletion(.failure(URLError(.cannotCreateFile)))
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCompletion(.failure(URLError(.cancelled)))
        }
    }
}
#endif
