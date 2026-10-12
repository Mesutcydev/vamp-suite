import Foundation

/// Sent by either side to push clipboard plaintext to the other device.
/// Only plaintext is supported — no binary, no rich text, no images.
/// Security: transferred only over the active authenticated session data channel.
/// Content is bounded to maxContentLength to guard against oversized payloads.
public struct ClipboardSyncMessage: Codable, Sendable {
    public let sessionID: UUID
    public let text: String     // plaintext only
    public let source: String   // "host" or "client"

    public static let maxContentLength = 65_536

    public init(sessionID: UUID, text: String, source: String) {
        self.sessionID = sessionID
        self.text = String(text.prefix(Self.maxContentLength))
        self.source = source
    }
}

/// Sent by the client to ask the host to push its current clipboard content.
/// The host responds with a `ClipboardSyncMessage`.
public struct ClipboardRequestMessage: Codable, Sendable {
    public let sessionID: UUID

    public init(sessionID: UUID) {
        self.sessionID = sessionID
    }
}
