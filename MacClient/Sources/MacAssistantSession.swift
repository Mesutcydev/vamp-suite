import Combine
import Foundation

/// Owns Vamp Control's explicit connection to Vamp Assistant.
///
/// Vamp Assistant is intentionally separate from Vamp Host discovery: it uses a
/// one-time code followed by a bearer token over a private LAN/Tailscale HTTP
/// endpoint. Keeping the state separate prevents either protocol from weakening
/// the other's trust model.
@MainActor
final class MacAssistantSession: ObservableObject {
    struct ConnectedSession {
        let id: UUID
        let client: BeetCodeRemoteClient
        let address: String
        let displayName: String
        let status: BeetCodeControlStatus
    }

    @Published private(set) var connected: ConnectedSession?
    @Published private(set) var savedAddress: String?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let savedAddressKey = "vampcontrol.assistant.savedAddress"
    /// Cache the token after the single deliberate Keychain lookup. View updates
    /// and background status refreshes must never trigger repeated Keychain reads.
    private var cachedToken: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        savedAddress = defaults.string(forKey: savedAddressKey)
    }

    func pair(address: String, code: String) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let endpoint = try BeetCodeRemoteEndpoint.parse(address: address, pairingCode: code)
            guard let pairingCode = endpoint.pairingCode else {
                throw BeetCodeRemoteError.invalidPairingCode
            }
            let response = try await BeetCodeRemoteClient(endpoint: endpoint).pair(code: pairingCode)
            guard !response.token.isEmpty else { throw BeetCodeRemoteError.invalidResponse }

            let client = BeetCodeRemoteClient(baseURL: endpoint.url, token: response.token)
            let status = try await client.controlStatus()
            try BeetCodeTokenStore.save(response.token, for: endpoint.url)

            cachedToken = response.token
            savedAddress = endpoint.url.absoluteString
            defaults.set(endpoint.url.absoluteString, forKey: savedAddressKey)
            connected = ConnectedSession(
                id: UUID(),
                client: client,
                address: endpoint.url.absoluteString,
                displayName: response.product?.isEmpty == false ? response.product! : "Vamp Assistant",
                status: status
            )
        } catch {
            errorMessage = Self.connectionMessage(for: error)
        }
    }

    func reconnect() async {
        guard !isWorking else { return }
        guard let savedAddress else {
            errorMessage = BeetCodeRemoteError.invalidAddress.localizedDescription
            return
        }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let endpoint = try BeetCodeRemoteEndpoint.parse(address: savedAddress)
            let token = cachedToken ?? BeetCodeTokenStore.load(for: endpoint.url)
            guard let token, !token.isEmpty else { throw BeetCodeRemoteError.notConnected }
            cachedToken = token
            let client = BeetCodeRemoteClient(baseURL: endpoint.url, token: token)
            let status = try await client.controlStatus()
            connected = ConnectedSession(
                id: UUID(),
                client: client,
                address: endpoint.url.absoluteString,
                displayName: "Vamp Assistant",
                status: status
            )
        } catch {
            connected = nil
            errorMessage = Self.connectionMessage(for: error)
        }
    }

    @discardableResult
    func refreshStatus() async -> String? {
        guard let connected else { return BeetCodeRemoteError.notConnected.localizedDescription }
        do {
            let status = try await connected.client.controlStatus()
            self.connected = ConnectedSession(
                id: connected.id,
                client: connected.client,
                address: connected.address,
                displayName: connected.displayName,
                status: status
            )
            errorMessage = nil
            return nil
        } catch {
            let message = Self.connectionMessage(for: error)
            errorMessage = message
            return message
        }
    }

    func disconnect(forget: Bool = false) {
        connected = nil
        errorMessage = nil
        guard forget, let savedAddress,
              let endpoint = try? BeetCodeRemoteEndpoint.parse(address: savedAddress) else { return }
        BeetCodeTokenStore.clear(for: endpoint.url)
        cachedToken = nil
        defaults.removeObject(forKey: savedAddressKey)
        self.savedAddress = nil
    }

    private static func connectionMessage(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch URLError.Code(rawValue: nsError.code) {
        case .cannotConnectToHost, .cannotFindHost:
            return "Vamp Assistant could not be reached. Keep it open and verify its LAN or Tailscale address and port 9575."
        case .timedOut:
            return "Vamp Assistant did not respond in time. Confirm both Macs are on the same LAN or private Tailscale network."
        case .networkConnectionLost, .notConnectedToInternet:
            return "The private network connection was lost. Reconnect LAN or Tailscale, then try again."
        default:
            return error.localizedDescription
        }
    }
}
