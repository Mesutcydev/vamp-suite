import Foundation

/// A small, non-secret QR payload for adding a Vamp host on a private network.
///
/// The link contains an address, a display name and the host's public-key
/// fingerprint. It never approves a peer or carries a trust secret: the Mac
/// still asks for approval. The fingerprint is public, and scanning it off the
/// Mac's own screen is what lets the client verify that Mac on first contact
/// instead of trusting whoever answers at the address.
public enum VampHostPairingLink {
    public static let scheme = "vampstream"

    public static func make(address: String, displayName: String? = nil, fingerprint: String? = nil) -> String? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty, !trimmedAddress.contains(" ") else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "address", value: trimmedAddress)
        ]
        if let displayName {
            let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "name", value: trimmedName))
            }
        }
        if let fingerprint, PublicKeyFingerprint.isValid(fingerprint) {
            components.queryItems?.append(URLQueryItem(name: "fp", value: fingerprint))
        }
        return components.string
    }

    /// `fingerprint` is nil for links made by hosts that predate it. A link
    /// whose `fp` is present but malformed is rejected outright: a damaged or
    /// altered code must not quietly become an unverified pairing.
    public static func parse(_ payload: String) -> (address: String, displayName: String?, fingerprint: String?)? {
        guard let components = URLComponents(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.caseInsensitiveCompare(scheme) == .orderedSame,
              components.host?.caseInsensitiveCompare("pair") == .orderedSame,
              let address = components.queryItems?.first(where: { $0.name == "address" })?.value else {
            return nil
        }

        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty, !trimmedAddress.contains(" ") else { return nil }
        let displayName = components.queryItems?.first(where: { $0.name == "name" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = components.queryItems?.first(where: { $0.name == "fp" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let fingerprint, !PublicKeyFingerprint.isValid(fingerprint) { return nil }
        return (trimmedAddress, displayName?.isEmpty == true ? nil : displayName, fingerprint)
    }
}
