import CryptoKit
import Foundation
import SharedModels
import SharedProtocol
import TransportWebRTC
import UniformTypeIdentifiers

@MainActor
final class ClientFileTransferManager: ObservableObject {
    private enum AcceptOutcome {
        case accepted(FileTransferAcceptMessage)
        case failed(String)
    }

    private enum CompletionOutcome {
        case completed(FileTransferCompleteMessage)
        case failed(String)
    }

    struct TransferState: Identifiable, Equatable {
        enum Direction: Equatable {
            case toMac
            case fromMac
        }

        enum Status: Equatable {
            case preparing
            case waitingForMac
            case sending
            case receiving
            case completed(String)
            case canceled
            case failed(String)
        }

        let id: UUID
        var direction: Direction
        var fileName: String
        var transferredBytes: Int64
        var totalBytes: Int64
        var status: Status

        var progress: Double {
            guard totalBytes > 0 else { return status == .completed("") ? 1 : 0 }
            return min(1, Double(transferredBytes) / Double(totalBytes))
        }
    }

    struct IncomingTransferPrompt: Identifiable, Equatable {
        let id: UUID
        let fileName: String
        let fileSize: Int64
    }

    struct PendingReceivedFile: Equatable {
        let url: URL
        let fileName: String
    }

    private struct IncomingTransferState {
        let offer: FileTransferOfferMessage
        let tempURL: URL
        let fileHandle: FileHandle
        var bytesReceived: Int64
        var expectedChunkIndex: Int
        var hasher: SHA256
    }

    @Published var isImporterPresented = false
    @Published var isReceivedFileSavePresented = false
    @Published private(set) var activeTransfer: TransferState?
    @Published private(set) var lastMessage: String?
    @Published private(set) var incomingPrompt: IncomingTransferPrompt?
    @Published private(set) var pendingReceivedFile: PendingReceivedFile?

    private let webRTCSessionManager: any WebRTCSessionManaging
    private let sessionCoordinator: ClientSessionCoordinator
    private let clientIdentity: ClientIdentity
    private var messageTask: Task<Void, Never>?
    private var sendingTask: Task<Void, Never>?
    private var acceptTimeoutTask: Task<Void, Never>?
    private var progressTimeoutTask: Task<Void, Never>?
    private var completionTimeoutTask: Task<Void, Never>?

    private var acceptContinuation: CheckedContinuation<AcceptOutcome, Never>?
    private var progressContinuation: CheckedContinuation<FileTransferProgressMessage?, Never>?
    private var completionContinuation: CheckedContinuation<CompletionOutcome, Never>?
    private var currentOutgoingTransferID: UUID?
    private var currentChunkIndexWaitingForAck: Int?
    private var pendingIncomingOffers: [UUID: FileTransferOfferMessage] = [:]
    private var incomingTransferState: IncomingTransferState?
    private let acceptTimeoutSeconds: TimeInterval = 30
    private let progressTimeoutSeconds: TimeInterval = 20
    private let completionTimeoutSeconds: TimeInterval = 30
    private let maxIncomingFileSizeBytes: Int64 = 100 * 1_048_576
    private let incomingChunkSize: Int = 24 * 1024

    init(
        webRTCSessionManager: any WebRTCSessionManaging,
        sessionCoordinator: ClientSessionCoordinator,
        clientIdentity: ClientIdentity
    ) {
        self.webRTCSessionManager = webRTCSessionManager
        self.sessionCoordinator = sessionCoordinator
        self.clientIdentity = clientIdentity
    }

    var isEnabled: Bool {
        get { ClientFileTransferPreference.isEnabled() }
        set { ClientFileTransferPreference.setEnabled(newValue) }
    }

    func startObserving() {
        guard messageTask == nil else { return }
        messageTask = Task { [weak self] in
            guard let self else { return }
            for await envelope in webRTCSessionManager.receiveDataMessages() {
                guard !Task.isCancelled else { break }
                guard envelope.kind == .fileTransfer, let message = try? envelope.decodeFileTransfer() else { continue }
                await handleFileTransferMessage(message)
            }
        }
    }

