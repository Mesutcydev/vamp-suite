import Foundation
import SharedModels

@MainActor
final class HostSessionModeController: ObservableObject {
    @Published private(set) var mode: SessionControlMode

    private let lock = NSLock()

    init(mode: SessionControlMode = .fullControl) {
        self.mode = mode
        self._currentMode = mode
    }

    nonisolated var currentMode: SessionControlMode {
        lock.lock()
        defer { lock.unlock() }
        return _currentMode
    }

    private nonisolated(unsafe) var _currentMode: SessionControlMode = .fullControl

    func setMode(_ newMode: SessionControlMode) {
        lock.lock()
        _currentMode = newMode
        lock.unlock()
        mode = newMode
    }
}

@MainActor
final class HostPerformanceStateController: ObservableObject {
    @Published private(set) var thermalState: AppThermalState
    @Published private(set) var lowPowerModeEnabled: Bool
    @Published private(set) var profile: StreamingPerformanceProfile

    private let policyService: SessionPerformancePolicyService
    private let preferredPresetProvider: @Sendable () -> StreamQualityPreset
    private var activePreset: StreamQualityPreset?

    init(
        thermalState: AppThermalState = .nominal,
        lowPowerModeEnabled: Bool = false,
        policyService: SessionPerformancePolicyService = SessionPerformancePolicyService(),
        preferredPresetProvider: @escaping @Sendable () -> StreamQualityPreset = { .balanced }
    ) {
        self.thermalState = thermalState
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.policyService = policyService
        self.preferredPresetProvider = preferredPresetProvider
        self.profile = policyService.profile(
            preferredPreset: preferredPresetProvider(),
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState
        )
    }

    func setThermalState(_ newState: AppThermalState) {
        thermalState = newState
        recomputeProfile()
    }

    func setLowPowerModeEnabled(_ isEnabled: Bool) {
        lowPowerModeEnabled = isEnabled
        recomputeProfile()
    }

    /// Call after the pipeline applies a new quality preset so the dashboard tiles reflect it live.
    /// Applies the client-requested preset through the host's live power and thermal policy.
    /// Returning the effective value keeps session setup from accidentally treating the
    /// controller's idle `.balanced` profile as a permanent quality ceiling.
    @discardableResult
    func setActivePreset(_ preset: StreamQualityPreset) -> StreamQualityPreset {
        activePreset = preset
        recomputeProfile()
        return profile.effectivePreset
    }

    func resetActivePreset() {
        activePreset = nil
        recomputeProfile()
    }

    func recomputeProfile() {
        profile = policyService.profile(
            preferredPreset: activePreset ?? preferredPresetProvider(),
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState
        )
    }
}
