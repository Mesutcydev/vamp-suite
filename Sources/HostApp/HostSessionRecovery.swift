import CaptureEngine
import Diagnostics
import Foundation
import Permissions
import SharedModels
import SharedProtocol
import TransportWebRTC
import os

#if canImport(OSLog)
import OSLog
#endif

/// Host-side session recovery coordinator.
/// On reconnect or state change, re-sends display layout, permission state,
/// restarts capture if needed, and refreshes shareable content.
@MainActor
final class HostSessionRecovery: ObservableObject {

    enum RecoveryState: String, Equatable {
        case idle
        case recovering
        case recovered
        case failed
    }

    @Published private(set) var recoveryState: RecoveryState = .idle
    @Published private(set) var lastRecoveryError: String?
    @Published private(set) var recoveryCount: Int = 0

    private let captureEngine: any CaptureEngineProtocol
    private let displayLayoutProvider: any DisplayLayoutProviding
    private let permissionService: any PermissionServiceProtocol
    private let webRTCSessionManager: any WebRTCSessionManaging
    private let eventLogStore: any EventLogStoreProtocol
    private let hostIdentity: HostIdentity
    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "SessionRecovery")

    private var lastKnownDisplayID: String?
    private var lastKnownQualityPreset: StreamQualityPreset = .balanced

    init(
        hostIdentity: HostIdentity,
        captureEngine: any CaptureEngineProtocol,
        displayLayoutProvider: any DisplayLayoutProviding,
        permissionService: any PermissionServiceProtocol,
        webRTCSessionManager: any WebRTCSessionManaging,
        eventLogStore: any EventLogStoreProtocol
    ) {
        self.hostIdentity = hostIdentity
        self.captureEngine = captureEngine
        self.displayLayoutProvider = displayLayoutProvider
        self.permissionService = permissionService
        self.webRTCSessionManager = webRTCSessionManager
        self.eventLogStore = eventLogStore
    }

    // MARK: - State Tracking

    /// Remember the last active display and quality for recovery.
    func recordActiveSession(displayID: String, qualityPreset: StreamQualityPreset) {
        lastKnownDisplayID = displayID
        lastKnownQualityPreset = qualityPreset
    }

    // MARK: - Full Recovery

    /// Perform a full recovery sequence after reconnection.
    /// Steps:
    /// 1. Refresh and re-send permission state
    /// 2. Refresh and re-send display layout
    /// 3. Restart capture if needed
    /// 4. Notify the client that the session is ready
    func performRecovery(sessionID: UUID) async {
        recoveryState = .recovering
        lastRecoveryError = nil
        logger.info("Starting session recovery for \(sessionID)")

        do {
            // Step 1: Re-check permissions
            let permissions = await permissionService.currentStates()
            let blocked = permissions.filter { $0.authorizationState == .denied }

            if !blocked.isEmpty {
                logger.warning("Permissions blocked during recovery: \(blocked.map(\.kind.rawValue))")
                let envelope = try DataChannelEnvelope.error(ErrorMessage(
                    code: "permission_blocked",
                    message: "Host permissions need approval: \(blocked.map(\.kind.rawValue).joined(separator: ", "))",
                    isRecoverable: true
                ))
                try webRTCSessionManager.sendDataMessage(envelope)
                // Continue with partial recovery — client will show blocked state
            }

            // Step 2: Refresh display layout and send to client
            let layout = try await displayLayoutProvider.currentDisplayLayout()
            let layoutMessage = DisplayLayoutMessage(layout: layout)
            let layoutEnvelope = try DataChannelEnvelope.displayLayout(layoutMessage)
            try webRTCSessionManager.sendDataMessage(layoutEnvelope)
            logger.info("Re-sent display layout with \(layout.displays.count) display(s)")

            // Step 3: Restart capture if it was previously running
            await restartCaptureIfNeeded(layout: layout)

            // Step 4: Send host status indicating readiness
            let statusMsg = HostStatusMessage(
                hostID: hostIdentity.id,
                connectionState: .connected,
                activeSessionID: sessionID,
                displayLayout: layout
            )
            let statusEnvelope = try DataChannelEnvelope.hostStatus(statusMsg)
            try webRTCSessionManager.sendDataMessage(statusEnvelope)

            recoveryState = .recovered
            recoveryCount += 1
            logger.info("Session recovery completed successfully (recovery #\(self.recoveryCount))")

            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Recovery",
                message: "Session recovery #\(recoveryCount) completed"
            ))

        } catch {
            recoveryState = .failed
            lastRecoveryError = error.localizedDescription
            logger.error("Session recovery failed: \(error.localizedDescription)")

            await eventLogStore.append(EventLogItem(
                severity: .error,
                category: "Recovery",
                message: "Session recovery failed: \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - Capture Recovery

    /// Restart capture for the last known display, or the primary display.
    private func restartCaptureIfNeeded(layout: DisplayLayout) async {
        // Determine which display to capture
        let targetDisplayID: String?
        if let last = lastKnownDisplayID, layout.display(withID: last) != nil {
            targetDisplayID = last
        } else {
            targetDisplayID = layout.primaryDisplayID
        }

        guard let displayID = targetDisplayID else {
            logger.warning("No display available for capture recovery")
            return
        }

        // Only restart if capture is not already running for this display
        if captureEngine.captureState == .running
            && captureEngine.diagnostics.currentDisplayID == displayID {
            logger.info("Capture already running for display \(displayID), skipping restart")
            return
        }

        do {
            // Stop existing capture gracefully
            if captureEngine.isCapturing {
                await captureEngine.stopCapture()
            }
            try await captureEngine.startCapture(displayID: displayID, qualityPreset: lastKnownQualityPreset)
            lastKnownDisplayID = displayID
            logger.info("Capture restarted for display \(displayID)")
        } catch {
            logger.error("Capture restart failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Display Change Recovery

    /// Called when the host detects a display configuration change.
    func handleDisplayConfigurationChange() async {
        logger.info("Display configuration change detected")

        do {
            let layout = try await displayLayoutProvider.currentDisplayLayout()

            // Send updated layout to client
            let layoutMessage = DisplayLayoutMessage(layout: layout)
            let layoutEnvelope = try DataChannelEnvelope.displayLayout(layoutMessage)
            try webRTCSessionManager.sendDataMessage(layoutEnvelope)

            // Check if our current display is still valid
            if let lastID = lastKnownDisplayID, layout.display(withID: lastID) == nil {
                logger.warning("Previously selected display \(lastID) no longer available")
                // Fall back to primary
                if let primaryID = layout.primaryDisplayID {
                    lastKnownDisplayID = primaryID
                    await restartCaptureIfNeeded(layout: layout)
                }
            }

            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Recovery",
                message: "Display configuration updated: \(layout.displays.count) display(s)"
            ))
        } catch {
            logger.error("Failed to handle display change: \(error.localizedDescription)")
        }
    }

    // MARK: - Permission Change Recovery

    /// Called when the host detects a permission state change.
    func handlePermissionChange(sessionID: UUID) async {
        let permissions = await permissionService.currentStates()
        let blocked = permissions.filter { $0.authorizationState == .denied }

        if blocked.isEmpty {
            logger.info("All permissions granted — session can proceed")
        } else {
            logger.warning("Permissions revoked: \(blocked.map(\.kind.rawValue))")
            do {
                let envelope = try DataChannelEnvelope.error(ErrorMessage(
                    code: "permission_blocked",
                    message: "Host permissions revoked: \(blocked.map(\.kind.rawValue).joined(separator: ", "))",
                    isRecoverable: true
                ))
                try webRTCSessionManager.sendDataMessage(envelope)
            } catch {
                logger.error("Failed to send permission blocked message: \(error.localizedDescription)")
            }
        }
    }

    /// Reset recovery state.
    func reset() {
        recoveryState = .idle
        lastRecoveryError = nil
    }
}
