import SharedModels

/// Routes a scanned Mac QR to its existing pairing flow. Reading a QR never
/// approves a Sync device or submits an Assistant/Companion pairing code.
enum VampStreamPairingScan: Equatable {
    /// `fingerprint` is the host fingerprint the code carried, when it has one.
    case sync(address: String, fingerprint: String? = nil)
    case assistant(BeetCodeRemoteEndpoint)

    static func parse(_ payload: String) -> Self? {
        if let endpoint = try? BeetCodeRemoteEndpoint.parsePairingLink(payload) {
            return .assistant(endpoint)
        }
        if let pairing = VampHostPairingLink.parse(payload) {
            return .sync(address: pairing.address, fingerprint: pairing.fingerprint)
        }
        return nil
    }
}
