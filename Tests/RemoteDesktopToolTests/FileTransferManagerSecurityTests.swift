import CryptoKit
import XCTest
@testable import HostApp
@testable import SharedProtocol
@testable import TransportWebRTC

@MainActor
final class FileTransferManagerSecurityTests: XCTestCase {

    func testSecondIncomingOfferIsRejectedWhileApprovalIsPending() async throws {
        let fixture = try await makeFixture(requireConfirmation: true)
        defer { fixture.cleanup() }

        let firstOffer = makeOffer(sessionID: UUID(), senderDeviceID: UUID(), fileSize: 32, totalChunks: 1)
        let secondOffer = makeOffer(sessionID: UUID(), senderDeviceID: UUID(), fileSize: 32, totalChunks: 1)

        let firstTask = Task {
            await fixture.manager.handle(.offer(firstOffer)) { envelope in
                await fixture.recorder.capture(envelope)
            }
        }

        try await waitUntil(timeout: 1.0) {
            await MainActor.run { fixture.store.pendingPrompt?.id == firstOffer.transferID }
        }

        await fixture.manager.handle(.offer(secondOffer)) { envelope in
            await fixture.recorder.capture(envelope)
        }
        await MainActor.run { fixture.store.resolvePrompt(approved: false) }
        await firstTask.value

        let messages = await fixture.recorder.snapshot()
        let rejects = messages.compactMap { message -> FileTransferRejectMessage? in
            guard case .reject(let reject) = message else { return nil }
            return reject
        }

        XCTAssertTrue(
            rejects.contains(where: {
                $0.transferID == secondOffer.transferID
                    && $0.reason.contains("awaiting approval")
            }),
            "Expected the second offer to be rejected while the first prompt was pending"
        )
    }

    func testChunkMetadataMismatchFailsTransfer() async throws {
        let fixture = try await makeFixture(requireConfirmation: false)
        defer { fixture.cleanup() }

        let senderDeviceID = UUID()
        let offer = makeOffer(sessionID: UUID(), senderDeviceID: senderDeviceID, fileSize: 4, totalChunks: 1)
        await fixture.manager.handle(.offer(offer)) { envelope in
            await fixture.recorder.capture(envelope)
        }

        let badChunk = FileTransferChunkMessage(
            transferID: offer.transferID,
            sessionID: offer.sessionID,
            senderDeviceID: UUID(),
            fileName: offer.fileName,
            sanitizedFileName: offer.sanitizedFileName,
            fileSize: offer.fileSize,
            checksum: offer.checksum,
            chunkIndex: 0,
            totalChunks: 1,
            byteOffset: 0,
            chunkChecksum: sha256Hex(Data([0x01, 0x02, 0x03, 0x04])),
            data: Data([0x01, 0x02, 0x03, 0x04])
        )

        await fixture.manager.handle(.chunk(badChunk)) { envelope in
            await fixture.recorder.capture(envelope)
        }

        let messages = await fixture.recorder.snapshot()
        let errors = messages.compactMap { message -> FileTransferErrorMessage? in
            guard case .error(let error) = message else { return nil }
            return error
        }

        XCTAssertTrue(
            errors.contains(where: {
                $0.transferID == offer.transferID && $0.errorCode == "metadata_mismatch"
            }),
            "Expected mismatched metadata to fail the transfer"
        )
    }

    func testOfferTimesOutAndCleansUpTransfer() async throws {
        let fixture = try await makeFixture(
            requireConfirmation: false,
            configuration: HostFileTransferManager.Configuration(
                chunkTimeoutSeconds: 0.05,
                maxChunkSizeBytes: 32 * 1024
            )
        )
        defer { fixture.cleanup() }

        let offer = makeOffer(sessionID: UUID(), senderDeviceID: UUID(), fileSize: 8, totalChunks: 1)
        await fixture.manager.handle(.offer(offer)) { envelope in
            await fixture.recorder.capture(envelope)
        }

        try await waitUntil(timeout: 1.0) {
            let messages = await fixture.recorder.snapshot()
            return messages.contains {
                if case .error(let error) = $0 {
                    return error.transferID == offer.transferID && error.errorCode == "transfer_timeout"
                }
                return false
            }
        }

        let history = await MainActor.run { fixture.store.history }
        XCTAssertTrue(history.contains(where: { $0.id == offer.transferID && $0.status == .failed }))
    }

