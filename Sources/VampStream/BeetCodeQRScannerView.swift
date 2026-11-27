import SharedModels
import SwiftUI
import AVFoundation
#if canImport(UIKit) && canImport(VisionKit)
import UIKit
import VisionKit

struct BeetCodeQRScannerView: UIViewControllerRepresentable {
    enum Source {
        case assistant, sync, mac
        var instructions: String {
            switch self {
            case .assistant: return "Enter the address and six-digit pairing code shown by Assistant or Companion manually."
            case .sync: return "Close the scanner and enter the private address shown by \(VampProductIdentity.syncName)."
            case .mac: return "Close the scanner to enter the private address or pairing code shown by Sync, Assistant, or Companion on your Mac."
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
            showFailure("Enable Camera in Settings to scan your Mac’s pairing code.", offersSettings: true)
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
    private func showFailure(_ reason: String, offersSettings: Bool = false) {
        scanner?.stopScanning(); remove(scanner); scanner = nil
        remove(fallback)
        let content = UIHostingController(rootView: StreamScannerUnavailableView(
            reason: reason, instructions: instructions, offersSettings: offersSettings,
            onRetry: { [weak self] in self?.start() }
        ))
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

/// A hosted UIKit scanner does not inherit the app's SwiftUI environment.
/// Read the saved appearance here so camera errors follow the same settings.
private struct StreamScannerUnavailableView: View {
    let reason: String
    let instructions: String
    let offersSettings: Bool
    let onRetry: () -> Void
    @AppStorage(VampStreamAppearance.key) private var appearance = VampStreamAppearance.dark
    @AppStorage(VampStreamAppearance.backgroundArtKey) private var showsArt = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(StreamDesign.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Keep your Mac close.")
                        .font(.largeTitle.weight(.medium)).tracking(-1.5)
                        .foregroundStyle(StreamDesign.text)
                    Text(reason).font(.body).foregroundStyle(StreamDesign.secondary)
                }
                Label(instructions, systemImage: "macwindow")
                    .font(.subheadline).foregroundStyle(StreamDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(22).frame(maxWidth: .infinity, alignment: .leading).streamGlass()
                if offersSettings {
                    StreamPrimaryButton(title: "Open Settings", symbol: "camera") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Button("Try again", action: onRetry)
                    .font(.body.weight(.medium)).foregroundStyle(StreamDesign.text)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .streamGlass(radius: 24).buttonStyle(StreamPressStyle())
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(24).padding(.top, 32).frame(maxWidth: .infinity)
        }
        .background { VampStreamEnvironmentBackdrop() }
        .environment(\.prSolidSurfaces, !showsArt)
        .preferredColorScheme(appearance.colorScheme)
    }
}
#else
struct BeetCodeQRScannerView: View {
    enum Source { case assistant, sync, mac }
    var source: Source = .assistant
    let onPayload: (String) -> Void
    var body: some View {
        Text("QR scanning is unavailable. Enter the Mac's private address manually.")
    }
}
#endif
