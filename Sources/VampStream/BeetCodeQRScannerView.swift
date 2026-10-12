import SwiftUI
import AVFoundation
#if canImport(UIKit) && canImport(VisionKit)
import UIKit
import VisionKit

struct BeetCodeQRScannerView: UIViewControllerRepresentable {
    enum Source {
        case assistant, sync
        var instructions: String {
            switch self {
            case .assistant: return "Enter the address and six-digit pairing code shown by Vamp Assistant or Vamp Companion manually."
            case .sync: return "Close the scanner and enter the private address shown by Vamp Sync."
            }
        }
    }
    var source: Source = .assistant
    let onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        QRScannerController(instructions: source.instructions, onPayload: onPayload)
    }
    func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

final class QRScannerController: UIViewController, DataScannerViewControllerDelegate {
    private let instructions: String
    private let onPayload: (String) -> Void
    private var scanner: DataScannerViewController?
    private var fallback: UIViewController?
    private var didRead = false
    private var requestingAccess = false

    init(instructions: String, onPayload: @escaping (String) -> Void) {
        self.instructions = instructions
        self.onPayload = onPayload
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        NotificationCenter.default.addObserver(self, selector: #selector(start),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); start() }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner?.stopScanning()
    }

    @objc private func start() {
        guard viewIfLoaded?.window != nil, !didRead else { return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            guard !requestingAccess else { return }
            requestingAccess = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                Task { @MainActor in self?.requestingAccess = false; self?.start() }
            }
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            showFailure("Camera access is unavailable. Enable Camera in Settings to scan a QR code.")
            return
        }
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            showFailure("Camera scanning is unavailable on this device.")
            return
        }
        remove(fallback); fallback = nil
        if scanner == nil {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
            scanner.delegate = self
            self.scanner = scanner
            embed(scanner)
        }
        do { try scanner?.startScanning() }
        catch { showFailure("Scanning could not start. \(error.localizedDescription)") }
    }

    func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        showFailure("Scanning stopped. \(error.localizedDescription)")
    }
    func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
        guard !didRead else { return }
        for item in items {
            guard case .barcode(let code) = item, let payload = code.payloadStringValue, !payload.isEmpty else { continue }
            didRead = true
            scanner.stopScanning()
            onPayload(payload)
            return
        }
    }
    private func showFailure(_ reason: String) {
        scanner?.stopScanning(); remove(scanner); scanner = nil
        remove(fallback)
        let content = UIHostingController(rootView:
            VStack(spacing: 20) {
                ContentUnavailableView("QR scanning unavailable", systemImage: "qrcode.viewfinder",
                    description: Text("\(reason)\n\n\(instructions)"))
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.buttonStyle(.borderedProminent)
                Button("Try Again") { [weak self] in self?.start() }.buttonStyle(.bordered)
            }.padding())
        fallback = content
        embed(content)
    }
    private func embed(_ child: UIViewController) {
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }
    private func remove(_ child: UIViewController?) {
        child?.willMove(toParent: nil); child?.view.removeFromSuperview(); child?.removeFromParent()
    }
}
#else
struct BeetCodeQRScannerView: View {
    enum Source { case assistant, sync }
    var source: Source = .assistant
    let onPayload: (String) -> Void
    var body: some View {
        Text("QR scanning is unavailable. Enter the Mac's private address manually.")
    }
}
#endif
