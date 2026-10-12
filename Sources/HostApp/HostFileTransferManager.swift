import CryptoKit
import Foundation
import Permissions
import SharedProtocol
import TransportWebRTC
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

@MainActor
final class HostFileTransferSettingsStore: ObservableObject {
    private enum Keys {
        static let isEnabled = "com.remotedesktop.host.filetransfer.enabled"
        static let maxFileSizeMB = "com.remotedesktop.host.filetransfer.maxFileSizeMB"
        static let requireConfirmation = "com.remotedesktop.host.filetransfer.requireConfirmation"
        static let saveLocationBookmark = "com.remotedesktop.host.filetransfer.saveLocationBookmark"
        static let saveLocationPath = "com.remotedesktop.host.filetransfer.saveLocationPath"
    }

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }
    @Published var maxFileSizeMB: Int {
        didSet { defaults.set(maxFileSizeMB, forKey: Keys.maxFileSizeMB) }
    }
    @Published var requireConfirmation: Bool {
        didSet { defaults.set(requireConfirmation, forKey: Keys.requireConfirmation) }
    }
    @Published private(set) var saveLocationPath: String?

    private let defaults: UserDefaults
    private let supportsDefaultDownloadsFallback: Bool
    private var saveLocationBookmark: Data?

    init(defaults: UserDefaults = .standard, supportsDefaultDownloadsLocation: Bool) {
        self.defaults = defaults
        self.supportsDefaultDownloadsFallback = supportsDefaultDownloadsLocation
        self.isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? true
        self.maxFileSizeMB = max(1, defaults.object(forKey: Keys.maxFileSizeMB) as? Int ?? 100)
        self.requireConfirmation = defaults.object(forKey: Keys.requireConfirmation) as? Bool ?? true
        self.saveLocationBookmark = defaults.data(forKey: Keys.saveLocationBookmark)
        self.saveLocationPath = defaults.string(forKey: Keys.saveLocationPath)
    }

    var maxFileSizeBytes: Int64 {
        Int64(maxFileSizeMB) * 1_048_576
    }

    var supportsDefaultDownloadsLocation: Bool {
        supportsDefaultDownloadsFallback
    }

    var effectiveSaveLocationDescription: String {
        effectiveSaveLocationDisplayName
    }

    var effectiveSaveLocationDisplayName: String {
        if let path = saveLocationPath, !path.isEmpty {
            return displayName(for: URL(fileURLWithPath: path, isDirectory: true))
        }
        if supportsDefaultDownloadsLocation {
            return "Downloads/Vamp Host Transfers"
        }
        return "Choose a folder in Vamp Host settings"
    }

    func scopedSaveDirectory() -> ScopedDirectoryAccess? {
        if let bookmark = saveLocationBookmark {
            var stale = false
            #if os(macOS)
            let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let resolutionOptions: URL.BookmarkResolutionOptions = []
            #endif
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: resolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                let started = url.startAccessingSecurityScopedResource()
                return ScopedDirectoryAccess(url: url, stopAccessing: started)
            }
        }

        guard supportsDefaultDownloadsLocation else {
            return nil
        }
        return ScopedDirectoryAccess(url: defaultDownloadsDirectory, stopAccessing: false)
    }

    func setSaveLocation(url: URL, bookmark: Data?) {
        saveLocationPath = url.path
        defaults.set(url.path, forKey: Keys.saveLocationPath)
        saveLocationBookmark = bookmark
        defaults.set(bookmark, forKey: Keys.saveLocationBookmark)
    }

    #if os(macOS)
    func chooseSaveLocation() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose where incoming files from Vamp Host should be saved."

        if panel.runModal() == .OK, let url = panel.url {
            let bookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            setSaveLocation(url: url, bookmark: bookmark)
        }
    }
    #endif

    private var defaultDownloadsDirectory: URL {
        #if os(macOS)
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        #else
        let homeDir = FileManager.default.temporaryDirectory
        #endif
        return homeDir
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("Vamp Host Transfers", isDirectory: true)
    }

    private func displayName(for url: URL) -> String {
        let lastComponent = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lastComponent.isEmpty else { return "Chosen transfer folder" }
        return lastComponent
    }
}

struct ScopedDirectoryAccess {
    let url: URL
    let stopAccessing: Bool
}

