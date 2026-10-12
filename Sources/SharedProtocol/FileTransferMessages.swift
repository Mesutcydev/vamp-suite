import Foundation

public enum FileTransferMessageKind: String, Codable, Hashable, Sendable {
    case offer
    case accept
    case reject
    case chunk
    case progress
    case complete
    case cancel
    case error
}

public struct FileTransferOfferMessage: Codable, Hashable, Sendable {
    public var transferID: UUID
    public var sessionID: UUID
    public var senderDeviceID: UUID
    public var fileName: String
    public var sanitizedFileName: String
    public var fileSize: Int64
    public var mimeType: String?
    public var uniformTypeIdentifier: String?
    public var checksum: String
    public var createdAt: Date
    public var totalChunks: Int

    public init(
        transferID: UUID,
        sessionID: UUID,
        senderDeviceID: UUID,
        fileName: String,
        sanitizedFileName: String,
        fileSize: Int64,
        mimeType: String?,
        uniformTypeIdentifier: String?,
        checksum: String,
        createdAt: Date = Date(),
        totalChunks: Int
    ) {
        self.transferID = transferID
        self.sessionID = sessionID
        self.senderDeviceID = senderDeviceID
        self.fileName = fileName
        self.sanitizedFileName = sanitizedFileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.checksum = checksum
        self.createdAt = createdAt
        self.totalChunks = totalChunks
    }
}

public struct FileTransferAcceptMessage: Codable, Hashable, Sendable {
    public var transferID: UUID
    public var sessionID: UUID
    public var senderDeviceID: UUID
    public var fileName: String
    public var sanitizedFileName: String
    public var fileSize: Int64
    public var checksum: String
    public var createdAt: Date
    public var destinationDescription: String
    public var maxChunkSize: Int

    public init(
        transferID: UUID,
        sessionID: UUID,
        senderDeviceID: UUID,
        fileName: String,
        sanitizedFileName: String,
        fileSize: Int64,
        checksum: String,
        createdAt: Date = Date(),
        destinationDescription: String,
        maxChunkSize: Int
    ) {
        self.transferID = transferID
        self.sessionID = sessionID
        self.senderDeviceID = senderDeviceID
        self.fileName = fileName
        self.sanitizedFileName = sanitizedFileName
        self.fileSize = fileSize
        self.checksum = checksum
        self.createdAt = createdAt
        self.destinationDescription = destinationDescription
        self.maxChunkSize = maxChunkSize
    }
}

public struct FileTransferRejectMessage: Codable, Hashable, Sendable {
    public var transferID: UUID
    public var sessionID: UUID
    public var senderDeviceID: UUID
    public var fileName: String
    public var sanitizedFileName: String
    public var fileSize: Int64
    public var checksum: String
    public var createdAt: Date
    public var reason: String

    public init(
        transferID: UUID,
        sessionID: UUID,
        senderDeviceID: UUID,
        fileName: String,
        sanitizedFileName: String,
        fileSize: Int64,
        checksum: String,
        createdAt: Date = Date(),
        reason: String
    ) {
        self.transferID = transferID
        self.sessionID = sessionID
        self.senderDeviceID = senderDeviceID
        self.fileName = fileName
        self.sanitizedFileName = sanitizedFileName
        self.fileSize = fileSize
        self.checksum = checksum
        self.createdAt = createdAt
        self.reason = reason
    }
}

public struct FileTransferChunkMessage: Codable, Hashable, Sendable {
    public var transferID: UUID
    public var sessionID: UUID
    public var senderDeviceID: UUID
    public var fileName: String
    public var sanitizedFileName: String
    public var fileSize: Int64
    public var checksum: String
    public var createdAt: Date
    public var chunkIndex: Int
    public var totalChunks: Int
    public var byteOffset: Int64
    public var chunkChecksum: String
    public var data: Data

    public init(
        transferID: UUID,
        sessionID: UUID,
        senderDeviceID: UUID,
        fileName: String,
        sanitizedFileName: String,
        fileSize: Int64,
        checksum: String,
        createdAt: Date = Date(),
        chunkIndex: Int,
        totalChunks: Int,
        byteOffset: Int64,
        chunkChecksum: String,
        data: Data
    ) {
        self.transferID = transferID
        self.sessionID = sessionID
        self.senderDeviceID = senderDeviceID
        self.fileName = fileName
        self.sanitizedFileName = sanitizedFileName
        self.fileSize = fileSize
        self.checksum = checksum
        self.createdAt = createdAt
        self.chunkIndex = chunkIndex
        self.totalChunks = totalChunks
        self.byteOffset = byteOffset
        self.chunkChecksum = chunkChecksum
        self.data = data
    }
}

public struct FileTransferProgressMessage: Codable, Hashable, Sendable {
    public var transferID: UUID
    public var sessionID: UUID
    public var senderDeviceID: UUID
    public var fileName: String
    public var sanitizedFileName: String
    public var fileSize: Int64
    public var checksum: String
    public var createdAt: Date
    public var chunkIndex: Int
    public var totalChunks: Int
    public var bytesReceived: Int64

    public init(
        transferID: UUID,
        sessionID: UUID,
        senderDeviceID: UUID,
        fileName: String,
        sanitizedFileName: String,
        fileSize: Int64,
        checksum: String,
        createdAt: Date = Date(),
        chunkIndex: Int,
        totalChunks: Int,
        bytesReceived: Int64
    ) {
        self.transferID = transferID
        self.sessionID = sessionID
        self.senderDeviceID = senderDeviceID
        self.fileName = fileName
        self.sanitizedFileName = sanitizedFileName
        self.fileSize = fileSize
        self.checksum = checksum
        self.createdAt = createdAt
        self.chunkIndex = chunkIndex
        self.totalChunks = totalChunks
        self.bytesReceived = bytesReceived
    }
}

