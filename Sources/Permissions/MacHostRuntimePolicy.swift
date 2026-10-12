import Foundation
import SharedModels

public struct MacHostRuntimePolicy: Sendable, Equatable {
    public let isSandboxedDistribution: Bool
    public let isTerminalOnly: Bool

    public init(isSandboxedDistribution: Bool, isTerminalOnly: Bool = false) {
        self.isSandboxedDistribution = isSandboxedDistribution
        self.isTerminalOnly = isTerminalOnly
    }

    public static var current: MacHostRuntimePolicy {
        resolved(
            distributionChannel: Bundle.main.object(forInfoDictionaryKey: "VampDistributionChannel") as? String,
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// Store restrictions also apply to unsigned development builds. An actual
    /// sandbox always wins over the distribution label.
    public static func resolved(distributionChannel: String?, environment: [String: String]) -> MacHostRuntimePolicy {
        MacHostRuntimePolicy(isSandboxedDistribution:
            distributionChannel == "app-store" || environment["APP_SANDBOX_CONTAINER_ID"] != nil)
    }

    public var supportsApplicationManagement: Bool { supportsRemoteInput }
    public var supportsWindowResizing: Bool { supportsRemoteInput }
    public var supportsTerminalSessions: Bool { !isSandboxedDistribution }
    public var supportsBrowserControl: Bool { !isSandboxedDistribution }

    public static var terminalOnly: MacHostRuntimePolicy {
        MacHostRuntimePolicy(
            isSandboxedDistribution: current.isSandboxedDistribution,
            isTerminalOnly: true
        )
    }

    public var supportsRemoteInput: Bool {
        !isSandboxedDistribution && !isTerminalOnly
    }

    public var supportsRemoteUnlock: Bool {
        supportsRemoteInput
    }

    public var requiresAccessibilityPermission: Bool {
        supportsRemoteInput
    }

    public var supportsScreenCapture: Bool {
        !isTerminalOnly
    }

    public var canRequestAccessibilityPermission: Bool {
        supportsRemoteInput
    }

    public var enforcedSessionMode: SessionControlMode? {
        supportsRemoteInput ? nil : .viewOnly
    }

    public var distributionTitle: String {
        isSandboxedDistribution ? "Sandboxed Build" : "Direct Distribution Build"
    }
}