enum HostFileTransferHistoryStatus: String, Codable, Hashable, Sendable {
    case pending
    case inProgress
    case completed
    case canceled
    case rejected
    case failed
}

struct HostFileTransferHistoryItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let fileName: String
    let destinationDescription: String
    let savedFileURL: URL?
    let status: HostFileTransferHistoryStatus
    let transferredBytes: Int64
    let totalBytes: Int64
    let updatedAt: Date
    let detail: String?
}

struct HostIncomingTransferPrompt: Identifiable, Equatable {
    let id: UUID
    let fileName: String
    let fileSize: Int64
    let destinationDescription: String
}

@MainActor
final class HostFileTransferStore: ObservableObject {
    @Published private(set) var history: [HostFileTransferHistoryItem] = []
    @Published var pendingPrompt: HostIncomingTransferPrompt?
    @Published private(set) var activeTransferSummary: HostFileTransferHistoryItem?

    private var promptContinuation: CheckedContinuation<Bool, Never>?

    func requestApproval(for prompt: HostIncomingTransferPrompt) async -> Bool {
        pendingPrompt = prompt
        return await withCheckedContinuation { continuation in
            promptContinuation = continuation
        }
    }

    func resolvePrompt(approved: Bool) {
        pendingPrompt = nil
        promptContinuation?.resume(returning: approved)
        promptContinuation = nil
    }

    func updateActiveTransfer(_ item: HostFileTransferHistoryItem?) {
        activeTransferSummary = item
        if let item {
            upsert(item)
        }
    }

    func record(_ item: HostFileTransferHistoryItem) {
        if item.status != .inProgress && item.status != .pending {
            activeTransferSummary = nil
        }
        upsert(item)
    }

    func clearHistory() {
        history.removeAll()
        activeTransferSummary = nil
    }

    #if os(macOS)
    func reveal(_ item: HostFileTransferHistoryItem) {
        guard let savedFileURL = item.savedFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedFileURL])
    }
    #endif

    private func upsert(_ item: HostFileTransferHistoryItem) {
        if let index = history.firstIndex(where: { $0.id == item.id }) {
            history[index] = item
        } else {
            history.insert(item, at: 0)
        }
        history.sort { $0.updatedAt > $1.updatedAt }
    }
}

