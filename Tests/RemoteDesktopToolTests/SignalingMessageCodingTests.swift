import XCTest
@testable import SharedModels
@testable import SharedProtocol

final class SignalingMessageCodingTests: XCTestCase {
    func testOfferEnvelopeEncodesAndDecodes() throws {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let senderID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let envelopeID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let sentAt = Date(timeIntervalSince1970: 100)

        let offer = SessionOfferMessage(
            sessionID: sessionID,
            sdp: "v=0",
            requestedDisplayID: "main",
            qualityPreset: .balanced
        )
        let envelope = SignalingEnvelope(
            id: envelopeID,
            protocolVersion: 1,
            sentAt: sentAt,
            sessionID: sessionID,
            sender: SignalingPeer(id: senderID, role: .client, displayName: "iPhone"),
            event: .offer(offer)
        )
        let message = VersionedSignalingMessage(envelope: envelope)
        let coder = JSONSignalingMessageCoder()

        let data = try coder.encode(message)
        let decoded = try coder.decode(data)

        XCTAssertEqual(decoded, message)
        XCTAssertEqual(decoded.envelope.kind, .offer)
    }

    func testTerminalClientRoleAndHostRestrictionReasonRoundTrip() throws {
        let sessionID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let offer = SessionOfferMessage(
            sessionID: sessionID,
            sdp: "v=0",
            qualityPreset: .balanced,
            clientCapabilities: [.supportsH264, .supportsTerminal, .supportsMultipleTerminals],
            clientProductRole: .terminal
        )
        let blocked = PermissionBlockedMessage(
            sessionID: sessionID,
            blockedPermissions: [],
            reason: .terminalOnlyHost
        )

        let offerData = try JSONEncoder().encode(offer)
        let blockedData = try JSONEncoder().encode(blocked)
        let decodedOffer = try JSONDecoder().decode(SessionOfferMessage.self, from: offerData)
        let decodedBlocked = try JSONDecoder().decode(PermissionBlockedMessage.self, from: blockedData)

        XCTAssertEqual(decodedOffer.clientProductRole, .terminal)
        XCTAssertEqual(decodedBlocked.reason, .terminalOnlyHost)
    }

    func testLegacyOfferWithoutClientProductRoleStillDecodes() throws {
        let data = Data("{\"sessionID\":\"66666666-6666-6666-6666-666666666666\",\"sdp\":\"v=0\",\"requestedDisplayID\":null,\"qualityPreset\":\"balanced\",\"sessionToken\":null,\"clientCapabilities\":null,\"preferredDynamicRange\":null}".utf8)

        let decoded = try JSONDecoder().decode(SessionOfferMessage.self, from: data)

        XCTAssertNil(decoded.clientProductRole)
    }

    func testSessionReadyEnvelopeEncodesNegotiatedCapabilities() throws {
        let sessionID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let senderID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let capabilities = NegotiatedCapabilities(
            videoCodec: .hevc,
            supportsMultiDisplay: true,
            supportsAudio: false,
            supportsMacClient: true,
            supportsTerminal: true,
            supportsMultipleTerminals: true
        )
        let envelope = SignalingEnvelope(
            protocolVersion: 1,
            sessionID: sessionID,
            sender: SignalingPeer(id: senderID, role: .host),
            event: .sessionReady(
                SessionReadyMessage(
                    sessionID: sessionID,
                    selectedDisplayID: "main",
                    negotiatedCapabilities: capabilities,
                    lockState: .lockedOrLoginWindow
                )
            )
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(SignalingEnvelope.self, from: data)

        XCTAssertEqual(decoded.kind, .sessionReady)
        XCTAssertEqual(decoded, envelope)
    }

    func testLegacySessionReadyDecodesWithoutLockState() throws {
        let data = Data(#"{"sessionID":"44444444-4444-4444-4444-444444444444","negotiatedCapabilities":{"videoCodec":"h264","supportsMultiDisplay":false,"supportsAudio":false,"supportsMacClient":false}}"#.utf8)

        let decoded = try JSONDecoder().decode(SessionReadyMessage.self, from: data)

        XCTAssertNil(decoded.lockState)
    }

    func testLegacyNegotiatedCapabilitiesDecodeWithoutTerminalFields() throws {
        let data = Data("{\"videoCodec\":\"h264\",\"supportsMultiDisplay\":false,\"supportsAudio\":false,\"supportsMacClient\":false}".utf8)

        let decoded = try JSONDecoder().decode(NegotiatedCapabilities.self, from: data)

        XCTAssertFalse(decoded.supportsTerminal)
        XCTAssertFalse(decoded.supportsMultipleTerminals)
    }
}
