import Foundation
import OSLog

/// Centralizes the two-path wake — magic packet (`WakeOnLANService`) + Bonjour Wake-on-Demand
/// (`BonjourWakeService`) — that HostsScreen and MirrorScreen both trigger. Keeping it here means
/// the guard logic, error capture, and logging live in one place instead of being duplicated (and
/// silently drifting) across the two call sites.
struct WakeCoordinator {
    /// What actually happened, so the UI can give honest feedback instead of swallowing errors.
    enum Outcome {
        /// At least one wake signal was dispatched. This does NOT guarantee the Mac woke: magic
        /// packets are fire-and-forget, and an Apple-Silicon Mac on Wi-Fi only wakes via a LAN
        /// sleep proxy, with "Wake for network access" enabled.
        /// `wakeReady` is the host's advertised "Wake for network access" state (nil = unknown).
        case requestSent(magicPacket: Bool, bonjour: Bool, wakeReady: Bool?)
        /// Neither a MAC nor a Bonjour service name was known, so nothing could be sent.
        case noTarget
        /// A wake target existed but every attempted send failed.
        case failed(String)

        var userMessage: String {
            switch self {
            case .requestSent(_, _, let wakeReady):
                if wakeReady == false {
            return "Wake signal sent, but this Mac has “Wake for network access” turned off — enable it in Vamp Host settings, then try again."
                }
                return "Wake signal sent — give your Mac a few seconds to wake. (Apple-Silicon Macs on Wi-Fi need a Sleep Proxy on the network.)"
            case .noTarget:
                return "Can't wake this Mac yet. Connect to it once on the same Wi-Fi so its wake details are saved."
            case .failed(let reason):
                return "Couldn't send wake signal: \(reason)"
            }
        }

        var isError: Bool {
            switch self {
            case .requestSent: return false
            case .noTarget, .failed: return true
            }
        }
    }

    private static let logger = Logger(subsystem: "com.mesutcy.remotedesktop.terminal", category: "Wake")

    /// Fires both wake paths in parallel and reports what was actually dispatched.
    /// - Parameters:
    ///   - macAddress: Host MAC for the magic-packet path, when known.
    ///   - bonjourServiceName: Bonjour instance name for the Wake-on-Demand path, when known.
    ///   - targetHost: Last-known host address, used to derive a subnet broadcast.
    func wake(macAddress: String?, bonjourServiceName: String?, targetHost: String?, wakeSupported: Bool? = nil) async -> Outcome {
        guard macAddress != nil || bonjourServiceName != nil else {
            Self.logger.info("Wake skipped: no MAC and no Bonjour name available for target")
            return .noTarget
        }

        async let magic: Result<Bool, Error> = {
            guard let macAddress else { return .success(false) }
            do {
                try await WakeOnLANService().wake(macAddress: macAddress, targetHost: targetHost)
                Self.logger.info("Magic-packet wake dispatched")
                return .success(true)
            } catch {
                Self.logger.error("Magic-packet wake failed: \(error.localizedDescription, privacy: .public)")
                return .failure(error)
            }
        }()

        async let bonjourAttempted: Bool = {
            guard let bonjourServiceName else { return false }
            await BonjourWakeService().wake(serviceName: bonjourServiceName)
            return true
        }()

        let magicResult = await magic
        let bonjour = await bonjourAttempted

        var magicSent = false
        var magicError: Error?
        switch magicResult {
        case .success(let sent): magicSent = sent
        case .failure(let error): magicError = error
        }

        if magicSent || bonjour {
            return .requestSent(magicPacket: magicSent, bonjour: bonjour, wakeReady: wakeSupported)
        }
        if let magicError {
            let reason = (magicError as? WakeOnLANService.WakeError)?.errorDescription ?? magicError.localizedDescription
            return .failed(reason)
        }
        return .failed("no reachable wake path")
    }
}