    func stopObserving() {
        messageTask?.cancel()
        messageTask = nil
        sendingTask?.cancel()
        sendingTask = nil
        finishPendingContinuationsForCancellation()
        cleanupIncomingTransfer(deleteFile: true)
        incomingPrompt = nil
        pendingIncomingOffers.removeAll()
    }

    func sendFile(url: URL) {
        guard isEnabled else {
            lastMessage = "Enable file transfer in Config first."
            return
        }
        guard activeTransfer == nil, incomingPrompt == nil, incomingTransferState == nil else {
            lastMessage = "Finish the current transfer first."
            return
        }
        guard sessionCoordinator.phase == .receiving || sessionCoordinator.phase == .waitingForMedia,
              let sessionID = sessionCoordinator.activeSessionID else {
            lastMessage = "Connect to your Mac before sending a file."
            return
        }

        sendingTask?.cancel()
        sendingTask = Task { [weak self] in
            await self?.runSendFile(url: url, sessionID: sessionID)
        }
    }

    func dismissTransfer() {
        guard let state = activeTransfer else { return }
        switch state.status {
        case .completed, .failed, .canceled:
            activeTransfer = nil
            if pendingReceivedFile == nil {
                lastMessage = nil
            }
        default:
            break
        }
    }

    func cancelActiveTransfer() {
        guard let sessionID = sessionCoordinator.activeSessionID,
              let state = activeTransfer else {
            return
        }
        switch state.direction {
        case .toMac:
            guard let transferID = currentOutgoingTransferID else { return }
            sendingTask?.cancel()
            let cancel = FileTransferCancelMessage(
                transferID: transferID,
                sessionID: sessionID,
                senderDeviceID: clientIdentity.id,
                fileName: state.fileName,
                sanitizedFileName: sanitizedFileName(state.fileName),
                fileSize: state.totalBytes,
                checksum: "",
                createdAt: Date(),
                reason: "Transfer canceled"
            )
            sendFileTransferMessage(.cancel(cancel))
            finishPendingContinuationsForCancellation()
        case .fromMac:
            guard let incoming = incomingTransferState else { return }
            let cancel = FileTransferCancelMessage(
                transferID: incoming.offer.transferID,
                sessionID: sessionID,
                senderDeviceID: clientIdentity.id,
                fileName: incoming.offer.fileName,
                sanitizedFileName: incoming.offer.sanitizedFileName,
                fileSize: incoming.offer.fileSize,
                checksum: incoming.offer.checksum,
                createdAt: Date(),
                reason: "Transfer canceled on this Mac"
            )
            sendFileTransferMessage(.cancel(cancel))
            cleanupIncomingTransfer(deleteFile: true)
        }
        activeTransfer?.status = .canceled
        lastMessage = "Transfer canceled"
    }

    func acceptIncomingTransfer() {
        guard let prompt = incomingPrompt,
              let offer = pendingIncomingOffers[prompt.id] else { return }
        guard activeTransfer == nil, incomingTransferState == nil else {
            rejectIncomingTransfer()
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vamp Terminal Incoming Transfers", isDirectory: true)
        let tempURL = directory.appendingPathComponent("\(UUID().uuidString)-\(offer.sanitizedFileName)", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)

            incomingTransferState = IncomingTransferState(
                offer: offer,
                tempURL: tempURL,
                fileHandle: handle,
                bytesReceived: 0,
                expectedChunkIndex: 0,
                hasher: SHA256()
            )
            activeTransfer = TransferState(
                id: offer.transferID,
                direction: .fromMac,
                fileName: offer.sanitizedFileName,
                transferredBytes: 0,
                totalBytes: offer.fileSize,
                status: .receiving
            )
            incomingPrompt = nil
            lastMessage = "Receiving file from your Mac."

            let accept = FileTransferAcceptMessage(
                transferID: offer.transferID,
                sessionID: offer.sessionID,
                senderDeviceID: clientIdentity.id,
                fileName: offer.fileName,
                sanitizedFileName: offer.sanitizedFileName,
                fileSize: offer.fileSize,
                checksum: offer.checksum,
                createdAt: Date(),
                destinationDescription: "Files on this Mac",
                maxChunkSize: incomingChunkSize
            )
            sendFileTransferMessage(.accept(accept))
        } catch {
            pendingIncomingOffers.removeValue(forKey: prompt.id)
            incomingPrompt = nil
            lastMessage = "Could not prepare secure file storage on this Mac."
            let reject = FileTransferRejectMessage(
                transferID: offer.transferID,
                sessionID: offer.sessionID,
                senderDeviceID: clientIdentity.id,
                fileName: offer.fileName,
                sanitizedFileName: offer.sanitizedFileName,
                fileSize: offer.fileSize,
                checksum: offer.checksum,
                createdAt: Date(),
                reason: "The client Mac could not prepare secure storage for this file."
            )
            sendFileTransferMessage(.reject(reject))
        }
    }