actor HostFileTransferManager {
    struct Configuration {
        var chunkTimeoutSeconds: TimeInterval = 15
        var maxChunkSizeBytes: Int = 32 * 1024
    }

    private struct IncomingTransferState {
        var offer: FileTransferOfferMessage
        var sanitizedFileName: String
        var destinationDirectory: ScopedDirectoryAccess
        var finalURL: URL
        var tempURL: URL
        var fileHandle: FileHandle
        var bytesReceived: Int64
        var expectedChunkIndex: Int
        var hasher: SHA256
        var lastActivityAt: Date
        var timeoutTask: Task<Void, Never>?
    }

    private let settings: HostFileTransferSettingsStore
    private let store: HostFileTransferStore
    private let configuration: Configuration
    private var activeTransfers: [UUID: IncomingTransferState] = [:]
    private var seenTransferIDs = Set<UUID>()
    private var seenTransferIDQueue: [UUID] = []
    private let maxSeenTransferIDs = 1000
    private var pendingApprovalTransferID: UUID?

    init(
        settings: HostFileTransferSettingsStore,
        store: HostFileTransferStore,
        configuration: Configuration = Configuration()
    ) {
        self.settings = settings
        self.store = store
        self.configuration = configuration
    }

    deinit {
        for state in activeTransfers.values {
            state.timeoutTask?.cancel()
            try? state.fileHandle.close()
            try? FileManager.default.removeItem(at: state.tempURL)
            if state.destinationDirectory.stopAccessing {
                state.destinationDirectory.url.stopAccessingSecurityScopedResource()
            }
        }
    }

    func handle(
        _ message: FileTransferMessage,
        sendResponse: @escaping @Sendable (TransportWebRTC.DataChannelEnvelope) async -> Void
    ) async {
        switch message {
        case .offer(let offer):
            await handleOffer(offer, sendResponse: sendResponse)
        case .chunk(let chunk):
            await handleChunk(chunk, sendResponse: sendResponse)
        case .complete(let complete):
            await handleComplete(complete, sendResponse: sendResponse)
        case .cancel(let cancel):
            await handleCancel(cancel, reason: cancel.reason)
        case .accept, .reject, .progress, .error:
            break
        }
    }

    private func handleOffer(
        _ offer: FileTransferOfferMessage,
        sendResponse: @escaping @Sendable (TransportWebRTC.DataChannelEnvelope) async -> Void
    ) async {
        guard !seenTransferIDs.contains(offer.transferID), activeTransfers[offer.transferID] == nil else {
            await sendResponse(errorEnvelope(
                code: "duplicate_transfer_id",
                message: "Duplicate transfer request.",
                offer: offer
            ))
            return
        }
        guard pendingApprovalTransferID == nil else {
            await sendResponse(rejectEnvelope(reason: "Another incoming transfer is awaiting approval on this Mac.", offer: offer))
            return
        }

        guard offer.fileSize >= 0 else {
            await sendResponse(errorEnvelope(code: "invalid_file_size", message: "Invalid file size.", offer: offer))
            return
        }

        let settingsSnapshot = await MainActor.run {
            (
                isEnabled: settings.isEnabled,
                maxBytes: settings.maxFileSizeBytes,
                requireConfirmation: settings.requireConfirmation,
                destination: settings.scopedSaveDirectory(),
                destinationDescription: settings.effectiveSaveLocationDisplayName
            )
        }

        guard settingsSnapshot.isEnabled else {
            await sendResponse(rejectEnvelope(reason: "File transfer is disabled on this Mac.", offer: offer))
            return
        }
        guard offer.fileSize <= settingsSnapshot.maxBytes else {
            await sendResponse(rejectEnvelope(reason: "File too large for this Mac.", offer: offer))
            return
        }
        guard let scopedDirectory = settingsSnapshot.destination else {
            await sendResponse(rejectEnvelope(reason: "Choose a save folder in Vamp Host settings first.", offer: offer))
            return
        }

        let sanitizedName = sanitizeFileName(offer.sanitizedFileName.isEmpty ? offer.fileName : offer.sanitizedFileName)
        let prompt = HostIncomingTransferPrompt(
            id: offer.transferID,
            fileName: sanitizedName,
            fileSize: offer.fileSize,
            destinationDescription: settingsSnapshot.destinationDescription
        )

        if settingsSnapshot.requireConfirmation {
            pendingApprovalTransferID = offer.transferID
            // Safety timeout: if the approval prompt is dismissed without an explicit decision (the
            // continuation would otherwise never resume), auto-decline so pendingApprovalTransferID
            // can't get stuck and block ALL future incoming transfers until an app restart.
            // resolvePrompt() is nil-guarded, so this can't double-resume a user's real decision.
            let approvalTimeout = Task { [store] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                await store.resolvePrompt(approved: false)
            }
            let approved = await store.requestApproval(for: prompt)
            approvalTimeout.cancel()
            if pendingApprovalTransferID == offer.transferID {
                pendingApprovalTransferID = nil
            }
            guard approved else {
                await sendResponse(rejectEnvelope(reason: "Transfer canceled on Mac.", offer: offer))
                await MainActor.run { [store] in
                    store.record(HostFileTransferHistoryItem(
                        id: offer.transferID,
                        fileName: sanitizedName,
                        destinationDescription: settingsSnapshot.destinationDescription,
                        savedFileURL: nil,
                        status: .rejected,
                        transferredBytes: 0,
                        totalBytes: offer.fileSize,
                        updatedAt: Date(),
                        detail: "Rejected on Mac"
                    ))
                }
                if scopedDirectory.stopAccessing {
                    scopedDirectory.url.stopAccessingSecurityScopedResource()
                }
                return
            }
        }

        do {
            try FileManager.default.createDirectory(at: scopedDirectory.url, withIntermediateDirectories: true)
            let finalURL = uniqueDestinationURL(
                directory: scopedDirectory.url,
                fileName: sanitizedName
            )
            let tempURL = scopedDirectory.url.appendingPathComponent(".\(offer.transferID.uuidString).partial", isDirectory: false)
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)
            let state = IncomingTransferState(
                offer: offer,
                sanitizedFileName: sanitizedName,
                destinationDirectory: scopedDirectory,
                finalURL: finalURL,
                tempURL: tempURL,
                fileHandle: handle,
                bytesReceived: 0,
                expectedChunkIndex: 0,
                hasher: SHA256(),
                lastActivityAt: Date(),
                timeoutTask: nil
            )
            activeTransfers[offer.transferID] = state
            recordSeenTransferID(offer.transferID)
            resetTimeout(for: offer.transferID, sendResponse: sendResponse)

            await MainActor.run { [store] in
                store.updateActiveTransfer(HostFileTransferHistoryItem(
                    id: offer.transferID,
                    fileName: sanitizedName,
                    destinationDescription: settingsSnapshot.destinationDescription,
                    savedFileURL: nil,
                    status: .pending,
                    transferredBytes: 0,
                    totalBytes: offer.fileSize,
                    updatedAt: Date(),
                    detail: "Waiting for file data"
                ))
            }

            let accept = FileTransferAcceptMessage(
                transferID: offer.transferID,
                sessionID: offer.sessionID,
                senderDeviceID: offer.senderDeviceID,
                fileName: offer.fileName,
                sanitizedFileName: sanitizedName,
                fileSize: offer.fileSize,
                checksum: offer.checksum,
                createdAt: Date(),
                destinationDescription: settingsSnapshot.destinationDescription,
                maxChunkSize: configuration.maxChunkSizeBytes
            )
            await sendResponse(envelope(for: FileTransferMessage.accept(accept), sessionID: offer.sessionID))
        } catch {
            if scopedDirectory.stopAccessing {
                scopedDirectory.url.stopAccessingSecurityScopedResource()
            }
            await sendResponse(errorEnvelope(
                code: "destination_unavailable",
                message: "Could not prepare the transfer folder on this Mac.",
                offer: offer
            ))
        }
    }

    private func handleChunk(
        _ chunk: FileTransferChunkMessage,
        sendResponse: @escaping @Sendable (TransportWebRTC.DataChannelEnvelope) async -> Void
    ) async {
        guard var state = activeTransfers[chunk.transferID] else {
            await sendResponse(errorEnvelope(
                code: "unknown_transfer",
                message: "Transfer is no longer active.",
                transferID: chunk.transferID,
                sessionID: chunk.sessionID,
                senderDeviceID: chunk.senderDeviceID,
                fileName: chunk.fileName,
                sanitizedFileName: chunk.sanitizedFileName,
                fileSize: chunk.fileSize,
                checksum: chunk.checksum
            ))
            return
        }

        guard validateFreshness(of: state) else {
            await failTransfer(
                id: chunk.transferID,
                offer: state.offer,
                reason: "Connection lost during transfer.",
                code: "transfer_timeout",
                sendResponse: sendResponse
            )
            return
        }
        guard chunk.sessionID == state.offer.sessionID,
              chunk.senderDeviceID == state.offer.senderDeviceID else {
            await failTransfer(
                id: chunk.transferID,
                offer: state.offer,
                reason: "Transfer metadata did not match the approved request.",
                code: "metadata_mismatch",
                sendResponse: sendResponse
            )
            return
        }
        guard chunk.fileSize == state.offer.fileSize,
              chunk.totalChunks == state.offer.totalChunks,
              chunk.checksum == state.offer.checksum else {
            await failTransfer(
                id: chunk.transferID,
                offer: state.offer,
                reason: "Transfer metadata changed during upload.",
                code: "metadata_mismatch",
                sendResponse: sendResponse
            )
            return
        }
        guard chunk.data.count <= configuration.maxChunkSizeBytes else {
            await failTransfer(
                id: chunk.transferID,
                offer: state.offer,
                reason: "Transfer chunk was too large.",
                code: "chunk_too_large",
                sendResponse: sendResponse
            )
            return
        }
        guard chunk.chunkIndex == state.expectedChunkIndex else {
            await failTransfer(
                id: chunk.transferID,
                offer: state.offer,
                reason: "Transfer chunks arrived out of order.",
                code: "unexpected_chunk",
                sendResponse: sendResponse
            )
            return
        }
        guard chunk.byteOffset == state.bytesReceived else {
            await failTransfer(
                id: chunk.transferID,
                offer: state.offer,
                reason: "Transfer byte offset did not match.",
                code: "offset_mismatch",
                sendResponse: sendResponse
            )
            return
        }
        guard state.bytesReceived + Int64(chunk.data.count) <= state.offer.fileSize else {
            await failTransfer(
                id: chunk.transferID,
                offer: state.offer,
                reason: "Transfer exceeded the approved file size.",
                code: "size_overflow",
                sendResponse: sendResponse
            )
            return
        }

        let chunkChecksum = SHA256.hash(data: chunk.data).hexString
        guard chunkChecksum == chunk.chunkChecksum else {
            await failTransfer(
                id: chunk.transferID,
                offer: state.offer,
                reason: "Transfer checksum validation failed.",
                code: "bad_chunk_checksum",
                sendResponse: sendResponse
            )
            return
        }

        do {
            try state.fileHandle.write(contentsOf: chunk.data)
            state.hasher.update(data: chunk.data)
            state.bytesReceived += Int64(chunk.data.count)
            state.expectedChunkIndex += 1
            state.lastActivityAt = Date()
            activeTransfers[chunk.transferID] = state
            resetTimeout(for: chunk.transferID, sendResponse: sendResponse)

            let fileName = state.sanitizedFileName
            let destinationPath = Self.destinationDisplayName(for: state)
            let bytesReceived = state.bytesReceived
            let totalBytes = state.offer.fileSize
            await MainActor.run { [store] in
                store.updateActiveTransfer(HostFileTransferHistoryItem(
                    id: chunk.transferID,
                    fileName: fileName,
                    destinationDescription: destinationPath,
                    savedFileURL: nil,
                    status: .inProgress,
                    transferredBytes: bytesReceived,
                    totalBytes: totalBytes,
                    updatedAt: Date(),
                    detail: nil
                ))
            }

            let progress = FileTransferProgressMessage(
                transferID: chunk.transferID,
                sessionID: chunk.sessionID,
                senderDeviceID: chunk.senderDeviceID,
                fileName: chunk.fileName,
                sanitizedFileName: state.sanitizedFileName,
                fileSize: chunk.fileSize,
                checksum: chunk.checksum,
                createdAt: Date(),
                chunkIndex: chunk.chunkIndex,
                totalChunks: chunk.totalChunks,
                bytesReceived: state.bytesReceived
            )
            await sendResponse(envelope(for: FileTransferMessage.progress(progress), sessionID: chunk.sessionID))
        } catch {
            await failTransfer(
                id: chunk.transferID,
                offer: state.offer,
                reason: "Could not write transfer data on this Mac.",
                code: "write_failed",
                sendResponse: sendResponse
            )
        }
    }

    private func handleComplete(
        _ complete: FileTransferCompleteMessage,
        sendResponse: @escaping @Sendable (TransportWebRTC.DataChannelEnvelope) async -> Void
    ) async {
        guard let state = activeTransfers[complete.transferID] else { return }
        guard validateFreshness(of: state) else {
            await failTransfer(
                id: complete.transferID,
                offer: state.offer,
                reason: "Connection lost during transfer.",
                code: "transfer_timeout",
                sendResponse: sendResponse
            )
            return
        }
        guard complete.sessionID == state.offer.sessionID,
              complete.senderDeviceID == state.offer.senderDeviceID,
              complete.fileSize == state.offer.fileSize,
              complete.totalChunks == state.offer.totalChunks,
              complete.checksum == state.offer.checksum else {
            await failTransfer(
                id: complete.transferID,
                offer: state.offer,
                reason: "Transfer metadata did not match the approved request.",
                code: "metadata_mismatch",
                sendResponse: sendResponse
            )
            return
        }
        guard complete.totalBytes == state.bytesReceived,
              complete.totalBytes == state.offer.fileSize else {
            await failTransfer(
                id: complete.transferID,
                offer: state.offer,
                reason: "Transfer finished with the wrong number of bytes.",
                code: "size_mismatch",
                sendResponse: sendResponse
            )
            return
        }
        guard complete.totalChunks == state.offer.totalChunks else {
            await failTransfer(
                id: complete.transferID,
                offer: state.offer,
                reason: "Transfer finished with the wrong number of chunks.",
                code: "chunk_count_mismatch",
                sendResponse: sendResponse
            )
            return
        }

        let digest = state.hasher.finalize().hexString
        guard digest == state.offer.checksum, digest == complete.checksum else {
            await failTransfer(
                id: complete.transferID,
                offer: state.offer,
                reason: "Transfer checksum validation failed.",
                code: "bad_checksum",
                sendResponse: sendResponse
            )
            return
        }

        do {
            try state.fileHandle.close()
            try FileManager.default.moveItem(at: state.tempURL, to: state.finalURL)
            state.timeoutTask?.cancel()
            activeTransfers[complete.transferID] = nil
            if state.destinationDirectory.stopAccessing {
                state.destinationDirectory.url.stopAccessingSecurityScopedResource()
            }

            let destinationDescription = Self.destinationDisplayName(for: state)
            await MainActor.run { [store] in
                store.record(HostFileTransferHistoryItem(
                    id: complete.transferID,
                    fileName: state.sanitizedFileName,
                    destinationDescription: destinationDescription,
                    savedFileURL: state.finalURL,
                    status: .completed,
                    transferredBytes: state.bytesReceived,
                    totalBytes: state.offer.fileSize,
                    updatedAt: Date(),
                    detail: "Saved on this Mac"
                ))
            }

            let response = FileTransferCompleteMessage(
                transferID: complete.transferID,
                sessionID: complete.sessionID,
                senderDeviceID: complete.senderDeviceID,
                fileName: complete.fileName,
                sanitizedFileName: state.sanitizedFileName,
                fileSize: complete.fileSize,
                checksum: complete.checksum,
                createdAt: Date(),
                totalChunks: complete.totalChunks,
                totalBytes: complete.totalBytes,
                destinationDescription: destinationDescription
            )
            await sendResponse(envelope(for: FileTransferMessage.complete(response), sessionID: complete.sessionID))
        } catch {
            await failTransfer(
                id: complete.transferID,
                offer: state.offer,
                reason: "Could not finalize the transferred file.",
                code: "finalize_failed",
                sendResponse: sendResponse
            )
        }
    }

    private func handleCancel(_ cancel: FileTransferCancelMessage, reason: String) async {
        guard let state = activeTransfers[cancel.transferID] else { return }
        guard cancel.sessionID == state.offer.sessionID,
              cancel.senderDeviceID == state.offer.senderDeviceID,
              cancel.fileSize == state.offer.fileSize else {
            return
        }
        await cleanupTransfer(
            id: cancel.transferID,
            status: .canceled,
            detail: reason,
            sendSavedURL: nil
        )
    }

    private func failTransfer(
        id: UUID,
        offer: FileTransferOfferMessage,
        reason: String,
        code: String,
        sendResponse: @escaping @Sendable (TransportWebRTC.DataChannelEnvelope) async -> Void
    ) async {
        await cleanupTransfer(id: id, status: .failed, detail: reason, sendSavedURL: nil)
        await sendResponse(errorEnvelope(code: code, message: reason, offer: offer))
    }

    private func cleanupTransfer(
        id: UUID,
        status: HostFileTransferHistoryStatus,
        detail: String,
        sendSavedURL: URL?
    ) async {
        guard let state = activeTransfers.removeValue(forKey: id) else { return }
        state.timeoutTask?.cancel()
        try? state.fileHandle.close()
        try? FileManager.default.removeItem(at: state.tempURL)
        if state.destinationDirectory.stopAccessing {
            state.destinationDirectory.url.stopAccessingSecurityScopedResource()
        }
        await MainActor.run { [store] in
            store.record(HostFileTransferHistoryItem(
                id: id,
                fileName: state.sanitizedFileName,
                destinationDescription: Self.destinationDisplayName(for: state),
                savedFileURL: sendSavedURL,
                status: status,
                transferredBytes: state.bytesReceived,
                totalBytes: state.offer.fileSize,
                updatedAt: Date(),
                detail: detail
            ))
        }
    }

    private func validateFreshness(of state: IncomingTransferState) -> Bool {
        Date().timeIntervalSince(state.lastActivityAt) <= configuration.chunkTimeoutSeconds
    }

    private func resetTimeout(
        for transferID: UUID,
        sendResponse: @escaping @Sendable (TransportWebRTC.DataChannelEnvelope) async -> Void
    ) {
        guard var state = activeTransfers[transferID] else { return }
        state.timeoutTask?.cancel()
        let offer = state.offer
        let timeoutNanoseconds = UInt64(self.configuration.chunkTimeoutSeconds * 1_000_000_000)
        state.timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard let self else { return }
            // The transfer may have completed (and been removed) while this task was scheduled to
            // run. Skip the failure path if so — avoids a redundant cleanup + duplicate error response.
            guard await self.isTransferActive(transferID) else { return }
            await self.failTransfer(
                id: transferID,
                offer: offer,
                reason: "Connection lost during transfer.",
                code: "transfer_timeout",
                sendResponse: sendResponse
            )
        }
        activeTransfers[transferID] = state
    }

    private func isTransferActive(_ id: UUID) -> Bool {
        activeTransfers[id] != nil
    }

    private func envelope(for message: FileTransferMessage, sessionID: UUID) -> TransportWebRTC.DataChannelEnvelope {
        (try? TransportWebRTC.DataChannelEnvelope.fileTransfer(message, sessionID: sessionID))
            ?? TransportWebRTC.DataChannelEnvelope(kind: .error, sessionID: sessionID, payload: Data())
    }

    private func rejectEnvelope(reason: String, offer: FileTransferOfferMessage) -> TransportWebRTC.DataChannelEnvelope {
        let reject = FileTransferRejectMessage(
            transferID: offer.transferID,
            sessionID: offer.sessionID,
            senderDeviceID: offer.senderDeviceID,
            fileName: offer.fileName,
            sanitizedFileName: offer.sanitizedFileName,
            fileSize: offer.fileSize,
            checksum: offer.checksum,
            createdAt: Date(),
            reason: reason
        )
        return envelope(for: FileTransferMessage.reject(reject), sessionID: offer.sessionID)
    }

    private func errorEnvelope(code: String, message: String, offer: FileTransferOfferMessage) -> TransportWebRTC.DataChannelEnvelope {
        errorEnvelope(
            code: code,
            message: message,
            transferID: offer.transferID,
            sessionID: offer.sessionID,
            senderDeviceID: offer.senderDeviceID,
            fileName: offer.fileName,
            sanitizedFileName: offer.sanitizedFileName,
            fileSize: offer.fileSize,
            checksum: offer.checksum
        )
    }

    private func errorEnvelope(
        code: String,
        message: String,
        transferID: UUID,
        sessionID: UUID,
        senderDeviceID: UUID,
        fileName: String,
        sanitizedFileName: String,
        fileSize: Int64,
        checksum: String
    ) -> TransportWebRTC.DataChannelEnvelope {
        let error = FileTransferErrorMessage(
            transferID: transferID,
            sessionID: sessionID,
            senderDeviceID: senderDeviceID,
            fileName: fileName,
            sanitizedFileName: sanitizedFileName,
            fileSize: fileSize,
            checksum: checksum,
            createdAt: Date(),
            errorCode: code,
            message: message
        )
        return envelope(for: FileTransferMessage.error(error), sessionID: sessionID)
    }

    private func uniqueDestinationURL(directory: URL, fileName: String) -> URL {
        let baseURL = directory.appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return baseURL }

        let stem = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension
        var counter = 2
        while counter <= 9999 {
            let candidateName = ext.isEmpty
                ? "\(stem) \(counter)"
                : "\(stem) \(counter).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
        let unique = UUID().uuidString
        let fallbackName = ext.isEmpty ? "\(stem) \(unique)" : "\(stem) \(unique).\(ext)"
        return directory.appendingPathComponent(fallbackName, isDirectory: false)
    }

    private func sanitizeFileName(_ fileName: String) -> String {
        FileTransferSanitizer.sanitizeFileName(fileName)
    }

    private static func destinationDisplayName(for state: IncomingTransferState) -> String {
        if state.destinationDirectory.url.lastPathComponent == "Vamp Host Transfers",
           state.destinationDirectory.url.path.contains("/Downloads/") {
            return "Downloads/Vamp Host Transfers"
        }

        let finalDirectory = state.finalURL.deletingLastPathComponent()
        let folderName = finalDirectory.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if folderName.isEmpty {
            return "Chosen transfer folder"
        }
        return folderName
    }

    private func recordSeenTransferID(_ id: UUID) {
        seenTransferIDs.insert(id)
        seenTransferIDQueue.append(id)
        if seenTransferIDQueue.count > maxSeenTransferIDs {
            let oldest = seenTransferIDQueue.removeFirst()
            seenTransferIDs.remove(oldest)
        }
    }
}

private extension Digest {
    var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}
