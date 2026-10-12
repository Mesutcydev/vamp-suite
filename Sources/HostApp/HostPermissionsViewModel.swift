import Foundation
import Diagnostics
import Permissions
import SharedModels

@MainActor
final class HostPermissionsViewModel: ObservableObject {
    @Published private(set) var statuses: [FriendlyPermissionStatus] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastErrorMessage: String?

    private let permissionService: any PermissionServiceProtocol
    private let eventLogStore: any EventLogStoreProtocol
    private var previousStates: [PermissionKind: PermissionAuthorizationState] = [:]
    private var refreshPending = false

    init(
        permissionService: any PermissionServiceProtocol,
        eventLogStore: any EventLogStoreProtocol
    ) {
        self.permissionService = permissionService
        self.eventLogStore = eventLogStore
    }

    var blockers: [FriendlyPermissionStatus] {
        // A temporarily unknown TCC state means the privacy daemon is still
        // checking. Only a confirmed denial should block host readiness.
        statuses.filter { $0.isRequired && $0.authorizationState == .denied }
    }

    var allRequiredGranted: Bool {
        !statuses.isEmpty && blockers.isEmpty
    }

    var dashboardSummary: String {
        if statuses.isEmpty {
            return "Checking"
        }
        if allRequiredGranted {
            return "Ready"
        }
        return "\(blockers.count) blocker\(blockers.count == 1 ? "" : "s")"
    }

    var onboardingTitle: String {
        allRequiredGranted ? "Host Permissions Ready" : "Finish Host Setup"
    }

    var onboardingMessage: String {
        let hasRequiredAccessibility = statuses.contains { $0.kind == .accessibility && $0.isRequired }
        let hasOptionalAccessibility = statuses.contains { $0.kind == .accessibility && !$0.isRequired }
        if allRequiredGranted {
            if hasRequiredAccessibility {
                return "Screen streaming and input control permissions are ready."
            }
            return hasOptionalAccessibility
                ? "Screen Recording permission is ready. Accessibility is optional and enables Remote Unlock from the login window."
                : "Screen Recording permission is ready. This build streams in View Only mode."
        }
        if hasRequiredAccessibility {
            return "Screen Recording lets the host stream your display. Accessibility lets trusted clients send pointer and keyboard input."
        }
        return hasOptionalAccessibility
            ? "Screen Recording is required for streaming. Accessibility is optional and enables Remote Unlock from the login window."
            : "Screen Recording is required for streaming. This build runs in View Only mode — remote keyboard and pointer control are available in the direct-download host."
    }

    /// Re-read TCC state without presenting OS permission sheets. The parameter
    /// remains source-compatible with older host call sites; prompting is only
    /// allowed from an explicit user action.
    func refresh(requestOSPromptIfNeeded: Bool = true) async {
        _ = requestOSPromptIfNeeded
        if isRefreshing {
            refreshPending = true
            return
        }

        isRefreshing = true
        lastErrorMessage = nil

        repeat {
            refreshPending = false
            let newStatuses = await permissionService.friendlyStatuses()
            statuses = newStatuses
            await logPermissionChanges(newStatuses)
        } while refreshPending

        isRefreshing = false
    }

    /// Called by the explainer sheet on dismiss. The actual native request is
    /// made explicitly by the caller so a state refresh never races the TCC
    /// prompt it is trying to observe.
    func markExplainerShown() {
        UserDefaults.standard.set(true, forKey: "host.didShowPermissionExplainer")
    }

    /// True when the explainer has never been shown for this user account.
    var shouldShowExplainer: Bool {
        !UserDefaults.standard.bool(forKey: "host.didShowPermissionExplainer")
    }

    func retry(_ kind: PermissionKind) async {
        isRefreshing = true
        lastErrorMessage = nil
        let refreshed = await permissionService.refreshState(for: kind)
        var newStatuses = await permissionService.friendlyStatuses()
        if !newStatuses.contains(where: { $0.kind == kind }) {
            newStatuses.append(
                FriendlyPermissionStatus(
                    kind: refreshed.kind,
                    title: title(for: refreshed.kind),
                    summary: summary(for: refreshed.authorizationState),
                    helperText: helperText(for: refreshed.kind),
                    authorizationState: refreshed.authorizationState,
                    isRequired: true,
                    settingsButtonTitle: "Open Settings"
                )
            )
        }
        statuses = newStatuses
        await logPermissionChanges(newStatuses)
        isRefreshing = false
    }

    func requestPrompt(for kind: PermissionKind) async {
        do {
            _ = try await permissionService.requestPermission(for: kind)
            await refresh()
        } catch {
            lastErrorMessage = error.localizedDescription
            await eventLogStore.append(
                EventLogItem(
                    severity: .error,
                    category: "Permissions",
                    message: "Permission request failed for \(title(for: kind)): \(error.localizedDescription)"
                )
            )
        }
    }

    func openSettings(for kind: PermissionKind) async {
        do {
            // Register the TCC entry only when needed. The permission service
            // caps each native prompt to one per permission kind per process.
            switch kind {
            case .screenRecording, .accessibility:
                let current = await permissionService.refreshState(for: kind)
                if current.authorizationState != .granted {
                    _ = try await permissionService.requestPermission(for: kind)
                }
            case .localNetwork, .microphone:
                break
            }
            try await permissionService.openSettings(for: kind)
            await eventLogStore.append(
                EventLogItem(
                    severity: .info,
                    category: "Permissions",
                    message: "Opened settings for \(title(for: kind))"
                )
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            await eventLogStore.append(
                EventLogItem(
                    severity: .error,
                    category: "Permissions",
                    message: "Could not open settings for \(title(for: kind)): \(error.localizedDescription)"
                )
            )
        }
    }

    private func logPermissionChanges(_ statuses: [FriendlyPermissionStatus]) async {
        for status in statuses where status.isRequired {
            let previous = previousStates[status.kind]
            previousStates[status.kind] = status.authorizationState

            if status.authorizationState == .granted, previous != nil, previous != .granted {
                await eventLogStore.append(
                    EventLogItem(
                        severity: .info,
                        category: "Permissions",
                        message: "\(status.title) permission recovered"
                    )
                )
            } else if status.authorizationState != .granted, previous != status.authorizationState {
                await eventLogStore.append(
                    EventLogItem(
                        severity: .warning,
                        category: "Permissions",
                        message: "\(status.title) permission is blocking host readiness"
                    )
                )
            }
        }
    }

    private func title(for kind: PermissionKind) -> String {
        switch kind {
        case .screenRecording:
            return "Screen Recording"
        case .accessibility:
            return "Accessibility"
        case .localNetwork:
            return "Local Network"
        case .microphone:
            return "Microphone"
        }
    }

    private func summary(for state: PermissionAuthorizationState) -> String {
        switch state {
        case .unknown:
            return "Needs checking"
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Needs approval"
        case .granted:
            return "Ready"
        case .restricted:
            return "Restricted"
        }
    }

    private func helperText(for kind: PermissionKind) -> String {
        switch kind {
        case .screenRecording:
            return "Needed so ScreenCaptureKit can capture your Mac display for the remote stream."
        case .accessibility:
            return "Needed so trusted clients can control the pointer, keyboard, and shortcuts."
        case .localNetwork:
            return "Needed for LAN discovery and local signaling."
        case .microphone:
            return "Reserved for future audio support."
        }
    }
}
