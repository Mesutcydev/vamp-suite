import Foundation
import SharedModels

@MainActor
final class DisplayLayoutViewModel: ObservableObject {
    enum ViewMode: Hashable {
        case singleDisplay(String)
        case unifiedDesktop
    }

    struct DisplaySwitchDiagnostics: Equatable {
        var selectedDisplayID: String?
        var streamState: String
        var firstFrameReceived: Bool
        var switchStartTime: Date?
        var switchFailureReason: String?
    }

    @Published private(set) var layout: DisplayLayout?
    @Published var viewMode: ViewMode = .unifiedDesktop
    @Published var selectedDisplayID: String?
    @Published private(set) var hostSelectedDisplayID: String?
    @Published private(set) var streamConfiguration: DisplayStreamConfiguration?
    @Published private(set) var mappingWarningMessage: String?
    @Published private(set) var isSwitchingDisplay = false
    @Published private(set) var switchFailureReason: String?
    @Published private(set) var switchStartTime: Date?
    @Published private(set) var firstFrameReceivedAfterSwitch = false

    var displays: [DisplayDescriptor] {
        layout?.displays ?? []
    }

    var selectedDisplay: DisplayDescriptor? {
        guard let id = selectedDisplayID else { return nil }
        return layout?.display(withID: id)
    }

    var primaryDisplay: DisplayDescriptor? {
        guard let layout, let primaryID = layout.primaryDisplayID else { return nil }
        return layout.display(withID: primaryID)
    }

    var selectedStreamConfiguration: DisplayStreamConfiguration? {
        guard let selectedDisplayID else { return nil }
        guard streamConfiguration?.displayID == selectedDisplayID else { return nil }
        return streamConfiguration
    }

    var virtualBoundsText: String {
        guard let layout else { return "Unknown" }
        let b = layout.virtualBounds
        return "\(Int(b.size.width))×\(Int(b.size.height))"
    }

    var diagnostics: DisplaySwitchDiagnostics {
        DisplaySwitchDiagnostics(
            selectedDisplayID: selectedDisplayID,
            streamState: isSwitchingDisplay ? "switching" : "stable",
            firstFrameReceived: firstFrameReceivedAfterSwitch,
            switchStartTime: switchStartTime,
            switchFailureReason: switchFailureReason
        )
    }

    func update(layout: DisplayLayout) {
        self.layout = layout
        if let id = selectedDisplayID, layout.display(withID: id) != nil {
            // Keep current selection — it's still valid.
        } else {
            selectedDisplayID = layout.primaryDisplayID
        }
    }

    func selectDisplay(id: String) {
        selectedDisplayID = id
        viewMode = .singleDisplay(id)
        if streamConfiguration?.displayID != id {
            streamConfiguration = nil
        }
    }

    func selectUnifiedDesktop() {
        viewMode = .unifiedDesktop
    }

    func markHostSelectedDisplay(id: String?) {
        hostSelectedDisplayID = id
        if selectedDisplayID == nil, let id {
            selectedDisplayID = id
        }
    }

    func updateStreamConfiguration(_ configuration: DisplayStreamConfiguration) {
        streamConfiguration = configuration
        hostSelectedDisplayID = configuration.displayID
        if selectedDisplayID == nil || selectedDisplayID != configuration.displayID {
            selectedDisplayID = configuration.displayID
            viewMode = .singleDisplay(configuration.displayID)
        }
        mappingWarningMessage = nil
    }

    func beginDisplaySwitch(to id: String) {
        selectedDisplayID = id
        viewMode = .singleDisplay(id)
        if streamConfiguration?.displayID != id {
            streamConfiguration = nil
        }
        isSwitchingDisplay = true
        let started = Date()
        switchStartTime = started
        switchFailureReason = nil
        firstFrameReceivedAfterSwitch = false
        mappingWarningMessage = nil
        // The host sends no result when it refuses a switch (locked Mac, or a second pick
        // inside its 2 s rate limit), so this flag stayed set — and on the Mac client that
        // keeps remote input off — until the session view was rebuilt.
        switchTimeoutTask?.cancel()
        switchTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled,
                  self.isSwitchingDisplay, self.switchStartTime == started else { return }
            if self.hostSelectedDisplayID == id {
                // The host did move to this display (its stream configuration arrived) but
                // nothing else marked the switch done: iOS never reads the host's result
                // message, and two displays of the same size produce no frame-size change.
                self.completeDisplaySwitch(selectedID: id)
            } else {
                self.failDisplaySwitch(reason: "The Mac didn’t switch displays.",
                                       fallbackID: self.hostSelectedDisplayID)
            }
        }
    }

    private var switchTimeoutTask: Task<Void, Never>?

    func noteFirstFrameAfterSwitch() {
        guard isSwitchingDisplay else { return }
        firstFrameReceivedAfterSwitch = true
        isSwitchingDisplay = false
    }

    func completeDisplaySwitch(selectedID: String) {
        hostSelectedDisplayID = selectedID
        selectedDisplayID = selectedID
        viewMode = .singleDisplay(selectedID)
        isSwitchingDisplay = false
        firstFrameReceivedAfterSwitch = true
        switchFailureReason = nil
        mappingWarningMessage = nil
    }

    func failDisplaySwitch(reason: String, fallbackID: String?) {
        if let fallbackID {
            selectedDisplayID = fallbackID
            hostSelectedDisplayID = fallbackID
            viewMode = .singleDisplay(fallbackID)
        }
        isSwitchingDisplay = false
        firstFrameReceivedAfterSwitch = false
        switchFailureReason = reason
    }

    func noteMissingStreamConfigurationIfNeeded(frameSize: DesktopSize?) {
        guard frameSize != nil else { return }
        guard selectedStreamConfiguration == nil else { return }
        mappingWarningMessage = "Display mapping unavailable"
    }

    @discardableResult
    func reconcileStreamFrameSize(_ frameSize: DesktopSize) -> Bool {
        guard var configuration = selectedStreamConfiguration else {
            noteMissingStreamConfigurationIfNeeded(frameSize: frameSize)
            return false
        }

        let differs = abs(configuration.streamWidth - frameSize.width) > 1
            || abs(configuration.streamHeight - frameSize.height) > 1
        guard differs else { return false }

        configuration.streamWidth = frameSize.width
        configuration.streamHeight = frameSize.height
        streamConfiguration = configuration
        mappingWarningMessage = nil
        return true
    }
}
