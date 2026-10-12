import Foundation
import SharedModels

/// Combines Screen Recording probe signals without a first-wins race.
///
/// `CGPreflightScreenCaptureAccess()` and `SCShareableContent` disagree often:
/// after a grant in System Settings, ScreenCaptureKit can still fail until the
/// process relaunches, while CoreGraphics already reports granted. Treating an
/// early SCK error as denied made the Host UI ignore a real approval.
public enum ScreenRecordingPermissionResolver: Sendable {
    public enum PreflightSignal: Equatable, Sendable {
        case granted
        case denied
    }

    public enum ShareableContentSignal: Equatable, Sendable {
        case granted
        case deniedEmptyDisplays
        case error
    }

    /// Resolve the current Screen Recording authorization from the probes that
    /// have finished so far.
    ///
    /// - Parameters:
    ///   - preflight: Result of `CGPreflightScreenCaptureAccess()`, if it returned.
    ///   - shareableContent: Result of the ScreenCaptureKit probe, if it finished.
    ///   - timedOut: Whether the overall check budget elapsed.
    /// - Returns: A state when resolution is possible, otherwise `nil` to keep waiting.
    public static func resolve(
        preflight: PreflightSignal?,
        shareableContent: ShareableContentSignal?,
        timedOut: Bool
    ) -> PermissionAuthorizationState? {
        if preflight == .granted || shareableContent == .granted {
            return .granted
        }

        if shareableContent == .deniedEmptyDisplays {
            return .denied
        }

        // Both probes finished without a grant. An SCK settle/error plus a false
        // preflight is the normal "not approved yet" path for a fresh install.
        if preflight == .denied, shareableContent == .error {
            return .denied
        }

        if timedOut {
            // Prefer "Needs checking" when the privacy daemon may still be hung,
            // but surface denial when preflight already returned false.
            if preflight == .denied {
                return .denied
            }
            return .unknown
        }

        return nil
    }
}
