import Foundation

public enum NetworkQuality: String, CaseIterable, Codable, Hashable, Sendable {
    case excellent
    case good
    case fair
    case poor
    case reconnecting

    public var summaryText: String {
        switch self {
        case .excellent:
            return "Excellent"
        case .good:
            return "Good"
        case .fair:
            return "Fair"
        case .poor:
            return "Poor"
        case .reconnecting:
            return "Reconnecting"
        }
    }
}

/// Describes whether the host Mac currently accepts remote input.
///
/// Sent inside `HostStatusMessage` so the iOS client can surface a clear
/// "Mac is locked" overlay instead of silently dropping touches.
public enum HostLockState: String, Codable, Hashable, Sendable {
    /// Normal state — session is active and input is accepted.
    case unlockedActiveSession
    /// macOS is showing the lock screen or login window.
    /// Remote keyboard/mouse commands are rejected by the host.
    case lockedOrLoginWindow

    /// True when remote input should be blocked due to this state.
    public var blocksRemoteInput: Bool {
        self == .lockedOrLoginWindow
    }

    /// Short human-readable label shown in diagnostics and the host status bar.
    public var statusLabel: String {
        switch self {
        case .unlockedActiveSession: return "Unlocked"
        case .lockedOrLoginWindow:  return "Locked"
        }
    }
}

public enum SessionControlMode: String, CaseIterable, Codable, Hashable, Sendable {
    case fullControl
    case viewOnly

    public var title: String {
        switch self {
        case .fullControl:
            return "Full Control"
        case .viewOnly:
            return "View Only"
        }
    }

    public var blocksRemoteInput: Bool {
        self == .viewOnly
    }
}

public enum AppThermalState: String, CaseIterable, Codable, Hashable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    public var title: String {
        rawValue.capitalized
    }
}

public enum SessionPerformanceThrottleReason: String, Codable, Hashable, Sendable {
    case none
    case lowPower
    case thermalFair
    case thermalSerious
    case thermalCritical

    public var title: String {
        switch self {
        case .none:
            return "None"
        case .lowPower:
            return "Low Power Mode"
        case .thermalFair:
            return "Thermal Pressure"
        case .thermalSerious:
            return "Serious Thermal Pressure"
        case .thermalCritical:
            return "Critical Thermal Pressure"
        }
    }
}

public struct SessionMetricsSnapshot: Codable, Hashable, Sendable {
    public var measuredAt: Date
    public var framesPerSecond: Double?
    public var bitrateKbps: Double?
    public var latencyMs: Double?
    public var packetLossPercent: Double?
    public var codecName: String?
    public var displayName: String?
    public var connectionState: ConnectionState

    public init(
        measuredAt: Date = Date(),
        framesPerSecond: Double? = nil,
        bitrateKbps: Double? = nil,
        latencyMs: Double? = nil,
        packetLossPercent: Double? = nil,
        codecName: String? = nil,
        displayName: String? = nil,
        connectionState: ConnectionState
    ) {
        self.measuredAt = measuredAt
        self.framesPerSecond = framesPerSecond
        self.bitrateKbps = bitrateKbps
        self.latencyMs = latencyMs
        self.packetLossPercent = packetLossPercent
        self.codecName = codecName
        self.displayName = displayName
        self.connectionState = connectionState
    }
}

public struct SessionFeatureSettings: Codable, Hashable, Sendable {
    public var preferredQualityPreset: StreamQualityPreset
    public var showsStatsOverlay: Bool
    public var lowPowerModeEnabled: Bool
    public var prefersViewOnly: Bool

    public init(
        preferredQualityPreset: StreamQualityPreset = .balanced,
        showsStatsOverlay: Bool = false,
        lowPowerModeEnabled: Bool = false,
        prefersViewOnly: Bool = false
    ) {
        self.preferredQualityPreset = preferredQualityPreset
        self.showsStatsOverlay = showsStatsOverlay
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.prefersViewOnly = prefersViewOnly
    }
}

public struct StreamingPerformanceProfile: Codable, Hashable, Sendable {
    public var preferredPreset: StreamQualityPreset
    public var effectivePreset: StreamQualityPreset
    public var targetFrameRate: Int
    public var maxBitrateKbps: Int
    public var overlayRefreshInterval: TimeInterval
    public var throttleReason: SessionPerformanceThrottleReason

    public init(
        preferredPreset: StreamQualityPreset,
        effectivePreset: StreamQualityPreset,
        targetFrameRate: Int,
        maxBitrateKbps: Int,
        overlayRefreshInterval: TimeInterval,
        throttleReason: SessionPerformanceThrottleReason
    ) {
        self.preferredPreset = preferredPreset
        self.effectivePreset = effectivePreset
        self.targetFrameRate = targetFrameRate
        self.maxBitrateKbps = maxBitrateKbps
        self.overlayRefreshInterval = overlayRefreshInterval
        self.throttleReason = throttleReason
    }
}

public protocol NetworkQualityClassifying: Sendable {
    func classify(
        metrics: SessionMetricsSnapshot,
        isReconnecting: Bool
    ) -> NetworkQuality
}

