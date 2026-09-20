import Combine
import Foundation

/// Owns the explicit Vamp Assistant connection flow. Vamp Assistant is deliberately not folded into Vamp
/// discovery: its one-time pairing code and bearer token belong to a separate HTTP protocol.
@MainActor
final class BeetCodeRemoteSessionViewModel: ObservableObject {
    enum Availability: Equatable {
        case checking
        case reachable
        case unavailable

        /// Receiving any authenticated control status proves the Assistant is online.
        /// `status.ready` describes whether capture/input can start, not reachability.
        static func authenticatedStatus(_ status: BeetCodeControlStatus) -> Self {
            _ = status
            return .reachable
        }
    }

    struct SavedAssistant: Codable, Equatable, Hashable, Identifiable {
        enum ConnectionKind: Equatable {
            case localNetwork
            case tailscale
            case privateNetwork
        }

        let address: String
        var displayName: String

        var id: String { address }

        var hasGenericDisplayName: Bool {
            let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "vamp assistant" || normalized == "vamp assistant mac"
        }

        var connectionKind: ConnectionKind {
            guard let host = URLComponents(string: address)?.host?.lowercased() else {
                return .privateNetwork
            }
            if host.hasSuffix(".ts.net") { return .tailscale }

            let octets = host.split(separator: ".").compactMap { Int($0) }
            if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
                if octets[0] == 100, (64...127).contains(octets[1]) { return .tailscale }
                if octets[0] == 10
                    || (octets[0] == 172 && (16...31).contains(octets[1]))
                    || (octets[0] == 192 && octets[1] == 168)
                    || octets[0] == 127 {
                    return .localNetwork
                }
            }
            if host == "localhost" || host.hasSuffix(".local") { return .localNetwork }
            return .privateNetwork
        }
    }

    struct Session {
        let client: BeetCodeRemoteClient
        let address: String
        let displayName: String
        let status: BeetCodeControlStatus
    }

    @Published private(set) var session: Session?
    @Published private(set) var savedAssistants: [SavedAssistant]
    @Published private(set) var isPairing = false
    @Published private(set) var lastError: String?
    @Published private(set) var availabilityByAddress: [String: Availability] = [:]

    private var attemptID: UUID?
    private let pairRequest: (BeetCodeRemoteEndpoint, String) async throws -> BeetCodePairResponse
    private let statusRequest: (BeetCodeRemoteClient) async throws -> BeetCodeControlStatus
    private let defaults: UserDefaults
    private let legacySavedAddressKey = "vampstream.beetcode.savedAddress"
    private let savedAssistantsKey = "vampstream.assistant.savedAssistants.v1"

    var savedAddress: String? { savedAssistants.first?.address }

    init(
        defaults: UserDefaults = .standard,
        pairRequest: @escaping (BeetCodeRemoteEndpoint, String) async throws -> BeetCodePairResponse = {
            try await BeetCodeRemoteClient(endpoint: $0).pair(code: $1)
        },
        statusRequest: @escaping (BeetCodeRemoteClient) async throws -> BeetCodeControlStatus = {
            try await $0.controlStatus()
        }
    ) {
        self.defaults = defaults
        self.pairRequest = pairRequest
        self.statusRequest = statusRequest
        var loaded: [SavedAssistant] = []
        if let data = defaults.data(forKey: savedAssistantsKey),
           let decoded = try? JSONDecoder().decode([SavedAssistant].self, from: data) {
            loaded = decoded
        }

        // One-time migration from the old single-address slot. Never discard a
        // previously paired Mac just because the storage model now supports many.
        if let legacy = defaults.string(forKey: legacySavedAddressKey),
           !loaded.contains(where: { $0.address == legacy }) {
            loaded.append(SavedAssistant(address: legacy, displayName: "Vamp Assistant"))
        }
        savedAssistants = loaded
        if let data = try? JSONEncoder().encode(loaded) {
            defaults.set(data, forKey: savedAssistantsKey)
            defaults.removeObject(forKey: legacySavedAddressKey)
        }
    }

    func pair(address: String, code: String) async {
        guard !Task.isCancelled else { return }
        let attempt = UUID()
        attemptID = attempt
        isPairing = true
        lastError = nil
        defer {
            if attemptID == attempt {
                attemptID = nil
                isPairing = false
            }
        }

        do {
            let endpoint = try BeetCodeRemoteEndpoint.parse(address: address, pairingCode: code)
            guard let pairingCode = endpoint.pairingCode else {
                throw BeetCodeRemoteError.invalidPairingCode
            }
            let response = try await pairRequest(endpoint, pairingCode)
            guard attemptID == attempt, !Task.isCancelled else { return }
            guard !response.token.isEmpty else { throw BeetCodeRemoteError.invalidResponse }

            let client = BeetCodeRemoteClient(baseURL: endpoint.url, token: response.token)
            let status = try await statusRequest(client)
            // No suspended work between this check and persistence/session publication.
            guard attemptID == attempt, !Task.isCancelled else { return }
            var tokenWasPersisted = true
            do {
                try BeetCodeTokenStore.save(response.token, for: endpoint.url)
            } catch {
                #if targetEnvironment(simulator)
                // Unsigned simulator builds can reject Keychain writes even though the
                // live session itself is valid. Keep this token memory-only for the test
                // session; never weaken the production device storage path.
                tokenWasPersisted = false
                #else
                throw error
                #endif
            }
            let displayName = response.product?.isEmpty == false ? response.product! : "Vamp Assistant Mac"
            if tokenWasPersisted {
                save(address: endpoint.url.absoluteString, displayName: displayName)
            }
            session = Session(
                client: client,
                address: endpoint.url.absoluteString,
                displayName: displayName,
                status: status)
            availabilityByAddress[endpoint.url.absoluteString] = .authenticatedStatus(status)
        } catch {
            guard attemptID == attempt, !Task.isCancelled else { return }
            lastError = Self.userFacingConnectionError(error)
        }
    }

    func reconnect(_ saved: SavedAssistant) async {
        guard !Task.isCancelled else { return }
        let attempt = UUID()
        attemptID = attempt
        isPairing = true
        lastError = nil
        defer {
            if attemptID == attempt {
                attemptID = nil
                isPairing = false
            }
        }

        do {
            let endpoint = try BeetCodeRemoteEndpoint.parse(address: saved.address)
            guard let token = BeetCodeTokenStore.load(for: endpoint.url), !token.isEmpty else {
                throw BeetCodeRemoteError.notConnected
            }
            let client = BeetCodeRemoteClient(baseURL: endpoint.url, token: token)
            let status = try await statusRequest(client)
            // No suspended work between this check and persistence/session publication.
            guard attemptID == attempt, !Task.isCancelled else { return }
            session = Session(
                client: client,
                address: endpoint.url.absoluteString,
                displayName: saved.displayName,
                status: status)
            // A locked Mac deliberately reports `ready == false`, but a successful
            // authenticated status response still proves Vamp Assistant is online.
            availabilityByAddress[saved.address] = .authenticatedStatus(status)
        } catch {
            guard attemptID == attempt, !Task.isCancelled else { return }
            session = nil
            availabilityByAddress[saved.address] = .unavailable
            lastError = "Reconnect failed: \(Self.userFacingConnectionError(error))"
        }
    }

    /// Probe every saved Mac at once. Run one after another, three unreachable Macs meant three
    /// full request timeouts back to back before the list stopped saying "checking".
    func refreshAvailability() async {
        let targets = savedAssistants.map(\.address)
        for address in targets { availabilityByAddress[address] = .checking }
        let results = await withTaskGroup(of: (String, Availability).self) { group in
            for address in targets {
                group.addTask { (address, await Self.probe(address: address)) }
            }
            var collected: [String: Availability] = [:]
            for await (address, availability) in group { collected[address] = availability }
            return collected
        }
        // Skip anything the user forgot while the probes were in flight.
        for (address, availability) in results where availabilityByAddress[address] != nil {
            availabilityByAddress[address] = availability
        }
    }

    private nonisolated static func probe(address: String) async -> Availability {
        do {
            let endpoint = try BeetCodeRemoteEndpoint.parse(address: address)
            guard let token = BeetCodeTokenStore.load(for: endpoint.url), !token.isEmpty else {
                return .unavailable
            }
            let status = try await BeetCodeRemoteClient(baseURL: endpoint.url, token: token)
                .controlStatus(timeout: 6)
            return .authenticatedStatus(status)
        } catch {
            return .unavailable
        }
    }

    /// Invalidates late responses even when a server has already handled the request.
    func cancelConnectionAttempt() {
        attemptID = nil
        isPairing = false
        lastError = nil
    }

    func disconnect(clearSaved: Bool = false) {
        cancelConnectionAttempt()
        let activeAddress = session?.address
        session = nil
        lastError = nil
        guard clearSaved,
              let address = activeAddress ?? savedAddress,
              let saved = savedAssistants.first(where: { $0.address == address }) else { return }
        forget(saved)
    }

    func forget(_ saved: SavedAssistant) {
        if session?.address == saved.address { session = nil }
        if let endpoint = try? BeetCodeRemoteEndpoint.parse(address: saved.address) {
            BeetCodeTokenStore.clear(for: endpoint.url)
        }
        savedAssistants.removeAll { $0.id == saved.id }
        availabilityByAddress.removeValue(forKey: saved.address)
        persistSavedAssistants()
        lastError = nil
    }

    @discardableResult
    func refreshStatus() async -> String? {
        guard let session else { return BeetCodeRemoteError.notConnected.localizedDescription }
        do {
            let status = try await session.client.controlStatus()
            self.session = Session(
                client: session.client,
                address: session.address,
                displayName: session.displayName,
                status: status)
            availabilityByAddress[session.address] = .authenticatedStatus(status)
            lastError = nil
            return nil
        } catch {
            let message = error.localizedDescription
            lastError = message
            return message
        }
    }

    private func save(address: String, displayName: String) {
        let saved = SavedAssistant(address: address, displayName: displayName)
        savedAssistants.removeAll { $0.id == saved.id }
        savedAssistants.insert(saved, at: 0)
        persistSavedAssistants()
    }

    private func persistSavedAssistants() {
        guard let data = try? JSONEncoder().encode(savedAssistants) else { return }
        defaults.set(data, forKey: savedAssistantsKey)
    }

    private static func userFacingConnectionError(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return error.localizedDescription
        }

        switch URLError.Code(rawValue: nsError.code) {
        case .appTransportSecurityRequiresSecureConnection:
            return "Vamp Stream could not open this private HTTP connection. Install the latest build and try the LAN or Tailscale address shown by Vamp Assistant."
        case .cannotConnectToHost, .cannotFindHost:
            return "Vamp Assistant could not be reached. Keep it open on the Mac and confirm the private address and port 9575."
        case .timedOut:
            return "Vamp Assistant did not respond in time. Check that both devices are on the same LAN or private Tailscale network."
        case .notConnectedToInternet, .networkConnectionLost:
            return "The private network connection was lost. Reconnect Wi-Fi or Tailscale, then try again."
        default:
            return error.localizedDescription
        }
    }
}
