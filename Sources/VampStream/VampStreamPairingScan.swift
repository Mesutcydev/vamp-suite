import SharedModels

/// Routes a scanned Mac QR to its existing pairing flow. Reading a QR never
/// approves a Sync device or submits an Assistant/Companion pairing code.
enum VampStreamPairingScan: Equatable {
    case sync(address: String)
    case assistant(BeetCodeRemoteEndpoint)

    static func parse(_ payload: String) -> Self? {
        if let endpoint = try? BeetCodeRemoteEndpoint.parsePairingLink(payload) {
            return .assistant(endpoint)
        }
        if let pairing = VampHostPairingLink.parse(payload) {
            return .sync(address: pairing.address)
        }
        return nil
    }
}
