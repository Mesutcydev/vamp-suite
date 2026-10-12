import Foundation
import SharedModels

@MainActor
final class ThermalMonitorService: ObservableObject {
    @Published private(set) var thermalState: AppThermalState = .nominal

    private var observer: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        refresh()
        observer = notificationCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func refresh() {
        thermalState = Self.map(ProcessInfo.processInfo.thermalState)
    }

    private static func map(_ state: ProcessInfo.ThermalState) -> AppThermalState {
        switch state {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .fair
        }
    }
}

@MainActor
final class LowPowerModeService: ObservableObject {
    @Published private(set) var systemLowPowerModeEnabled: Bool = false

    private var observer: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        refresh()
        observer = notificationCenter.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func refresh() {
        systemLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
