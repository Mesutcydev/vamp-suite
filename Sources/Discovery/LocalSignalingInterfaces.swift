import Foundation
import SharedProtocol

public protocol LocalSignalingClientTransportProtocol: SignalingMessageChannelProtocol {
    var transportKind: LocalSignalingTransportKind { get }

    func connect(to endpoint: ResolvedHostEndpoint) async throws
}

public protocol LocalSignalingServerTransportProtocol: SignalingMessageChannelProtocol {
    var transportKind: LocalSignalingTransportKind { get }

    func listen(port: UInt16) async throws
}
