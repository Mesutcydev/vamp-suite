import Foundation
import CaptureEngine
import Diagnostics
import SharedModels

@MainActor
final class CaptureStreamingViewModel: ObservableObject {
    @Published private(set) var captureState: CaptureState = .stopped
    @Published private(set) var diagnostics: CaptureDiagnostics = CaptureDiagnostics()
    @Published var selectedDisplayID: String?
    @Published var selectedPreset: StreamQualityPreset = .balanced
    @Published var displayLayout: DisplayLayout?
    @Published private(set) var errorMessage: String?

    private let captureEngine: any CaptureEngineProtocol
    private let displayLayoutProvider: any DisplayLayoutProviding
    private let eventLogStore: any EventLogStoreProtocol
    private var stateObserverTask: Task<Void, Never>?
    private var diagnosticsTimer: Task<Void, Never>?

    init(
        captureEngine: any CaptureEngineProtocol,
        displayLayoutProvider: any DisplayLayoutProviding,
        eventLogStore: any EventLogStoreProtocol
    ) {
        self.captureEngine = captureEngine
        self.displayLayoutProvider = displayLayoutProvider
        self.eventLogStore = eventLogStore
    }

    var isRunning: Bool { captureState == .running }
    var isStarting: Bool { captureState == .starting }
    var canStart: Bool { captureState == .stopped || captureState == .failed || captureState == .permissionBlocked }

    var selectedDisplay: DisplayDescriptor? {
        guard let id = selectedDisplayID else { return nil }
        return displayLayout?.display(withID: id)
    }

    var stateText: String {
        switch captureState {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .failed: return "Failed"
        case .permissionBlocked: return "Permission Blocked"
        }
    }

    var configSummary: String {
        guard let display = selectedDisplay else { return "No display selected" }
        return "\(Int(display.pixelSize.width))×\(Int(display.pixelSize.height)) · \(selectedPreset.rawValue.capitalized)"
    }

    var frameCountText: String {
        "\(diagnostics.capturedFrames) captured, \(diagnostics.droppedFrames) dropped"
    }

    // MARK: - Lifecycle

    func loadDisplayLayout() async {
        do {
            let layout = try await displayLayoutProvider.currentDisplayLayout()
            displayLayout = layout
            if selectedDisplayID == nil || layout.display(withID: selectedDisplayID!) == nil {
                selectedDisplayID = layout.primaryDisplayID ?? layout.displays.first?.id
            }
        } catch {
            errorMessage = "Failed to query displays: \(error.localizedDescription)"
        }
    }

    func startObservingState() {
        guard stateObserverTask == nil else { return }
        stateObserverTask = Task { [weak self] in
            guard let self else { return }
            for await state in captureEngine.stateChanges() {
                self.captureState = state
            }
        }
        diagnosticsTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                guard let self else { return }
                self.diagnostics = captureEngine.diagnostics
            }
        }
    }

    func startCapture() async {
        guard let displayID = selectedDisplayID else {
            errorMessage = "No display selected."
            return
        }
        errorMessage = nil
        do {
            try await captureEngine.startCapture(displayID: displayID, qualityPreset: selectedPreset)
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Capture",
                message: "Capture started on display \(displayID), preset: \(selectedPreset.rawValue)"
            ))
        } catch {
            errorMessage = error.localizedDescription
            await eventLogStore.append(EventLogItem(
                severity: .error,
                category: "Capture",
                message: "Capture start failed: \(error.localizedDescription)"
            ))
        }
    }

    func stopCapture() async {
        await captureEngine.stopCapture()
        await eventLogStore.append(EventLogItem(
            severity: .info,
            category: "Capture",
            message: "Capture stopped"
        ))
    }

    func restartCapture() async {
        await stopCapture()
        await startCapture()
        diagnostics.streamRestarts += 1
        await eventLogStore.append(EventLogItem(
            severity: .info,
            category: "Capture",
            message: "Capture restarted (restart #\(diagnostics.streamRestarts))"
        ))
    }
}
