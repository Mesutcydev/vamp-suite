import Foundation
import Network
import OSLog
import dnssd
import Discovery

/// Triggers Bonjour Wake-on-Demand for a sleeping host.
///
/// The resolve goes through `DNSServiceResolve` with `kDNSServiceFlagsWakeOnResolve`,
/// which makes mDNSResponder send a magic packet to the record owner's MAC — this is
/// the documented Wake on Demand path. The LAN's Sleep Proxy (Apple TV, HomePod,
/// always-on Mac) or the sleeping Mac's own NIC mDNS offload answers the query while
/// the host sleeps. A plain Network.framework resolve does NOT set this flag, so it
/// never wakes anything by itself.
///
/// After a successful resolve we also open a TCP connection to the resolved endpoint:
/// the SYN to an offloaded service port is the second wake trigger (sleep proxies and
/// NIC offload wake the host on inbound TCP to any port it had registered).
struct BonjourWakeService {
    private static let logger = Logger(subsystem: "com.mesutcy.remotedesktop.terminal", category: "BonjourWake")
    private static let queue = DispatchQueue(label: "com.mesutcy.remotedesktop.terminal.bonjour-wake")

    func wake(
        serviceName: String,
        serviceType: String = LANDiscoveryConstants.serviceType,
        domain: String = LANDiscoveryConstants.defaultDomain,
        timeout: TimeInterval = 6
    ) async {
        // Service name (the Mac's display name) and resolved host are device identifiers — keep them
        // private so they don't leak into the unified log in release builds; flow/error text stays public.
        Self.logger.info("Bonjour wake starting for \(serviceName, privacy: .private)")

        guard let resolved = await resolveWithWakeFlag(
            name: serviceName,
            type: serviceType,
            domain: domain,
            timeout: timeout
        ) else {
            // The wake-on-resolve query was still multicast onto the LAN; a sleep proxy
            // may act on it even though nothing answered us within the timeout.
            Self.logger.info("Bonjour wake: no resolve answer for \(serviceName, privacy: .private) (wake query was still sent)")
            return
        }

        Self.logger.info("Bonjour wake resolved \(resolved.host, privacy: .private):\(resolved.port) — sending TCP SYN")
        await attemptTCPConnection(host: resolved.host, port: resolved.port, timeout: timeout)
        Self.logger.info("Bonjour wake finished for \(serviceName, privacy: .private)")
    }

    // MARK: - DNSServiceResolve with kDNSServiceFlagsWakeOnResolve

    private final class ResolveState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(host: String, port: UInt16)?, Never>?
        var serviceRef: DNSServiceRef?

        init(continuation: CheckedContinuation<(host: String, port: UInt16)?, Never>) {
            self.continuation = continuation
        }

        /// Resumes the continuation exactly once; returns false on repeat calls.
        func finish(_ result: (host: String, port: UInt16)?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let continuation else { return false }
            self.continuation = nil
            continuation.resume(returning: result)
            return true
        }

        func cleanup() {
            lock.lock()
            defer { lock.unlock() }
            if let serviceRef {
                DNSServiceRefDeallocate(serviceRef)
                self.serviceRef = nil
            }
        }
    }

    private func resolveWithWakeFlag(
        name: String,
        type: String,
        domain: String,
        timeout: TimeInterval
    ) async -> (host: String, port: UInt16)? {
        await withCheckedContinuation { (continuation: CheckedContinuation<(host: String, port: UInt16)?, Never>) in
            let state = ResolveState(continuation: continuation)
            let context = Unmanaged.passRetained(state).toOpaque()

            var serviceRef: DNSServiceRef?
            let error = DNSServiceResolve(
                &serviceRef,
                DNSServiceFlags(kDNSServiceFlagsWakeOnResolve),
                0, // kDNSServiceInterfaceIndexAny
                name,
                type,
                domain,
                { _, _, _, errorCode, _, hostTarget, port, _, _, context in
                    guard let context else { return }
                    let state = Unmanaged<ResolveState>.fromOpaque(context).takeUnretainedValue()

                    var result: (host: String, port: UInt16)?
                    if errorCode == DNSServiceErrorType(kDNSServiceErr_NoError), let hostTarget {
                        result = (host: String(cString: hostTarget), port: UInt16(bigEndian: port))
                    }
                    guard state.finish(result) else { return }
                    // Defer teardown until after this callback returns; both run on `queue`.
                    BonjourWakeService.queue.async {
                        state.cleanup()
                        Unmanaged<ResolveState>.fromOpaque(context).release()
                    }
                },
                context
            )

            guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let serviceRef else {
                Self.logger.error("Bonjour wake: DNSServiceResolve failed to start (\(error))")
                _ = state.finish(nil)
                Unmanaged<ResolveState>.fromOpaque(context).release()
                return
            }

            state.serviceRef = serviceRef
            DNSServiceSetDispatchQueue(serviceRef, Self.queue)

            Self.queue.asyncAfter(deadline: .now() + timeout) {
                guard state.finish(nil) else { return }
                state.cleanup()
                // Balance the `passRetained` above without capturing the non-Sendable raw pointer.
                Unmanaged.passUnretained(state).release()
            }
        }
    }

    // MARK: - TCP SYN to the resolved endpoint

    private func attemptTCPConnection(host: String, port: UInt16, timeout: TimeInterval) async {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            final class ResumeGate: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false
                func take() -> Bool {
                    lock.lock(); defer { lock.unlock() }
                    guard !resumed else { return false }
                    resumed = true
                    return true
                }
            }
            let gate = ResumeGate()

            @Sendable func finish() {
                guard gate.take() else { return }
                connection.cancel()
                continuation.resume()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Self.logger.info("Bonjour wake: connection ready (host responded)")
                    finish()
                case .failed(let error):
                    // Failure is expected and fine — the SYN itself is the wake trigger.
                    Self.logger.info("Bonjour wake SYN sent, connection failed: \(error.localizedDescription, privacy: .public)")
                    finish()
                case .cancelled:
                    finish()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))

            Task {
                try? await Task.sleep(for: .seconds(timeout))
                finish()
            }
        }
    }
}
