import CryptoKit
import Foundation
import SharedModels
import SharedProtocol
import TransportWebRTC
import UniformTypeIdentifiers

@MainActor
final class HostOutgoingFileTransferController: ObservableObject {
    private enum AcceptOutcome {
        case accepted(FileTransferAcceptMessage)
        case failed(String)
    }

    private enum CompletionOutcome {
        case completed(FileTransferCompleteMessage)
        case failed(String)
    }

    struct TransferState: Identifiable, Equatable {
        enum Status: Equatable {
            case preparing
            case waitingForClient
            case sending
            case completed(String)
            case canceled
            case failed(String)
        }

        let id: UUID
        var fileName: String
        var transferredBytes: Int64
        var totalBytes: Int64
        var status: Status

        var progress: Double {
            guard totalBytes > 0 else { return status == .completed("") ? 1 : 0 }
            return min(1, Double(transferredBytes) / Double(totalBytes))
        }
    }

    @Published private(set) var activeTransfer: TransferState?
    @Published private(set) var lastMessage: String?

    private let webRTCSessionManager: any WebRTCSessionManaging
    private let hostIdentity: HostIdentity
    private var sendingTask: Task<Void, Never>?
    private var acceptTimeoutTask: Task<Void, Never>?
    private var progressTimeoutTask: Task<Void, Never>?
    private var completionTimeoutTask: Task<Void, Never>?
    private var acceptContinuation: CheckedContinuation<AcceptOutcome, Never>?
    private var progressContinuation: CheckedContinuation<FileTransferProgressMessage?, Never>?
    private var completionContinuation: CheckedContinuation<CompletionOutcome, Never>?
    private var currentTransferID: UUID?
    private var currentChunkIndexWaitingForAck: Int?
    private let acceptTimeoutSeconds: TimeInterval = 30
    private let progressTimeoutSeconds: TimeInterval = 20
    private let completionTimeoutSeconds: TimeInterval = 30

    init(webRTCSessionManager: any WebRTCSessionManaging, hostIdentity: HostIdentity) {
        self.webRTCSessionManager = webRTCSessionManager
        self.hostIdentity = hostIdentity
    }

    func sendFile(url: URL, sessionID: UUID) {
        guard activeTransfer == nil else {
            lastMessage = "Finish the current transfer first."
            return
        }

        sendingTask?.cancel()
        sendingTask = Task { [weak self] in
            await self?.runSendFile(url: url, sessionID: sessionID)
        }
    }

    func cancelActiveTransfer(sessionID: UUID) {
        guard let transferID = currentTransferID,
              let state = activeTransfer else { return }
        sendingTask?.cancel()
        let cancel = FileTransferCancelMessage(
            transferID: transferID,
            sessionID: sessionID,
            senderDeviceID: hostIdentity.id,
            fileName: state.fileName,
            sanitizedFileName: FileTransferSanitizer.sanitizeFileName(state.fileName),
            fileSize: state.totalBytes,
            checksum: "",
            createdAt: Date(),
            reason: "Transfer canceled on Mac"
        )
        if let envelope = try? DataChannelEnvelope.fileTransfer(.cancel(cancel), sessionID: sessionID) {
            try? webRTCSessionManager.sendDataMessage(envelope)
        }
        activeTransfer?.status = .canceled
        lastMessage = "Transfer canceled"
        finishPendingContinuationsForCancellation()
    }

    func dismissTransfer() {
        guard let state = activeTransfer else { return }
        switch state.status {
        case .completed, .failed, .canceled:
            activeTransfer = nil
            lastMessage = nil
        default:
            break
        }
    }

    func handleRemoteMessage(_ message: FileTransferMessage) async {
        guard let currentTransferID else { return }
        switch message {
        case .accept(let accept) where accept.transferID == currentTransferID:
            acceptTimeoutTask?.cancel()
            acceptTimeoutTask = nil
            acceptContinuation?.resume(returning: .accepted(accept))
            acceptContinuation = nil
        case .reject(let reject) where reject.transferID == currentTransferID:
            acceptTimeoutTask?.cancel()
            acceptTimeoutTask = nil
            acceptContinuation?.resume(returning: .failed(reject.reason))
            acceptContinuation = nil
            activeTransfer?.status = .failed(reject.reason)
        case .progress(let progress) where progress.transferID == currentTransferID:
            if currentChunkIndexWaitingForAck == progress.chunkIndex {
                progressTimeoutTask?.cancel()
                progressTimeoutTask = nil
                progressContinuation?.resume(returning: progress)
                progressContinuation = nil
                currentChunkIndexWaitingForAck = nil
            }
        case .complete(let complete) where complete.transferID == currentTransferID:
            completionTimeoutTask?.cancel()
            completionTimeoutTask = nil
            completionContinuation?.resume(returning: .completed(complete))
            completionContinuation = nil
        case .cancel(let cancel) where cancel.transferID == currentTransferID:
            completionTimeoutTask?.cancel()
            completionTimeoutTask = nil
            completionContinuation?.resume(returning: .failed(cancel.reason))
            completionContinuation = nil
        case .error(let error) where error.transferID == currentTransferID:
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
        default:
            break
        }
    }

