import XCTest
@testable import Permissions
@testable import SharedModels

/// The runtime policy is the gate that makes terminal-only mode non-negotiable:
/// a light host must never expose remote input, unlock, or screen capture no
/// matter what a peer requests. These tests pin that contract.
final class MacHostRuntimePolicyTests: XCTestCase {
    func testStoreRestrictionsApplyWithoutSandboxEnvironment() {
        let policy = MacHostRuntimePolicy.resolved(distributionChannel: "app-store", environment: [:])
        XCTAssertFalse(policy.supportsRemoteInput)
        XCTAssertFalse(policy.canRequestAccessibilityPermission)
        XCTAssertFalse(policy.supportsApplicationManagement)
        XCTAssertFalse(policy.supportsWindowResizing)
        XCTAssertFalse(policy.supportsTerminalSessions)
        XCTAssertFalse(policy.supportsBrowserControl)
        XCTAssertTrue(policy.supportsScreenCapture)
        XCTAssertEqual(policy.enforcedSessionMode, .viewOnly)
    }

    func testWebsiteLabelCannotOverrideActualSandbox() {
        let policy = MacHostRuntimePolicy.resolved(
            distributionChannel: "website", environment: ["APP_SANDBOX_CONTAINER_ID": "test-container"])
        XCTAssertFalse(policy.supportsRemoteInput)
        XCTAssertFalse(policy.supportsApplicationManagement)
        XCTAssertEqual(policy.enforcedSessionMode, .viewOnly)
    }

    func testWebsiteBuildPreservesControlAndUpdateCapabilities() {
        let policy = MacHostRuntimePolicy.resolved(distributionChannel: "website", environment: [:])
        XCTAssertTrue(policy.supportsRemoteInput)
        XCTAssertTrue(policy.supportsWindowResizing)
        XCTAssertTrue(policy.supportsApplicationManagement)
        XCTAssertTrue(policy.supportsTerminalSessions)
        XCTAssertTrue(policy.supportsBrowserControl)
    }

    func testFullDirectDistributionHostEnablesEverything() {
        let policy = MacHostRuntimePolicy(isSandboxedDistribution: false, isTerminalOnly: false)
        XCTAssertTrue(policy.supportsRemoteInput)
        XCTAssertTrue(policy.supportsRemoteUnlock)
        XCTAssertTrue(policy.requiresAccessibilityPermission)
        XCTAssertTrue(policy.supportsScreenCapture)
        XCTAssertTrue(policy.canRequestAccessibilityPermission)
        XCTAssertNil(policy.enforcedSessionMode)
        XCTAssertEqual(policy.distributionTitle, "Direct Distribution Build")
    }

    func testTerminalOnlyHostRejectsInputUnlockAndCapture() {
        let policy = MacHostRuntimePolicy(isSandboxedDistribution: false, isTerminalOnly: true)
        XCTAssertFalse(policy.supportsRemoteInput)
        XCTAssertFalse(policy.supportsRemoteUnlock)
        XCTAssertFalse(policy.requiresAccessibilityPermission)
        XCTAssertFalse(policy.supportsScreenCapture)
        XCTAssertFalse(policy.canRequestAccessibilityPermission)
        XCTAssertEqual(policy.enforcedSessionMode, .viewOnly)
    }

    func testSandboxedHostBlocksRemoteInputButKeepsCapture() {
        let policy = MacHostRuntimePolicy(isSandboxedDistribution: true, isTerminalOnly: false)
        XCTAssertFalse(policy.supportsRemoteInput)
        XCTAssertFalse(policy.supportsRemoteUnlock)
        XCTAssertFalse(policy.requiresAccessibilityPermission)
        XCTAssertTrue(policy.supportsScreenCapture)
        XCTAssertFalse(policy.canRequestAccessibilityPermission)
        XCTAssertEqual(policy.enforcedSessionMode, .viewOnly)
        XCTAssertEqual(policy.distributionTitle, "Sandboxed Build")
    }

    func testSandboxedTerminalOnlyHostDisablesEverything() {
        let policy = MacHostRuntimePolicy(isSandboxedDistribution: true, isTerminalOnly: true)
        XCTAssertFalse(policy.supportsRemoteInput)
        XCTAssertFalse(policy.supportsRemoteUnlock)
        XCTAssertFalse(policy.supportsScreenCapture)
        XCTAssertEqual(policy.enforcedSessionMode, .viewOnly)
    }

    func testTerminalOnlyFactoryMarksTerminalOnly() {
        XCTAssertTrue(MacHostRuntimePolicy.terminalOnly.isTerminalOnly)
        XCTAssertFalse(MacHostRuntimePolicy.terminalOnly.supportsScreenCapture)
    }

    func testPolicyEqualityDistinguishesModes() {
        let full = MacHostRuntimePolicy(isSandboxedDistribution: false, isTerminalOnly: false)
        let light = MacHostRuntimePolicy(isSandboxedDistribution: false, isTerminalOnly: true)
        XCTAssertNotEqual(full, light)
        XCTAssertEqual(light, MacHostRuntimePolicy(isSandboxedDistribution: false, isTerminalOnly: true))
    }
}