public struct NetworkQualityIndicatorService: NetworkQualityClassifying {
    public init() {}

    public func classify(
        metrics: SessionMetricsSnapshot,
        isReconnecting: Bool
    ) -> NetworkQuality {
        if isReconnecting || metrics.connectionState == .reconnecting {
            return .reconnecting
        }

        var penalty = 0

        if let latencyMs = metrics.latencyMs {
            switch latencyMs {
            case ..<70:
                break
            case ..<130:
                penalty += 1
            case ..<220:
                penalty += 2
            default:
                penalty += 3
            }
        }

        if let packetLossPercent = metrics.packetLossPercent {
            switch packetLossPercent {
            case ..<0.75:
                break
            case ..<2:
                penalty += 1
            case ..<5:
                penalty += 2
            default:
                penalty += 3
            }
        }

        if let framesPerSecond = metrics.framesPerSecond {
            switch framesPerSecond {
            case 26...:
                break
            case 18..<26:
                penalty += 1
            case 10..<18:
                penalty += 2
            default:
                penalty += 3
            }
        }

        if let bitrateKbps = metrics.bitrateKbps, bitrateKbps < 1200 {
            penalty += 1
        }

        switch penalty {
        case ..<1:
            return .excellent
        case 1...2:
            return .good
        case 3...4:
            return .fair
        default:
            return .poor
        }
    }
}

public struct SessionStatsFormatter {
    public init() {}

    public func fpsText(for value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f fps", value)
    }

    public func bitrateText(for value: Double?) -> String {
        guard let value else { return "--" }
        if value >= 1000 {
            return String(format: "%.1f Mbps", value / 1000)
        }
        return String(format: "%.0f kbps", value)
    }

    public func latencyText(for value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f ms", value)
    }

    public func packetLossText(for value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f%%", value)
    }
}

public struct SessionPerformancePolicyService {
    public init() {}

    public func profile(
        preferredPreset: StreamQualityPreset,
        lowPowerModeEnabled: Bool,
        thermalState: AppThermalState
    ) -> StreamingPerformanceProfile {
        let throttleReason: SessionPerformanceThrottleReason
        if thermalState == .critical {
            throttleReason = .thermalCritical
        } else if thermalState == .serious {
            throttleReason = .thermalSerious
        } else if thermalState == .fair {
            throttleReason = .thermalFair
        } else if lowPowerModeEnabled {
            throttleReason = .lowPower
        } else {
            throttleReason = .none
        }

        let effectivePreset: StreamQualityPreset
        switch throttleReason {
        case .none:
            effectivePreset = preferredPreset
        case .lowPower, .thermalFair:
            effectivePreset = minPreset(preferredPreset, ceiling: .balanced)
        case .thermalSerious:
            effectivePreset = .performance
        case .thermalCritical:
            effectivePreset = .performance
        }

        let targetFrameRate: Int
        let maxBitrateKbps: Int
        let overlayRefreshInterval: TimeInterval

        switch throttleReason {
        case .none:
            // Mirror EncoderConfiguration.frameRate: 60 fps for quality/ultra,
            // 30 fps for balanced/performance.  Keeps the diagnostics display
            // and any future runtime cap consistent with the actual encoder.
            targetFrameRate = (effectivePreset == .ultra || effectivePreset == .quality) ? 60 : 30
            // Headroom for native-resolution ultra (4K/5K HEVC can hit ~40 Mbps).
            // Lower presets are bounded by their own bits-per-pixel formula
            // and never approach this cap.
            maxBitrateKbps = 50_000
            overlayRefreshInterval = 1.0
        case .lowPower:
            targetFrameRate = 24
            maxBitrateKbps = 4_500
            overlayRefreshInterval = 1.5
        case .thermalFair:
            targetFrameRate = 24
            maxBitrateKbps = 4_000
            overlayRefreshInterval = 1.5
        case .thermalSerious:
            targetFrameRate = 18
            maxBitrateKbps = 2_500
            overlayRefreshInterval = 2.0
        case .thermalCritical:
            targetFrameRate = 12
            maxBitrateKbps = 1_800
            overlayRefreshInterval = 3.0
        }

        return StreamingPerformanceProfile(
            preferredPreset: preferredPreset,
            effectivePreset: effectivePreset,
            targetFrameRate: targetFrameRate,
            maxBitrateKbps: maxBitrateKbps,
            overlayRefreshInterval: overlayRefreshInterval,
            throttleReason: throttleReason
        )
    }

    private func minPreset(
        _ preset: StreamQualityPreset,
        ceiling: StreamQualityPreset
    ) -> StreamQualityPreset {
        let ranking: [StreamQualityPreset] = [.performance, .balanced, .quality, .ultra]
        guard
            let presetIndex = ranking.firstIndex(of: preset),
            let ceilingIndex = ranking.firstIndex(of: ceiling)
        else {
            return ceiling
        }
        return ranking[min(presetIndex, ceilingIndex)]
    }
}