    func rejectIncomingTransfer() {
        guard let prompt = incomingPrompt,
              let offer = pendingIncomingOffers.removeValue(forKey: prompt.id) else { return }
        incomingPrompt = nil
        let reject = FileTransferRejectMessage(
            transferID: offer.transferID,
            sessionID: offer.sessionID,
            senderDeviceID: clientIdentity.id,
            fileName: offer.fileName,
            sanitizedFileName: offer.sanitizedFileName,
            fileSize: offer.fileSize,
            checksum: offer.checksum,
            createdAt: Date(),
            reason: "Transfer canceled on this Mac"
        )
        sendFileTransferMessage(.reject(reject))
    }

    func retrySavingReceivedFile() {
        guard pendingReceivedFile != nil else { return }
        isReceivedFileSavePresented = true
    }

    func handleReceivedFileSaveResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            if let pendingReceivedFile {
                try? FileManager.default.removeItem(at: pendingReceivedFile.url)
            }
            pendingReceivedFile = nil
            isReceivedFileSavePresented = false
            activeTransfer?.status = .completed("Saved to Files")
            lastMessage = "Saved to Files on your Mac"
        case .failure(let error):
            isReceivedFileSavePresented = false
            if let urlError = error as? URLError, urlError.code == .cancelled {
                activeTransfer?.status = .completed("Ready to save")
                lastMessage = "File is ready to save when you are."
            } else {
                activeTransfer?.status = .completed("Ready to save")
                lastMessage = error.localizedDescription
            }
        }
    }

    private func runSendFile(url: URL, sessionID: UUID) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let metadata = try await loadMetadata(for: url)
            currentOutgoingTransferID = metadata.transferID
            activeTransfer = TransferState(
                id: metadata.transferID,
                direction: .toMac,
                fileName: metadata.fileName,
                transferredBytes: 0,
                totalBytes: metadata.fileSize,
                status: .preparing
            )

            let offer = FileTransferOfferMessage(
                transferID: metadata.transferID,
                sessionID: sessionID,
                senderDeviceID: clientIdentity.id,
                fileName: metadata.fileName,
                sanitizedFileName: sanitizedFileName(metadata.fileName),
                fileSize: metadata.fileSize,
                mimeType: metadata.mimeType,
                uniformTypeIdentifier: metadata.uniformTypeIdentifier,
                checksum: metadata.checksum,
                createdAt: Date(),
                totalChunks: metadata.totalChunks
            )

            activeTransfer?.status = .waitingForMac
            try webRTCSessionManager.sendDataMessage(try DataChannelEnvelope.fileTransfer(.offer(offer), sessionID: sessionID))

            let acceptResult = await awaitAccept()
            let accept: FileTransferAcceptMessage
            switch acceptResult {
            case .accepted(let value):
                accept = value
            case .failed(let message):
                throw NSError(domain: "ClientFileTransfer", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
            }

            activeTransfer?.status = .sending
            try await sendChunks(url: url, metadata: metadata, accept: accept, sessionID: sessionID)

            let complete = FileTransferCompleteMessage(
                transferID: metadata.transferID,
                sessionID: sessionID,
                senderDeviceID: clientIdentity.id,
                fileName: metadata.fileName,
                sanitizedFileName: sanitizedFileName(metadata.fileName),
                fileSize: metadata.fileSize,
                checksum: metadata.checksum,
                createdAt: Date(),
                totalChunks: metadata.totalChunks,
                totalBytes: metadata.fileSize
            )
            try webRTCSessionManager.sendDataMessage(try DataChannelEnvelope.fileTransfer(.complete(complete), sessionID: sessionID))

            let completion = await awaitCompletion()
            let response: FileTransferCompleteMessage
            switch completion {
            case .completed(let value):
                response = value
            case .failed(let message):
                throw NSError(domain: "ClientFileTransfer", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
            }
            activeTransfer?.transferredBytes = metadata.fileSize
            activeTransfer?.status = .completed(response.destinationDescription ?? "Saved on your Mac")
            lastMessage = response.destinationDescription.map { "Saved in \($0) on your Mac" } ?? "Saved on your Mac"
            clearContinuationReferences()
        } catch is CancellationError {
            activeTransfer?.status = .canceled
            lastMessage = "Transfer canceled"
            finishPendingContinuationsForCancellation()
        } catch {
            if Task.isCancelled, case .canceled = activeTransfer?.status {
                // Leave canceled state intact.
            } else {
                activeTransfer?.status = .failed(error.localizedDescription)
                lastMessage = error.localizedDescription
            }
            finishPendingContinuationsForCancellation()
        }
    }

    private func sendChunks(
        url: URL,
        metadata: PreparedFileMetadata,
        accept: FileTransferAcceptMessage,
        sessionID: UUID
    ) async throws {
        let chunkSize = min(configurationChunkSize, max(1, accept.maxChunkSize))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var chunkIndex = 0
        var offset: Int64 = 0

        while !Task.isCancelled {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty {
                break
            }

            let chunk = FileTransferChunkMessage(
                transferID: metadata.transferID,
                sessionID: sessionID,
                senderDeviceID: clientIdentity.id,
                fileName: metadata.fileName,
                sanitizedFileName: sanitizedFileName(metadata.fileName),
                fileSize: metadata.fileSize,
                checksum: metadata.checksum,
                createdAt: Date(),
                chunkIndex: chunkIndex,
                totalChunks: metadata.totalChunks,
                byteOffset: offset,
                chunkChecksum: SHA256.hash(data: data).hexString,
                data: data
            )
            currentChunkIndexWaitingForAck = chunkIndex
            try webRTCSessionManager.sendDataMessage(try DataChannelEnvelope.fileTransfer(.chunk(chunk), sessionID: sessionID))

            let progress = await awaitChunkProgress()
            guard let progress, progress.chunkIndex == chunkIndex else {
                throw NSError(domain: "ClientFileTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection lost during transfer"])
            }

            offset = progress.bytesReceived
            activeTransfer?.transferredBytes = progress.bytesReceived
            chunkIndex += 1
        }
    }

    private func handleFileTransferMessage(_ message: FileTransferMessage) async {
        switch message {
        case .offer(let offer):
            handleIncomingOffer(offer)
        case .chunk(let chunk):
            await handleIncomingChunk(chunk)
        case .complete(let complete):
            await handleIncomingComplete(complete)
        case .cancel(let cancel):
            handleOutgoingCancel(cancel)
            handleIncomingCancel(cancel)
        case .error(let error):
            handleOutgoingError(error)
            handleIncomingError(error)
        case .accept(let accept):
            handleOutgoingAccept(accept)
        case .reject(let reject):
            handleOutgoingReject(reject)
        case .progress(let progress):
            handleOutgoingProgress(progress)
        }
    }

    private func handleIncomingOffer(_ offer: FileTransferOfferMessage) {
        guard offer.sessionID == sessionCoordinator.activeSessionID else { return }
        guard isEnabled else {
            let reject = FileTransferRejectMessage(
                transferID: offer.transferID,
                sessionID: offer.sessionID,
                senderDeviceID: clientIdentity.id,
                fileName: offer.fileName,
                sanitizedFileName: offer.sanitizedFileName,
                fileSize: offer.fileSize,
                checksum: offer.checksum,
                createdAt: Date(),
                reason: "File transfer is disabled on this Mac."
            )
            sendFileTransferMessage(.reject(reject))
            return
        }
        guard offer.fileSize >= 0, offer.fileSize <= maxIncomingFileSizeBytes else {
            let reject = FileTransferRejectMessage(
                transferID: offer.transferID,
                sessionID: offer.sessionID,
                senderDeviceID: clientIdentity.id,
                fileName: offer.fileName,
                sanitizedFileName: offer.sanitizedFileName,
                fileSize: offer.fileSize,
                checksum: offer.checksum,
                createdAt: Date(),
                reason: "File is too large for this Mac."
            )
            sendFileTransferMessage(.reject(reject))
            return
        }
        guard activeTransfer == nil, incomingTransferState == nil, incomingPrompt == nil else {
            let reject = FileTransferRejectMessage(
                transferID: offer.transferID,
                sessionID: offer.sessionID,
                senderDeviceID: clientIdentity.id,
                fileName: offer.fileName,
                sanitizedFileName: offer.sanitizedFileName,
                fileSize: offer.fileSize,
                checksum: offer.checksum,
                createdAt: Date(),
                reason: "Another transfer is already active on this Mac."
            )
            sendFileTransferMessage(.reject(reject))
            return
        }

        pendingIncomingOffers[offer.transferID] = offer
        incomingPrompt = IncomingTransferPrompt(
            id: offer.transferID,
            fileName: offer.sanitizedFileName.isEmpty ? offer.fileName : offer.sanitizedFileName,
            fileSize: offer.fileSize
        )
    }

    private func handleIncomingChunk(_ chunk: FileTransferChunkMessage) async {
        guard var state = incomingTransferState, chunk.transferID == state.offer.transferID else { return }
        guard chunk.sessionID == state.offer.sessionID,
              chunk.senderDeviceID == state.offer.senderDeviceID,
              chunk.fileSize == state.offer.fileSize,
              chunk.totalChunks == state.offer.totalChunks,
              chunk.checksum == state.offer.checksum else {
            await failIncomingTransfer(code: "metadata_mismatch", message: "Transfer metadata did not match the approved request.")
            return
        }
        guard chunk.data.count <= incomingChunkSize else {
            await failIncomingTransfer(code: "chunk_too_large", message: "Transfer chunk was too large.")
            return
        }
        guard chunk.chunkIndex == state.expectedChunkIndex else {
            await failIncomingTransfer(code: "unexpected_chunk", message: "Transfer chunks arrived out of order.")
            return
        }
        guard chunk.byteOffset == state.bytesReceived else {
            await failIncomingTransfer(code: "offset_mismatch", message: "Transfer byte offset did not match.")
            return
        }
        guard state.bytesReceived + Int64(chunk.data.count) <= state.offer.fileSize else {
            await failIncomingTransfer(code: "size_overflow", message: "Transfer exceeded the approved file size.")
            return
        }

        let chunkChecksum = SHA256.hash(data: chunk.data).hexString
        guard chunkChecksum == chunk.chunkChecksum else {
            await failIncomingTransfer(code: "bad_chunk_checksum", message: "Transfer checksum validation failed.")
            return
        }

        do {
            try state.fileHandle.write(contentsOf: chunk.data)
            state.hasher.update(data: chunk.data)
            state.bytesReceived += Int64(chunk.data.count)
            state.expectedChunkIndex += 1
            incomingTransferState = state
            activeTransfer?.transferredBytes = state.bytesReceived

            let progress = FileTransferProgressMessage(
                transferID: state.offer.transferID,
                sessionID: state.offer.sessionID,
                senderDeviceID: clientIdentity.id,
                fileName: state.offer.fileName,
                sanitizedFileName: state.offer.sanitizedFileName,
                fileSize: state.offer.fileSize,
                checksum: state.offer.checksum,
                createdAt: Date(),
                chunkIndex: chunk.chunkIndex,
                totalChunks: state.offer.totalChunks,
                bytesReceived: state.bytesReceived
            )
            sendFileTransferMessage(.progress(progress))
        } catch {
            await failIncomingTransfer(code: "write_failed", message: "Could not write transfer data on this Mac.")
        }
    }

    private func handleIncomingComplete(_ complete: FileTransferCompleteMessage) async {
        guard let state = incomingTransferState, complete.transferID == state.offer.transferID else { return }
        guard complete.sessionID == state.offer.sessionID,
              complete.senderDeviceID == state.offer.senderDeviceID,
              complete.fileSize == state.offer.fileSize,
              complete.totalChunks == state.offer.totalChunks,
              complete.checksum == state.offer.checksum,
              complete.totalBytes == state.bytesReceived,
              complete.totalBytes == state.offer.fileSize else {
            await failIncomingTransfer(code: "metadata_mismatch", message: "Transfer metadata did not match the approved request.")
            return
        }

        let digest = state.hasher.finalize().hexString
        guard digest == state.offer.checksum else {
            await failIncomingTransfer(code: "bad_checksum", message: "Transfer checksum validation failed.")
            return
        }

        do {
            try state.fileHandle.close()
            incomingTransferState = nil
            pendingIncomingOffers.removeValue(forKey: complete.transferID)
            pendingReceivedFile = PendingReceivedFile(url: state.tempURL, fileName: state.offer.sanitizedFileName)
            activeTransfer?.transferredBytes = state.bytesReceived
            activeTransfer?.status = .completed("Ready to save")
            lastMessage = "Choose where to save the file on your Mac."
            let response = FileTransferCompleteMessage(
                transferID: complete.transferID,
                sessionID: complete.sessionID,
                senderDeviceID: clientIdentity.id,
                fileName: complete.fileName,
                sanitizedFileName: state.offer.sanitizedFileName,
                fileSize: complete.fileSize,
                checksum: complete.checksum,
                createdAt: Date(),
                totalChunks: complete.totalChunks,
                totalBytes: complete.totalBytes,
                destinationDescription: "Files on this Mac"
            )
            sendFileTransferMessage(.complete(response))
            isReceivedFileSavePresented = true
        } catch {
            await failIncomingTransfer(code: "finalize_failed", message: "Could not finalize the received file on this Mac.")
        }
    }

    private func handleIncomingCancel(_ cancel: FileTransferCancelMessage) {
        guard cancel.transferID == incomingTransferState?.offer.transferID || cancel.transferID == incomingPrompt?.id else { return }
        cleanupIncomingTransfer(deleteFile: true)
        incomingPrompt = nil
        pendingIncomingOffers.removeValue(forKey: cancel.transferID)
        activeTransfer?.status = .canceled
        lastMessage = cancel.reason
    }

    private func handleIncomingError(_ error: FileTransferErrorMessage) {
        guard error.transferID == incomingTransferState?.offer.transferID || error.transferID == incomingPrompt?.id else { return }
        cleanupIncomingTransfer(deleteFile: true)
        incomingPrompt = nil
        pendingIncomingOffers.removeValue(forKey: error.transferID)
        activeTransfer?.status = .failed(error.message)
        lastMessage = error.message
    }

    private func failIncomingTransfer(code: String, message: String) async {
        guard let state = incomingTransferState else { return }
        cleanupIncomingTransfer(deleteFile: true)
        activeTransfer?.status = .failed(message)
        lastMessage = message
        let error = FileTransferErrorMessage(
            transferID: state.offer.transferID,
            sessionID: state.offer.sessionID,
            senderDeviceID: clientIdentity.id,
            fileName: state.offer.fileName,
            sanitizedFileName: state.offer.sanitizedFileName,
            fileSize: state.offer.fileSize,
            checksum: state.offer.checksum,
            createdAt: Date(),
            errorCode: code,
            message: message
        )
        sendFileTransferMessage(.error(error))
    }

    private func cleanupIncomingTransfer(deleteFile: Bool) {
        if let state = incomingTransferState {
            try? state.fileHandle.close()
            if deleteFile {
                try? FileManager.default.removeItem(at: state.tempURL)
            }
        }
        incomingTransferState = nil
    }

    private func handleOutgoingAccept(_ accept: FileTransferAcceptMessage) {
        guard accept.transferID == currentOutgoingTransferID else { return }
        acceptTimeoutTask?.cancel()
        acceptTimeoutTask = nil
        acceptContinuation?.resume(returning: .accepted(accept))
        acceptContinuation = nil
    }

    private func handleOutgoingReject(_ reject: FileTransferRejectMessage) {
        guard reject.transferID == currentOutgoingTransferID else { return }
        acceptTimeoutTask?.cancel()
        acceptTimeoutTask = nil
        acceptContinuation?.resume(returning: .failed(reject.reason))
        acceptContinuation = nil
        activeTransfer?.status = .failed(reject.reason)
    }

    private func handleOutgoingProgress(_ progress: FileTransferProgressMessage) {
        guard progress.transferID == currentOutgoingTransferID else { return }
        if currentChunkIndexWaitingForAck == progress.chunkIndex {
            progressTimeoutTask?.cancel()
            progressTimeoutTask = nil
            progressContinuation?.resume(returning: progress)
            progressContinuation = nil
            currentChunkIndexWaitingForAck = nil
        }
    }

    private func handleOutgoingCancel(_ cancel: FileTransferCancelMessage) {
        guard cancel.transferID == currentOutgoingTransferID else { return }
        completionTimeoutTask?.cancel()
        completionTimeoutTask = nil
        completionContinuation?.resume(returning: .failed(cancel.reason))
        completionContinuation = nil
    }

    private func handleOutgoingError(_ error: FileTransferErrorMessage) {
        guard error.transferID == currentOutgoingTransferID else { return }
        acceptTimeoutTask?.cancel()
        progressTimeoutTask?.cancel()
        completionTimeoutTask?.cancel()
        acceptTimeoutTask = nil
        progressTimeoutTask = nil
        completionTimeoutTask = nil
        if acceptContinuation != nil {
            acceptContinuation?.resume(returning: .failed(error.message))
            acceptContinuation = nil
        } else if completionContinuation != nil {
            completionContinuation?.resume(returning: .failed(error.message))
            completionContinuation = nil
        } else {
            progressContinuation?.resume(returning: nil)
            progressContinuation = nil
        }
        activeTransfer?.status = .failed(error.message)
    }

    private func awaitAccept() async -> AcceptOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<AcceptOutcome, Never>) in
            acceptContinuation = continuation
            scheduleAcceptTimeout()
        }
    }

    private func awaitChunkProgress() async -> FileTransferProgressMessage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<FileTransferProgressMessage?, Never>) in
            progressContinuation = continuation
            scheduleProgressTimeout()
        }
    }

    private func awaitCompletion() async -> CompletionOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<CompletionOutcome, Never>) in
            completionContinuation = continuation
            scheduleCompletionTimeout()
        }
    }

    private func scheduleAcceptTimeout() {
        acceptTimeoutTask?.cancel()
        acceptTimeoutTask = Task { [weak self] in
            let timeout = UInt64((self?.acceptTimeoutSeconds ?? 30) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: timeout)
            await MainActor.run {
                guard let self, let continuation = self.acceptContinuation else { return }
                continuation.resume(returning: .failed("The Mac did not respond to the transfer request in time."))
                self.acceptContinuation = nil
                self.acceptTimeoutTask = nil
            }
        }
    }

    private func scheduleProgressTimeout() {
        progressTimeoutTask?.cancel()
        progressTimeoutTask = Task { [weak self] in
            let timeout = UInt64((self?.progressTimeoutSeconds ?? 20) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: timeout)
            await MainActor.run {
                guard let self, let continuation = self.progressContinuation else { return }
                continuation.resume(returning: nil)
                self.progressContinuation = nil
                self.progressTimeoutTask = nil
            }
        }
    }

    private func scheduleCompletionTimeout() {
        completionTimeoutTask?.cancel()
        completionTimeoutTask = Task { [weak self] in
            let timeout = UInt64((self?.completionTimeoutSeconds ?? 30) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: timeout)
            await MainActor.run {
                guard let self, let continuation = self.completionContinuation else { return }
                continuation.resume(returning: .failed("The Mac did not confirm the transfer in time."))
                self.completionContinuation = nil
                self.completionTimeoutTask = nil
            }
        }
    }

    private func finishPendingContinuationsForCancellation() {
        acceptTimeoutTask?.cancel()
        progressTimeoutTask?.cancel()
        completionTimeoutTask?.cancel()
        acceptTimeoutTask = nil
        progressTimeoutTask = nil
        completionTimeoutTask = nil

        if let acceptContinuation {
            acceptContinuation.resume(returning: .failed("Transfer canceled"))
            self.acceptContinuation = nil
        }
        if let progressContinuation {
            progressContinuation.resume(returning: nil)
            self.progressContinuation = nil
        }
        if let completionContinuation {
            completionContinuation.resume(returning: .failed("Transfer canceled"))
            self.completionContinuation = nil
        }
        clearContinuationReferences()
    }

    private func clearContinuationReferences() {
        acceptTimeoutTask?.cancel()
        progressTimeoutTask?.cancel()
        completionTimeoutTask?.cancel()
        acceptTimeoutTask = nil
        progressTimeoutTask = nil
        completionTimeoutTask = nil
        currentOutgoingTransferID = nil
        currentChunkIndexWaitingForAck = nil
        acceptContinuation = nil
        progressContinuation = nil
        completionContinuation = nil
    }

    private var configurationChunkSize: Int { 24 * 1024 }

    private func sanitizedFileName(_ fileName: String) -> String {
        FileTransferSanitizer.sanitizeFileName(fileName)
    }

    private func sendFileTransferMessage(_ message: FileTransferMessage) {
        guard let sessionID = sessionCoordinator.activeSessionID,
              let envelope = try? DataChannelEnvelope.fileTransfer(message, sessionID: sessionID) else {
            return
        }
        try? webRTCSessionManager.sendDataMessage(envelope)
    }

    private func loadMetadata(for url: URL) async throws -> PreparedFileMetadata {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .nameKey])
        guard let fileSize = values.fileSize.map(Int64.init) else {
            throw NSError(domain: "ClientFileTransfer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read file size"])
        }
        let maxFileSize: Int64 = 2 * 1024 * 1024 * 1024
        guard fileSize <= maxFileSize else {
            throw NSError(domain: "ClientFileTransfer", code: 5, userInfo: [NSLocalizedDescriptionKey: "File is too large to transfer (2 GB maximum)"])
        }

        let checksum = try await sha256Hex(for: url)
        let fileName = values.name ?? url.lastPathComponent
        let totalChunks = fileSize == 0 ? 0 : Int((fileSize + Int64(configurationChunkSize) - 1) / Int64(configurationChunkSize))

        return PreparedFileMetadata(
            transferID: UUID(),
            fileName: fileName,
            fileSize: fileSize,
            mimeType: values.contentType?.preferredMIMEType,
            uniformTypeIdentifier: values.contentType?.identifier,
            checksum: checksum,
            totalChunks: totalChunks
        )
    }

    private func sha256Hex(for url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().hexString
        }.value
    }
}

private struct PreparedFileMetadata {
    let transferID: UUID
    let fileName: String
    let fileSize: Int64
    let mimeType: String?
    let uniformTypeIdentifier: String?
    let checksum: String
    let totalChunks: Int
}

private extension Digest {
    var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}