    func testDestinationLabelsStayPrivacySafe() async throws {
        let fixture = try await makeFixture(requireConfirmation: false, folderName: "PrivateFolder")
        defer { fixture.cleanup() }

        let offer = makeOffer(
            sessionID: UUID(),
            senderDeviceID: UUID(),
            fileSize: 0,
            checksum: sha256Hex(Data()),
            totalChunks: 0
        )
        await fixture.manager.handle(.offer(offer)) { envelope in
            await fixture.recorder.capture(envelope)
        }

        let complete = FileTransferCompleteMessage(
            transferID: offer.transferID,
            sessionID: offer.sessionID,
            senderDeviceID: offer.senderDeviceID,
            fileName: offer.fileName,
            sanitizedFileName: offer.sanitizedFileName,
            fileSize: 0,
            checksum: offer.checksum,
            totalChunks: 0,
            totalBytes: 0
        )
        await fixture.manager.handle(.complete(complete)) { envelope in
            await fixture.recorder.capture(envelope)
        }

        let messages = await fixture.recorder.snapshot()
        let accept = try XCTUnwrap(messages.compactMap { message -> FileTransferAcceptMessage? in
            guard case .accept(let accept) = message else { return nil }
            return accept
        }.first)
        let completion = try XCTUnwrap(messages.compactMap { message -> FileTransferCompleteMessage? in
            guard case .complete(let complete) = message else { return nil }
            return complete
        }.first)

        XCTAssertEqual(accept.destinationDescription, "PrivateFolder")
        XCTAssertEqual(completion.destinationDescription, "PrivateFolder")
        XCTAssertFalse(accept.destinationDescription.contains("/"))
        XCTAssertFalse(completion.destinationDescription?.contains("/") ?? false)

        let history = await MainActor.run { fixture.store.history }
        XCTAssertTrue(history.contains(where: { $0.id == offer.transferID && $0.destinationDescription == "PrivateFolder" }))
    }

    private func makeFixture(
        requireConfirmation: Bool,
        configuration: HostFileTransferManager.Configuration = .init(),
        folderName: String = UUID().uuidString
    ) async throws -> FileTransferFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let bookmark = try directory.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let settings = await MainActor.run { () -> HostFileTransferSettingsStore in
            let settings = HostFileTransferSettingsStore(supportsDefaultDownloadsLocation: false)
            settings.isEnabled = true
            settings.requireConfirmation = requireConfirmation
            settings.setSaveLocation(url: directory, bookmark: bookmark)
            return settings
        }
        let store = await MainActor.run { HostFileTransferStore() }
        let recorder = FileTransferResponseRecorder()
        let manager = HostFileTransferManager(settings: settings, store: store, configuration: configuration)
        return FileTransferFixture(directory: directory, settings: settings, store: store, manager: manager, recorder: recorder)
    }

    private func makeOffer(
        sessionID: UUID,
        senderDeviceID: UUID,
        fileSize: Int64,
        checksum: String? = nil,
        totalChunks: Int
    ) -> FileTransferOfferMessage {
        FileTransferOfferMessage(
            transferID: UUID(),
            sessionID: sessionID,
            senderDeviceID: senderDeviceID,
            fileName: "example.txt",
            sanitizedFileName: "example.txt",
            fileSize: fileSize,
            mimeType: "text/plain",
            uniformTypeIdentifier: "public.plain-text",
            checksum: checksum ?? String(repeating: "a", count: 64),
            totalChunks: totalChunks
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct FileTransferFixture {
    let directory: URL
    let settings: HostFileTransferSettingsStore
    let store: HostFileTransferStore
    let manager: HostFileTransferManager
    let recorder: FileTransferResponseRecorder

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor FileTransferResponseRecorder {
    private var messages: [FileTransferMessage] = []

    func capture(_ envelope: DataChannelEnvelope) async {
        guard envelope.kind == .fileTransfer,
              let message = try? envelope.decodeFileTransfer() else { return }
        messages.append(message)
    }

    func snapshot() -> [FileTransferMessage] {
        messages
    }
}
