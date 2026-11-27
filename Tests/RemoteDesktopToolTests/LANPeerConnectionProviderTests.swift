#if canImport(Network)
import Foundation
import Network
import XCTest
@testable import SharedModels
@testable import TransportWebRTC

final class LANPeerConnectionProviderTests: XCTestCase {
    private final class Delegate: PeerConnectionDelegate, @unchecked Sendable {
        func peerConnection(
            _ pc: any PeerConnectionProtocol,
            didChangeConnectionState state: PeerConnectionState
        ) {}

        func peerConnection(
            _ pc: any PeerConnectionProtocol,
            didChangeICEConnectionState state: ICEConnectionState
        ) {}

        func peerConnection(
            _ pc: any PeerConnectionProtocol,
            didChangeICEGatheringState state: ICEGatheringState
        ) {}

        func peerConnection(
            _ pc: any PeerConnectionProtocol,
            didGenerateICECandidate candidate: ICECandidate
        ) {}

        func peerConnection(
            _ pc: any PeerConnectionProtocol,
            didOpenDataChannel channel: any DataChannelProtocol
        ) {}
    }

    /// Connects two ends over loopback and returns the TLS cipher suite they agreed on.
    private func negotiatedSuite(server: NWParameters, client: NWParameters) async throws -> UInt16 {
        let queue = DispatchQueue(label: "psk-test")
        let port = NWEndpoint.Port(rawValue: UInt16.random(in: 42000...48000))!
        let listener = try NWListener(using: server, on: port)
        listener.newConnectionHandler = { $0.start(queue: queue) }
        listener.start(queue: queue)
        defer { listener.cancel() }
        let connection = NWConnection(host: "127.0.0.1", port: port, using: client)
        defer { connection.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            connection.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready:
                    finished = true
                    let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
                    let suite = metadata.map { sec_protocol_metadata_get_negotiated_tls_ciphersuite($0.securityProtocolMetadata).rawValue }
                    continuation.resume(returning: suite ?? 0)
                case .failed(let error), .waiting(let error):
                    finished = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// The data transport as shipped before the forward-secret suite: plain PSK only.
    private func previousReleaseParameters(token: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = token.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("vamp-data-channel-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0x00AD)!)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    func testDataChannelIsForwardSecretBetweenUpdatedAppsAndStillConnectsToOlderOnes() async throws {
        let token = Data((0..<32).map { UInt8($0) })
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let updated = { try LANPeerConnection.makeTCPParameters(sessionTokenHex: hex) }

        let both = try await negotiatedSuite(server: updated(), client: updated())
        XCTAssertEqual(both, 0xCCAC, "ECDHE-PSK: a recorded session stays closed if the token leaks later")

        let updatedHostOldApp = try await negotiatedSuite(server: updated(), client: previousReleaseParameters(token: token))
        XCTAssertEqual(updatedHostOldApp, 0x00A8, "an older app must still connect")
        let oldHostUpdatedApp = try await negotiatedSuite(server: previousReleaseParameters(token: token), client: updated())
        XCTAssertEqual(oldHostUpdatedApp, 0x00A8, "an older Mac or the Linux host must still connect")
    }

    func testEncryptedListenerRejectsMissingSessionToken() async {
        let peer = LANPeerConnection(remoteHost: nil, delegate: Delegate())
        defer { peer.close() }

        do {
            _ = try await peer.createAnswer(constraints: .defaultAnswer)
            XCTFail("Expected an unauthenticated data listener to be rejected")
        } catch let error as WebRTCSessionError {
            guard case .invalidState = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFixedPortListenerRetriesUntilPreviousListenerReleasesPort() async throws {
        let delegate = Delegate()
        let token = String(repeating: "ab", count: 32)
        let blocker = LANPeerConnection(remoteHost: nil, sessionTokenHex: token, delegate: delegate)
        let blockerAnswer = try await blocker.createAnswer(constraints: .defaultAnswer)
        let blockerDescriptor = try XCTUnwrap(LANSessionDescriptor.decoded(from: blockerAnswer.sdp))
        let port = blockerDescriptor.dataPort

        let peer = LANPeerConnection(remoteHost: nil, fixedDataPort: port, sessionTokenHex: token, delegate: delegate)
        defer {
            blocker.close()
            peer.close()
        }

        // Keep the port occupied long enough to force more than one bind attempt,
        // then emulate the previous session's asynchronous listener teardown.
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            blocker.close()
        }

        let answer = try await peer.createAnswer(constraints: .defaultAnswer)
        let descriptor = try XCTUnwrap(LANSessionDescriptor.decoded(from: answer.sdp))
        XCTAssertEqual(descriptor.dataPort, port)
    }
}
#endif
