import AppKit
import Foundation
import Diagnostics
import Discovery
import Permissions
import SharedModels
import TransportWebRTC

/// Builds the shared `ClientAppEnvironment` (reused unmodified from the iOS
/// client sources) with Mac-appropriate identity values.
@MainActor
enum MacClientEnvironmentFactory {

    static func make() -> ClientAppEnvironment {
        let cryptoIdentity = CryptoIdentityService(tag: "com.remotedesktop.client.p256")
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let client = ClientIdentity(
            // A reconnecting Mac must keep the same signaling peer ID across app
            // launches. The public-key fingerprint is persistent and already is
            // the trust anchor, so derive the UUID from it just like the iOS
            // client does. A random UUID here made the host reject the same Mac
            // as a second device while the prior transport was in its grace period.
            id: ClientIdentity.stableID(publicKeyFingerprint: cryptoIdentity.fingerprint) ?? UUID(),
            displayName: Foundation.Host.current().localizedName ?? "Mac",
            deviceModel: "Mac",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: appVersion,
            publicKeyFingerprint: cryptoIdentity.fingerprint
        )

        let trustedPeerStore = PersistentTrustedPeerStore()
        let browser = BonjourHostDiscoveryBrowser()
        let signalingService = BonjourSignalingService()
        signalingService.identityService = cryptoIdentity
        let peerConnectionProvider = LANPeerConnectionProvider()
        let webRTCSessionManager = WebRTCSessionManager(peerConnectionProvider: peerConnectionProvider)
        let displayLayoutViewModel = DisplayLayoutViewModel()
        let eventLogStore = InMemoryEventLogStore()
        let sessionCoordinator = ClientSessionCoordinator(
            clientIdentity: client,
            isMacClient: true,
            webRTCSessionManager: webRTCSessionManager,
            peerConnectionProvider: peerConnectionProvider,
            eventLogStore: eventLogStore,
            signalingService: signalingService,
            displayLayoutViewModel: displayLayoutViewModel
        )

        let settingsSyncService = ClientSettingsSyncService()

        let environment = ClientAppEnvironment(
            clientIdentity: client,
            discoveryService: browser,
            signalingService: signalingService,
            webRTCSessionManager: webRTCSessionManager,
            eventLogStore: eventLogStore,
            peerConnectionProvider: peerConnectionProvider,
            hostBrowser: browser,
            displayLayoutViewModel: displayLayoutViewModel,
            trustedPeerStore: trustedPeerStore,
            sessionCoordinator: sessionCoordinator,
            settingsSyncService: settingsSyncService
        )

        // A Mac has ample HEVC decode headroom, so `.quality` — not the
        // phone-sized cross-platform `.balanced` — is the right floor. This used
        // to run only on a fresh install, which left every already-installed Mac
        // streaming at Balanced forever. The promotion now runs once per install
        // and never lowers a preset the user picked themselves.
        if let promoted = MacStreamingQualityPolicy.promotedPreset(
            current: environment.preferredQualityPreset,
            supportsUltra: environment.isUltraQualityEntitled
        ) {
            environment.preferredQualityPreset = promoted
        }

        return environment
    }
}