    private func runSendFile(url: URL, sessionID: UUID) async {
        do {
            let metadata = try await loadMetadata(for: url)
            currentTransferID = metadata.transferID
            activeTransfer = TransferState(
                id: metadata.transferID,
                fileName: metadata.fileName,
                transferredBytes: 0,
                totalBytes: metadata.fileSize,
                status: .preparing
            )

            let offer = FileTransferOfferMessage(
                transferID: metadata.transferID,
                sessionID: sessionID,
                senderDeviceID: hostIdentity.id,
                fileName: metadata.fileName,
                sanitizedFileName: FileTransferSanitizer.sanitizeFileName(metadata.fileName),
                fileSize: metadata.fileSize,
                mimeType: metadata.mimeType,
                uniformTypeIdentifier: metadata.uniformTypeIdentifier,
                checksum: metadata.checksum,
                createdAt: Date(),
                totalChunks: metadata.totalChunks
            )

            activeTransfer?.status = .waitingForClient
            try webRTCSessionManager.sendDataMessage(try DataChannelEnvelope.fileTransfer(.offer(offer), sessionID: sessionID))

            let acceptResult = await awaitAccept()
            let accept: FileTransferAcceptMessage
            switch acceptResult {
            case .accepted(let value):
                accept = value
            case .failed(let message):
                throw NSError(domain: "HostOutgoingFileTransfer", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
            }

            activeTransfer?.status = .sending
            try await sendChunks(url: url, metadata: metadata, accept: accept, sessionID: sessionID)

            let complete = FileTransferCompleteMessage(
                transferID: metadata.transferID,
                sessionID: sessionID,
                senderDeviceID: hostIdentity.id,
                fileName: metadata.fileName,
                sanitizedFileName: FileTransferSanitizer.sanitizeFileName(metadata.fileName),
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
                throw NSError(domain: "HostOutgoingFileTransfer", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
            }
            activeTransfer?.transferredBytes = metadata.fileSize
            activeTransfer?.status = .completed(response.destinationDescription ?? "Saved on client Mac")
            lastMessage = response.destinationDescription.map { "Saved on client Mac: \($0)" } ?? "Saved on client Mac"
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
                senderDeviceID: hostIdentity.id,
                fileName: metadata.fileName,
                sanitizedFileName: FileTransferSanitizer.sanitizeFileName(metadata.fileName),
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
                throw NSError(domain: "HostOutgoingFileTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection lost during transfer"])
            }

            offset = progress.bytesReceived
            activeTransfer?.transferredBytes = progress.bytesReceived
            chunkIndex += 1
        }
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
            guard let self else { return }
            let timeout = UInt64(self.acceptTimeoutSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: timeout)
            await MainActor.run {
                guard let continuation = self.acceptContinuation else { return }
                continuation.resume(returning: .failed("The client Mac did not respond to the transfer request in time."))
                self.acceptContinuation = nil
                self.acceptTimeoutTask = nil
            }
        }
    }

    private func scheduleProgressTimeout() {
        progressTimeoutTask?.cancel()
        progressTimeoutTask = Task { [weak self] in
            guard let self else { return }
            let timeout = UInt64(self.progressTimeoutSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: timeout)
            await MainActor.run {
                guard let continuation = self.progressContinuation else { return }
                continuation.resume(returning: nil)
                self.progressContinuation = nil
                self.progressTimeoutTask = nil
            }
        }
    }

    private func scheduleCompletionTimeout() {
        completionTimeoutTask?.cancel()
        completionTimeoutTask = Task { [weak self] in
            guard let self else { return }
            let timeout = UInt64(self.completionTimeoutSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: timeout)
            await MainActor.run {
                guard let continuation = self.completionContinuation else { return }
                continuation.resume(returning: .failed("The client Mac did not confirm the transfer in time."))
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
        currentTransferID = nil
        currentChunkIndexWaitingForAck = nil
        acceptContinuation = nil
        progressContinuation = nil
        completionContinuation = nil
    }

    private var configurationChunkSize: Int { 24 * 1024 }

    private func loadMetadata(for url: URL) async throws -> PreparedFileMetadata {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .nameKey])
        guard let fileSize = values.fileSize.map(Int64.init) else {
            throw NSError(domain: "HostOutgoingFileTransfer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read file size"])
        }
        let maxFileSize: Int64 = 2 * 1024 * 1024 * 1024
        guard fileSize <= maxFileSize else {
            throw NSError(domain: "HostOutgoingFileTransfer", code: 5, userInfo: [NSLocalizedDescriptionKey: "File is too large to transfer (2 GB maximum)"])
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