public struct FileTransferCompleteMessage: Codable, Hashable, Sendable {
    public var transferID: UUID
    public var sessionID: UUID
    public var senderDeviceID: UUID
    public var fileName: String
    public var sanitizedFileName: String
    public var fileSize: Int64
    public var checksum: String
    public var createdAt: Date
    public var totalChunks: Int
    public var totalBytes: Int64
    public var destinationDescription: String?

    public init(
        transferID: UUID,
        sessionID: UUID,
        senderDeviceID: UUID,
        fileName: String,
        sanitizedFileName: String,
        fileSize: Int64,
        checksum: String,
        createdAt: Date = Date(),
        totalChunks: Int,
        totalBytes: Int64,
        destinationDescription: String? = nil
    ) {
        self.transferID = transferID
        self.sessionID = sessionID
        self.senderDeviceID = senderDeviceID
        self.fileName = fileName
        self.sanitizedFileName = sanitizedFileName
        self.fileSize = fileSize
        self.checksum = checksum
        self.createdAt = createdAt
        self.totalChunks = totalChunks
        self.totalBytes = totalBytes
        self.destinationDescription = destinationDescription
    }
}

public struct FileTransferCancelMessage: Codable, Hashable, Sendable {
    public var transferID: UUID
    public var sessionID: UUID
    public var senderDeviceID: UUID
    public var fileName: String
    public var sanitizedFileName: String
    public var fileSize: Int64
    public var checksum: String
    public var createdAt: Date
    public var reason: String

    public init(
        transferID: UUID,
        sessionID: UUID,
        senderDeviceID: UUID,
        fileName: String,
        sanitizedFileName: String,
        fileSize: Int64,
        checksum: String,
        createdAt: Date = Date(),
        reason: String
    ) {
        self.transferID = transferID
        self.sessionID = sessionID
        self.senderDeviceID = senderDeviceID
        self.fileName = fileName
        self.sanitizedFileName = sanitizedFileName
        self.fileSize = fileSize
        self.checksum = checksum
        self.createdAt = createdAt
        self.reason = reason
    }
}

public struct FileTransferErrorMessage: Codable, Hashable, Sendable {
    public var transferID: UUID
    public var sessionID: UUID
    public var senderDeviceID: UUID
    public var fileName: String
    public var sanitizedFileName: String
    public var fileSize: Int64
    public var checksum: String
    public var createdAt: Date
    public var errorCode: String
    public var message: String

    public init(
        transferID: UUID,
        sessionID: UUID,
        senderDeviceID: UUID,
        fileName: String,
        sanitizedFileName: String,
        fileSize: Int64,
        checksum: String,
        createdAt: Date = Date(),
        errorCode: String,
        message: String
    ) {
        self.transferID = transferID
        self.sessionID = sessionID
        self.senderDeviceID = senderDeviceID
        self.fileName = fileName
        self.sanitizedFileName = sanitizedFileName
        self.fileSize = fileSize
        self.checksum = checksum
        self.createdAt = createdAt
        self.errorCode = errorCode
        self.message = message
    }
}

public enum FileTransferMessage: Codable, Hashable, Sendable {
    case offer(FileTransferOfferMessage)
    case accept(FileTransferAcceptMessage)
    case reject(FileTransferRejectMessage)
    case chunk(FileTransferChunkMessage)
    case progress(FileTransferProgressMessage)
    case complete(FileTransferCompleteMessage)
    case cancel(FileTransferCancelMessage)
    case error(FileTransferErrorMessage)

    private enum CodingKeys: String, CodingKey {
        case kind
        case offer
        case accept
        case reject
        case chunk
        case progress
        case complete
        case cancel
        case error
    }

    public var kind: FileTransferMessageKind {
        switch self {
        case .offer: return .offer
        case .accept: return .accept
        case .reject: return .reject
        case .chunk: return .chunk
        case .progress: return .progress
        case .complete: return .complete
        case .cancel: return .cancel
        case .error: return .error
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(FileTransferMessageKind.self, forKey: .kind) {
        case .offer:
            self = .offer(try container.decode(FileTransferOfferMessage.self, forKey: .offer))
        case .accept:
            self = .accept(try container.decode(FileTransferAcceptMessage.self, forKey: .accept))
        case .reject:
            self = .reject(try container.decode(FileTransferRejectMessage.self, forKey: .reject))
        case .chunk:
            self = .chunk(try container.decode(FileTransferChunkMessage.self, forKey: .chunk))
        case .progress:
            self = .progress(try container.decode(FileTransferProgressMessage.self, forKey: .progress))
        case .complete:
            self = .complete(try container.decode(FileTransferCompleteMessage.self, forKey: .complete))
        case .cancel:
            self = .cancel(try container.decode(FileTransferCancelMessage.self, forKey: .cancel))
        case .error:
            self = .error(try container.decode(FileTransferErrorMessage.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .offer(let value):
            try container.encode(value, forKey: .offer)
        case .accept(let value):
            try container.encode(value, forKey: .accept)
        case .reject(let value):
            try container.encode(value, forKey: .reject)
        case .chunk(let value):
            try container.encode(value, forKey: .chunk)
        case .progress(let value):
            try container.encode(value, forKey: .progress)
        case .complete(let value):
            try container.encode(value, forKey: .complete)
        case .cancel(let value):
            try container.encode(value, forKey: .cancel)
        case .error(let value):
            try container.encode(value, forKey: .error)
        }
    }
}
