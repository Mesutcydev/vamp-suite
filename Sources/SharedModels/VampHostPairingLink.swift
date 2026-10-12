import Foundation

/// A small, non-secret QR payload for adding a Vamp host on a private network.
///
/// The link only contains an address and display name. It never approves a peer
/// or carries a trust secret; the normal fingerprint comparison and approval
/// flow still runs after the address is added.
public enum VampHostPairingLink {
    public static let scheme = "vampstream"

    public static func make(address: String, displayName: String? = nil) -> String? {
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
        return components.string
    }

    public static func parse(_ payload: String) -> (address: String, displayName: String?)? {
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
        return (trimmedAddress, displayName?.isEmpty == true ? nil : displayName)
    }
}
