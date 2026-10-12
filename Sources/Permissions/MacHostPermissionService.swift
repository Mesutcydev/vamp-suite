import Foundation
import SharedModels

#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

public final class MacHostPermissionService: PermissionServiceProtocol {
    private let policy: MacHostRuntimePolicy
    /// Hard cap: each permission kind may present at most one OS sheet per process.
    private static let osPromptLock = NSLock()
    private static var osPromptedKinds: Set<PermissionKind> = []

    public init(policy: MacHostRuntimePolicy = .current) {
        self.policy = policy
    }

    public func currentStates() async -> [PermissionState] {
        guard policy.supportsScreenCapture else { return [] }
        var states = [await screenRecordingState()]
        if policy.requiresAccessibilityPermission {
            states.append(refreshStateSync(for: .accessibility))
        }
        return states
    }

    public func refreshState(for kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .screenRecording:
            guard policy.supportsScreenCapture else {
                return PermissionState(kind: kind, authorizationState: .restricted, lastCheckedAt: Date())
            }
            return await screenRecordingState()
        case .accessibility, .localNetwork, .microphone:
            return refreshStateSync(for: kind)
        }
    }

    public func requestPermission(for kind: PermissionKind) async throws -> PermissionState {
        switch kind {
        case .screenRecording:
            guard policy.supportsScreenCapture else {
                return PermissionState(kind: kind, authorizationState: .restricted, lastCheckedAt: Date())
            }
            if CGPreflightScreenCaptureAccess() {
                return await screenRecordingState()
            }
            guard Self.claimOSPrompt(for: .screenRecording) else {
                return await screenRecordingState()
            }
            await MainActor.run {
                NSApplication.shared.activate(ignoringOtherApps: true)
                _ = CGRequestScreenCaptureAccess()
            }
        case .accessibility:
            guard policy.canRequestAccessibilityPermission else {
                return refreshStateSync(for: kind)
            }
            if AXIsProcessTrusted() {
                return refreshStateSync(for: kind)
            }
            guard Self.claimOSPrompt(for: .accessibility) else {
                return refreshStateSync(for: kind)
            }
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            await MainActor.run {
                _ = AXIsProcessTrustedWithOptions(options)
            }
        case .localNetwork, .microphone:
            break
        }
        return await refreshState(for: kind)
    }

    private static func claimOSPrompt(for kind: PermissionKind) -> Bool {
        osPromptLock.lock()
        defer { osPromptLock.unlock() }
        if osPromptedKinds.contains(kind) { return false }
        osPromptedKinds.insert(kind)
        return true
    }

    public func friendlyStatuses() async -> [FriendlyPermissionStatus] {
        guard policy.supportsScreenCapture else { return [] }
        let screenRecording = await screenRecordingState()

        var statuses = [FriendlyPermissionStatus(
            kind: .screenRecording,
            title: title(for: .screenRecording),
            summary: summary(for: .screenRecording, state: screenRecording.authorizationState, isRequired: true),
            helperText: helperText(for: .screenRecording),
            authorizationState: screenRecording.authorizationState,
            isRequired: true,
            settingsButtonTitle: settingsButtonTitle(for: .screenRecording)
        )]

        if policy.canRequestAccessibilityPermission {
            let accessibility = refreshStateSync(for: .accessibility)
            statuses.append(FriendlyPermissionStatus(
                kind: .accessibility,
                title: title(for: .accessibility),
                summary: summary(for: .accessibility, state: accessibility.authorizationState, isRequired: policy.requiresAccessibilityPermission),
                helperText: helperText(for: .accessibility),
                authorizationState: accessibility.authorizationState,
                isRequired: policy.requiresAccessibilityPermission,
                settingsButtonTitle: settingsButtonTitle(for: .accessibility)
            ))
        }

        return statuses
    }

    public func openSettings(for kind: PermissionKind) async throws {
        guard policy.supportsScreenCapture || kind != .screenRecording else { return }
        if kind == .accessibility && !policy.canRequestAccessibilityPermission {
            return
        }
        guard let url = settingsURL(for: kind) else {
            return
        }
        _ = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshStateSync(for kind: PermissionKind) -> PermissionState {
        let authorizationState: PermissionAuthorizationState
        switch kind {
        case .screenRecording:
            authorizationState = CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .accessibility:
            authorizationState = policy.canRequestAccessibilityPermission
                ? (AXIsProcessTrusted() ? .granted : .denied)
                : .restricted
        case .localNetwork, .microphone:
            authorizationState = .unknown
        }
        return PermissionState(kind: kind, authorizationState: authorizationState, lastCheckedAt: Date())
    }

    private func screenRecordingState() async -> PermissionState {
        // Never call ScreenCaptureKit while CoreGraphics says access is denied:
        // SCShareableContent can present the native permission sheet during a
        // polling refresh, which caused repeated prompts during host setup.
        // Keep the synchronous preflight off Swift's cooperative pool because
        // the macOS privacy daemon can stall it on some OS releases.
        let preflightGranted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: CGPreflightScreenCaptureAccess())
            }
        }

        if !preflightGranted {
            return PermissionState(
                kind: .screenRecording,
                authorizationState: .denied,
                lastCheckedAt: Date()
            )
        }

        // Once preflight is granted, SCK is only a settling/availability check;
        // trust the grant if the probe is still catching up after System Settings.
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            var shareableContent: ScreenRecordingPermissionResolver.ShareableContentSignal?
            var timedOut = false

            @inline(__always)
            func withLock<T>(_ body: () -> T) -> T {
                lock.lock()
                defer { lock.unlock() }
                return body()
            }

            func considerResolve() {
                let result: PermissionAuthorizationState? = withLock {
                    guard !resumed else { return nil }
                    guard let state = ScreenRecordingPermissionResolver.resolve(
                        preflight: .granted,
                        shareableContent: shareableContent,
                        timedOut: timedOut
                    ) else { return nil }
                    resumed = true
                    return state
                }
                guard let result else { return }
                continuation.resume(returning: PermissionState(
                    kind: .screenRecording,
                    authorizationState: result,
                    lastCheckedAt: Date()
                ))
            }

            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    withLock {
                        shareableContent = content.displays.isEmpty ? .deniedEmptyDisplays : .granted
                    }
                } catch {
                    withLock { shareableContent = .error }
                }
                considerResolve()
            }

            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                withLock { timedOut = true }
                considerResolve()
            }
        }
    }

    private func settingsURL(for kind: PermissionKind) -> URL? {
        // macOS 13+ uses the PrivacySecurity extension URL scheme.
        // The old com.apple.preference.security scheme stopped working on macOS 13+.
        switch kind {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
        case .localNetwork:
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork")
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")
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

    private func helperText(for kind: PermissionKind) -> String {
        switch kind {
        case .screenRecording:
            return "Needed so ScreenCaptureKit can capture your Mac display for the remote stream. If an older MacHost build is already approved, enable this updated build in System Settings and relaunch it."
        case .accessibility:
            if policy.canRequestAccessibilityPermission {
                if policy.supportsRemoteInput {
                    return "Needed so trusted clients can control the pointer, keyboard, and shortcuts. If only an older MacHost build is listed as approved, re-enable this updated build in System Settings."
                }
                return "Needed so trusted clients can type your Mac login password from the lock screen when Remote Unlock is enabled. If only an older MacHost build is listed as approved, re-enable this updated build in System Settings."
            }
            return "This sandboxed build runs in View Only mode because it cannot inject keyboard or pointer events."
        case .localNetwork:
            return "Needed for LAN discovery and local signaling."
        case .microphone:
            return "Reserved for future audio support."
        }
    }

    private func summary(for kind: PermissionKind, state: PermissionAuthorizationState, isRequired: Bool) -> String {
        if kind == .accessibility && !isRequired {
            return "Not available in this build"
        }
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

    private func settingsButtonTitle(for kind: PermissionKind) -> String {
        switch kind {
        case .screenRecording:
            return "Open Screen Recording"
        case .accessibility:
            if !policy.canRequestAccessibilityPermission {
                return "Sandboxed View Only"
            }
            return "Open Accessibility"
        case .localNetwork:
            return "Open Local Network"
        case .microphone:
            return "Open Microphone"
        }
    }
}
#endif
