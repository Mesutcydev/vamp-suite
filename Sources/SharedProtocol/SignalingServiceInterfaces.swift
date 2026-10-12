import Foundation

public enum LocalSignalingTransportKind: String, Codable, Hashable, Sendable {
    case webSocket
    case localTCP
}

public protocol SignalingMessageEncoding {
    func encode(_ message: VersionedSignalingMessage) throws -> Data
    func decode(_ data: Data) throws -> VersionedSignalingMessage
}

public struct JSONSignalingMessageCoder: SignalingMessageEncoding {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(encoder: JSONEncoder = JSONEncoder(), decoder: JSONDecoder = JSONDecoder()) {
        self.encoder = encoder
        self.decoder = decoder
    }

    public func encode(_ message: VersionedSignalingMessage) throws -> Data {
        try encoder.encode(message)
    }

    public func decode(_ data: Data) throws -> VersionedSignalingMessage {
        try decoder.decode(VersionedSignalingMessage.self, from: data)
    }
}

public protocol SignalingMessageChannelProtocol {
    func send(_ message: VersionedSignalingMessage) async throws
    func receiveMessages() -> AsyncThrowingStream<VersionedSignalingMessage, Error>
    func close() async
}
