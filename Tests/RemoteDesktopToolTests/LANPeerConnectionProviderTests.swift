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
