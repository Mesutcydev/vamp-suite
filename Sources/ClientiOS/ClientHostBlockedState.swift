import Foundation
import SharedModels
import SharedProtocol

struct ClientHostBlockedState: Equatable {
    var title: String
    var message: String
    var blockedPermissions: [PermissionState]

    init(terminalOnlyHostNamed name: String) {
        self.title = "Terminal-only host"
        self.message = "\(name) is running Vamp Terminal Host. It provides terminal tabs, not screen sharing or remote control. Open Vamp Terminal for terminal access, or run Vamp Host on the Mac for this client."
        self.blockedPermissions = []
    }

    init(message: PermissionBlockedMessage) {
        self.blockedPermissions = message.blockedPermissions
        if message.reason == .terminalOnlyHost {
            self.title = "Use Vamp Terminal"
            self.message = "This Mac is running Vamp Terminal Host. It supports terminal tabs only. Open Vamp Terminal for the session, or start Vamp Host on the Mac to use screen sharing and remote control."
            return
        }

        self.title = "Host Permissions Needed"
        let names = message.blockedPermissions
            .map { $0.kind.clientTitle }
            .joined(separator: ", ")
        // The host sends an empty list pre-authentication (it won't reveal which permissions it lacks
        // to an unauthenticated client) and on a generic pipeline-start failure — so don't render
        // "approval for  before…" with a blank. Give actionable guidance instead.
        if names.isEmpty {
            self.message = "Vamp Host needs permission on the Mac before it can stream or accept control. On the Mac, open Vamp Host and grant Screen Recording (and Accessibility for control) — macOS can reset these after an app identity changes."
        } else {
            self.message = "Vamp Host needs approval for \(names) before streaming or control can start."
        }
    }
}

private extension PermissionKind {
    var clientTitle: String {
        switch self {
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
}
