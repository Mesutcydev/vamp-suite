import CryptoKit
import XCTest
@testable import Discovery
@testable import SharedModels

final class DiscoveryMetadataTests: XCTestCase {
    func testHostAdvertisementMetadataRoundTripsThroughTXTRecord() throws {
        let hostID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let metadata = HostAdvertisementMetadata(
            protocolVersion: 1,
            hostID: hostID,
            displayName: "Studio Mac",
            appVersion: "0.1",
            signalingPort: 9471,
            capabilities: [
                .supportsHEVC,
                .supportsH264,
                .supportsMultiDisplay,
                .supportsMacClient,
                .supportsTerminal,
                .supportsMultipleTerminals,
                .supportsTerminalChat,
                .supportsTaskPlans,
                .supportsWorkspaces
            ]
        )

        let parsed = try HostAdvertisementMetadata(txtRecord: metadata.txtRecord)

        XCTAssertEqual(parsed, metadata)
        XCTAssertTrue(parsed.capabilities.contains(.supportsHEVC))
        XCTAssertTrue(parsed.capabilities.contains(.supportsH264))
        XCTAssertTrue(parsed.capabilities.contains(.supportsMultiDisplay))
        XCTAssertTrue(parsed.capabilities.contains(.supportsMacClient))
        XCTAssertTrue(parsed.capabilities.contains(.supportsTerminal))
        XCTAssertTrue(parsed.capabilities.contains(.supportsMultipleTerminals))
        XCTAssertTrue(parsed.capabilities.contains(.supportsTerminalChat))
        XCTAssertTrue(parsed.capabilities.contains(.supportsTaskPlans))
        XCTAssertTrue(parsed.capabilities.contains(.supportsWorkspaces))
    }

    func testKeyAgreementPublicKeyRoundTripsThroughTXTRecord() throws {
        let kapk = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let metadata = HostAdvertisementMetadata(
            protocolVersion: 1,
            hostID: UUID(),
            displayName: "Secure Mac",
            appVersion: "0.1",
            signalingPort: 9471,
            capabilities: [.supportsTerminal],
            keyAgreementPublicKey: kapk
        )

        let parsed = try HostAdvertisementMetadata(txtRecord: metadata.txtRecord)

        XCTAssertEqual(parsed, metadata)
        XCTAssertEqual(parsed.keyAgreementPublicKey, kapk)
        // The base64 payload must actually be present in the TXT record.
        XCTAssertNotNil(metadata.txtRecord[HostAdvertisementMetadata.TXTKey.keyAgreementPublicKey])
    }

    func testHostAdvertisementMetadataRejectsMissingProtocolVersion() {
        let txtRecord: [String: Data] = [
            HostAdvertisementMetadata.TXTKey.hostID: Data(UUID().uuidString.utf8),
            HostAdvertisementMetadata.TXTKey.displayName: Data("Mac".utf8),
            HostAdvertisementMetadata.TXTKey.appVersion: Data("0.1".utf8),
            HostAdvertisementMetadata.TXTKey.signalingPort: Data("9471".utf8),
            HostAdvertisementMetadata.TXTKey.capabilities: Data("supportsH264".utf8)
        ]

        XCTAssertThrowsError(try HostAdvertisementMetadata(txtRecord: txtRecord)) { error in
            XCTAssertEqual(
                error as? HostAdvertisementMetadataError,
                .missingKey(HostAdvertisementMetadata.TXTKey.protocolVersion)
            )
        }
    }

    func testResolvedHostMetadataFallsBackWhenTXTRecordIsMissing() {
        let result = resolvedHostMetadata(
            from: nil,
            serviceName: "Studio Mac",
            port: 9471,
            serviceKey: "Studio Mac|_screenharbor._tcp.|local."
        )

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.metadata.displayName, "Studio Mac")
        XCTAssertEqual(result.metadata.appVersion, "unknown")
        XCTAssertEqual(result.metadata.signalingPort, 9471)
        XCTAssertEqual(result.metadata.availability, .available)
    }

    func testResolvedHostMetadataFallsBackWhenTXTRecordIsMalformed() {
        let result = resolvedHostMetadata(
            from: [
                HostAdvertisementMetadata.TXTKey.displayName: Data("Studio Mac".utf8)
            ],
            serviceName: "Studio Mac",
            port: 9471,
            serviceKey: "Studio Mac|_screenharbor._tcp.|local."
        )

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.metadata.displayName, "Studio Mac")
        XCTAssertEqual(result.metadata.signalingPort, 9471)
    }

    func testResolvedHostMetadataUsesTXTRecordWhenPresent() throws {
        let expected = HostAdvertisementMetadata(
            protocolVersion: 1,
            hostID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            displayName: "Studio Mac",
            appVersion: "2.1",
            signalingPort: 9471,
            capabilities: [.supportsH264],
            supportedCodecs: ["h264"],
            availability: .busy
        )

        let result = resolvedHostMetadata(
            from: expected.txtRecord,
            serviceName: "Ignored",
            port: 9472,
            serviceKey: "ignored"
        )

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.metadata, expected)
    }
}
