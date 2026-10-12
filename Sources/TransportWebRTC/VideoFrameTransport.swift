import Foundation
import SharedModels

// MARK: - Video Frame Data

/// Encoded video frame ready for transport over WebRTC.
/// Uses a compact binary encoding for efficient data channel transmission.
public struct VideoFrameData: Sendable, Hashable {
    public var codec: VideoCodec
    public var data: Data
    public var isKeyframe: Bool
    public var presentationTimestamp: Double
    public var width: Int
    public var height: Int
    public var sequenceNumber: UInt64
    /// Annex-B parameter sets (SPS/PPS for H.264, VPS/SPS/PPS for HEVC).
    /// Present on keyframes so the remote decoder can (re-)initialize.
    public var parameterSets: Data?
    public var dynamicRange: StreamDynamicRange
    /// Which host display this frame belongs to (0 = primary). Lets multiple displays
    /// share the one video channel; the client demuxes by this into per-display surfaces.
    /// Rides a previously-reserved header byte, so old peers (single-display) read 0.
    public var displayID: UInt8

    public enum VideoCodec: UInt8, Codable, Hashable, Sendable {
        case h264 = 0
        case hevc = 1
    }

    public init(
        codec: VideoCodec,
        data: Data,
        isKeyframe: Bool,
        presentationTimestamp: Double,
        width: Int,
        height: Int,
        sequenceNumber: UInt64,
        parameterSets: Data? = nil,
        dynamicRange: StreamDynamicRange = .sdr,
        displayID: UInt8 = 0
    ) {
        self.codec = codec
        self.data = data
        self.isKeyframe = isKeyframe
        self.presentationTimestamp = presentationTimestamp
        self.width = width
        self.height = height
        self.sequenceNumber = sequenceNumber
        self.parameterSets = parameterSets
        self.dynamicRange = dynamicRange
        self.displayID = displayID
    }
}

// MARK: - Binary Wire Format

extension VideoFrameData {
    public enum DecodeError: Error, LocalizedError, Sendable {
        case dataTooShort
        case invalidMagic
        case unsupportedVersion
        case invalidCodec
        case invalidDimensions

        public var errorDescription: String? {
            switch self {
            case .dataTooShort: return "Video frame data too short for header."
            case .invalidMagic: return "Invalid video frame magic bytes."
            case .unsupportedVersion: return "Unsupported video frame version."
            case .invalidCodec: return "Invalid video codec identifier."
            case .invalidDimensions: return "Video frame has invalid width or height."
            }
        }
    }

    /// Binary header layout (version 2/3, 34 bytes + paramSets, big-endian):
    /// ```
    /// [0..1]   magic: 0x5646 ('V' 'F')
    /// [2]      version: 2
    /// [3]      codec: 0=h264, 1=hevc
    /// [4]      flags: bit0=keyframe
    /// [5]      color profile (v3: 0=SDR, 1=HDR10/HLG)
    /// [6]      displayID (0=primary; for multi-display demux)
    /// [7]      reserved
    /// [8..15]  sequenceNumber: UInt64
    /// [16..23] presentationTimestamp: Float64
    /// [24..27] width: UInt32
    /// [28..31] height: UInt32
    /// [32..33] paramSetSize: UInt16
    /// [34..34+paramSetSize) parameterSets
    /// [34+paramSetSize..] payload
    /// ```
    public static let headerSize = 34
    private static let magic: UInt16 = 0x5646

    public func wireEncode() -> Data {
        let psData = parameterSets ?? Data()
        var result = Data(capacity: Self.headerSize + psData.count + data.count)
        appendBigEndian(&result, Self.magic)
        result.append(dynamicRange == .hdr10 ? 3 : 2)
        result.append(codec.rawValue)
        var flags: UInt8 = 0
        if isKeyframe { flags |= 0x01 }
        result.append(flags)
        result.append(dynamicRange == .hdr10 ? 1 : 0)
        result.append(displayID)        // [6]
        result.append(0)                // [7] reserved
        appendBigEndian(&result, sequenceNumber)
        appendBigEndian(&result, presentationTimestamp.bitPattern)
        appendBigEndian(&result, UInt32(width))
        appendBigEndian(&result, UInt32(height))
        appendBigEndian(&result, UInt16(psData.count))
        if !psData.isEmpty { result.append(psData) }
        result.append(data)
        return result
    }

    public static func wireDecode(_ wireData: Data) throws -> VideoFrameData {
        // Minimum header is 32 bytes (v1) or 34 bytes (v2)
        guard wireData.count >= 32 else {
            throw DecodeError.dataTooShort
        }

        let magic: UInt16 = readBigEndian(wireData, offset: 0)
        guard magic == Self.magic else {
            throw DecodeError.invalidMagic
        }

        let version = wireData[wireData.startIndex + 2]
        guard version == 1 || version == 2 || version == 3 else {
            throw DecodeError.unsupportedVersion
        }

        let codecRaw = wireData[wireData.startIndex + 3]
        guard let codec = VideoCodec(rawValue: codecRaw) else {
            throw DecodeError.invalidCodec
        }

        let flags = wireData[wireData.startIndex + 4]
        let isKeyframe = (flags & 0x01) != 0
        let dynamicRange: StreamDynamicRange =
            version >= 3 && wireData[wireData.startIndex + 5] == 1 ? .hdr10 : .sdr
        // displayID rides reserved byte [6] (v2+); legacy v1 has no field → primary.
        let displayID: UInt8 = version >= 2 ? wireData[wireData.startIndex + 6] : 0

        let sequenceNumber: UInt64 = readBigEndian(wireData, offset: 8)
        let ptsBits: UInt64 = readBigEndian(wireData, offset: 16)
        let pts = Double(bitPattern: ptsBits)
        let width: UInt32 = readBigEndian(wireData, offset: 24)
        let height: UInt32 = readBigEndian(wireData, offset: 28)

        // Reject unreasonable dimensions (max 16384 per axis, typical for 8K+).
        guard width > 0, width <= 16384, height > 0, height <= 16384 else {
            throw DecodeError.invalidDimensions
        }

        var paramSets: Data?
        let payloadStart: Int

        if version >= 2 {
            guard wireData.count >= 34 else { throw DecodeError.dataTooShort }
            let psSize: UInt16 = readBigEndian(wireData, offset: 32)
            let psStart = wireData.startIndex + 34
            let psEnd = psStart + Int(psSize)
            guard wireData.count >= 34 + Int(psSize) else { throw DecodeError.dataTooShort }
            if psSize > 0 {
                paramSets = Data(wireData[psStart..<psEnd])
            }
            payloadStart = psEnd
        } else {
            payloadStart = wireData.startIndex + 32
        }

        let payload = wireData.suffix(from: payloadStart)

        return VideoFrameData(
            codec: codec,
            data: Data(payload),
            isKeyframe: isKeyframe,
            presentationTimestamp: pts,
            width: Int(width),
            height: Int(height),
            sequenceNumber: sequenceNumber,
            parameterSets: paramSets,
            dynamicRange: dynamicRange,
            displayID: displayID
        )
    }

    // MARK: - Binary Helpers

    private func appendBigEndian<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func readBigEndian<T: FixedWidthInteger>(_ data: Data, offset: Int) -> T {
        let size = MemoryLayout<T>.size
        let base = data.startIndex + offset
        let slice = data[base ..< base + size]
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            slice.copyBytes(to: dest)
        }
        return T(bigEndian: value)
    }
}

// MARK: - Fragmented Video Packet Format

/// A bounded packet used when an encoded frame is too large for one data-channel
/// message. The payload being fragmented is the complete `VideoFrameData` wire
/// representation, so reassembly feeds the existing decoder unchanged.
struct VideoFrameFragment: Sendable {
    static let headerSize = 24
    static let magic: UInt16 = 0x5647 // "VG"
    static let maxReassembledBytes = 64 * 1024 * 1024
    static let maxFragmentCount = 4_096

    let sequenceNumber: UInt64
    let fragmentIndex: Int
    let fragmentCount: Int
    let totalByteCount: Int
    let payload: Data
    var displayID: UInt8 = 0   // [3], reserved in old peers → 0

    func wireEncode() -> Data {
        var result = Data(capacity: Self.headerSize + payload.count)
        appendBigEndian(&result, Self.magic)
        result.append(1)
        result.append(displayID)
        appendBigEndian(&result, sequenceNumber)
        appendBigEndian(&result, UInt32(fragmentIndex))
        appendBigEndian(&result, UInt32(fragmentCount))
        appendBigEndian(&result, UInt32(totalByteCount))
        result.append(payload)
        return result
    }

    static func wireDecode(_ data: Data) throws -> VideoFrameFragment {
        guard data.count >= headerSize else { throw VideoFrameData.DecodeError.dataTooShort }
        let packetMagic: UInt16 = readBigEndian(data, offset: 0)
        guard packetMagic == magic else { throw VideoFrameData.DecodeError.invalidMagic }
        guard data[data.startIndex + 2] == 1 else {
            throw VideoFrameData.DecodeError.unsupportedVersion
        }
        let displayID = data[data.startIndex + 3]
        let sequence: UInt64 = readBigEndian(data, offset: 4)
        let index = Int(UInt32(bigEndian: readInteger(data, offset: 12)))
        let count = Int(UInt32(bigEndian: readInteger(data, offset: 16)))
        let total = Int(UInt32(bigEndian: readInteger(data, offset: 20)))
        guard count > 0, count <= maxFragmentCount,
              index >= 0, index < count,
              total > 0, total <= maxReassembledBytes else {
            throw VideoFrameData.DecodeError.dataTooShort
        }
        return VideoFrameFragment(
            sequenceNumber: sequence,
            fragmentIndex: index,
            fragmentCount: count,
            totalByteCount: total,
            payload: Data(data.dropFirst(headerSize)),
            displayID: displayID
        )
    }

    private func appendBigEndian<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func readBigEndian<T: FixedWidthInteger>(_ data: Data, offset: Int) -> T {
        let raw: T = readInteger(data, offset: offset)
        return T(bigEndian: raw)
    }

    private static func readInteger<T: FixedWidthInteger>(_ data: Data, offset: Int) -> T {
        let size = MemoryLayout<T>.size
        let base = data.startIndex + offset
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { destination in
            data[base ..< base + size].copyBytes(to: destination)
        }
        return value
    }
}

/// XOR parity packet covering every data fragment of one frame. Lets the receiver
/// rebuild a single lost fragment with no retransmission round-trip — chiefly to
/// rescue large keyframes, whose loss otherwise stalls the whole GOP. Emitted only
/// when the client negotiated `supportsVideoFEC`, so older clients never see it.
///
/// `payload` is `payloadCapacity` (L) bytes: the XOR of all fragment payloads, each
/// zero-padded to L. The last fragment is shorter, but XOR with its implicit zero
/// padding is a no-op, so the receiver can pad-and-XOR the survivors symmetrically.
struct VideoFrameParity: Sendable {
    static let headerSize = 20
    static let magic: UInt16 = 0x5648 // "VH"

    let sequenceNumber: UInt64
    let fragmentCount: Int
    let totalByteCount: Int
    let payload: Data
    var displayID: UInt8 = 0   // [3], matches the fragments it covers

    func wireEncode() -> Data {
        var result = Data(capacity: Self.headerSize + payload.count)
        appendBigEndian(&result, Self.magic)
        result.append(1)
        result.append(displayID)
        appendBigEndian(&result, sequenceNumber)
        appendBigEndian(&result, UInt32(fragmentCount))
        appendBigEndian(&result, UInt32(totalByteCount))
        result.append(payload)
        return result
    }

    static func wireDecode(_ data: Data) throws -> VideoFrameParity {
        guard data.count >= headerSize else { throw VideoFrameData.DecodeError.dataTooShort }
        let packetMagic: UInt16 = readBigEndian(data, offset: 0)
        guard packetMagic == magic else { throw VideoFrameData.DecodeError.invalidMagic }
        guard data[data.startIndex + 2] == 1 else {
            throw VideoFrameData.DecodeError.unsupportedVersion
        }
        let displayID = data[data.startIndex + 3]
        let sequence: UInt64 = readBigEndian(data, offset: 4)
        let count = Int(UInt32(bigEndian: readInteger(data, offset: 12)))
        let total = Int(UInt32(bigEndian: readInteger(data, offset: 16)))
        guard count > 1, count <= VideoFrameFragment.maxFragmentCount,
              total > 0, total <= VideoFrameFragment.maxReassembledBytes else {
            throw VideoFrameData.DecodeError.dataTooShort
        }
        return VideoFrameParity(
            sequenceNumber: sequence,
            fragmentCount: count,
            totalByteCount: total,
            payload: Data(data.dropFirst(headerSize)),
            displayID: displayID
        )
    }

    private func appendBigEndian<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func readBigEndian<T: FixedWidthInteger>(_ data: Data, offset: Int) -> T {
        T(bigEndian: readInteger(data, offset: offset))
    }

    private static func readInteger<T: FixedWidthInteger>(_ data: Data, offset: Int) -> T {
        let size = MemoryLayout<T>.size
        let base = data.startIndex + offset
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { destination in
            data[base ..< base + size].copyBytes(to: destination)
        }
        return value
    }
}

extension VideoFrameData {
    /// Produces either the legacy whole-frame packet or bounded fragment packets.
    /// When `fec` is set and the frame spans more than one fragment, a trailing XOR
    /// parity packet is appended so the receiver can recover one lost fragment.
    func wirePackets(maxPacketBytes: Int, fec: Bool = false) -> [Data] {
        let wire = wireEncode()
        guard maxPacketBytes > VideoFrameFragment.headerSize,
              wire.count > maxPacketBytes else {
            return [wire]
        }

        let payloadCapacity = maxPacketBytes - VideoFrameFragment.headerSize
        let fragmentCount = Int(ceil(Double(wire.count) / Double(payloadCapacity)))
        guard fragmentCount <= VideoFrameFragment.maxFragmentCount else { return [] }

        var packets: [Data] = []
        packets.reserveCapacity(fragmentCount + 1)
        // Accumulate XOR parity over zero-padded fragment payloads as we go.
        var parity = (fec && fragmentCount > 1) ? [UInt8](repeating: 0, count: payloadCapacity) : []

        for index in 0..<fragmentCount {
            let lower = index * payloadCapacity
            let upper = min(lower + payloadCapacity, wire.count)
            let chunk = Data(wire[lower..<upper])
            packets.append(VideoFrameFragment(
                sequenceNumber: sequenceNumber,
                fragmentIndex: index,
                fragmentCount: fragmentCount,
                totalByteCount: wire.count,
                payload: chunk,
                displayID: displayID
            ).wireEncode())
            if !parity.isEmpty {
                for (j, byte) in chunk.enumerated() { parity[j] ^= byte }
            }
        }

        if !parity.isEmpty {
            packets.append(VideoFrameParity(
                sequenceNumber: sequenceNumber,
                fragmentCount: fragmentCount,
                totalByteCount: wire.count,
                payload: Data(parity),
                displayID: displayID
            ).wireEncode())
        }
        return packets
    }
}

final class VideoFrameReassembler {
    private struct Assembly {
        var createdAt: Date
        var totalByteCount: Int
        var fragments: [Data?]
        var receivedByteCount: Int
        var parity: Data?
    }

    // Keyed by (displayID, sequenceNumber): each display has its own sequence counter, so
    // two displays' in-flight frames must not share an assembly slot.
    private struct AssemblyKey: Hashable { let displayID: UInt8; let seq: UInt64 }
    private var assemblies: [AssemblyKey: Assembly] = [:]
    // Bound untrusted sizing: a malformed packet must not trigger a huge allocation
    // (`Array(repeating:count:)`) or an out-of-range fragment index (crash).
    private static let maxFragmentCount = 8192
    private static let maxBytes = 64 * 1024 * 1024

    func ingest(_ packet: Data) throws -> VideoFrameData? {
        guard packet.count >= 2 else { throw VideoFrameData.DecodeError.dataTooShort }
        let magic = (UInt16(packet[packet.startIndex]) << 8)
            | UInt16(packet[packet.startIndex + 1])
        if magic == 0x5646 {
            return try VideoFrameData.wireDecode(packet)
        }
        if magic == VideoFrameParity.magic {
            return try ingestParity(VideoFrameParity.wireDecode(packet))
        }
        return try ingestFragment(VideoFrameFragment.wireDecode(packet))
    }

    private func ingestFragment(_ fragment: VideoFrameFragment) throws -> VideoFrameData? {
        guard fragment.fragmentCount > 0, fragment.fragmentCount <= Self.maxFragmentCount,
              fragment.totalByteCount > 0, fragment.totalByteCount <= Self.maxBytes,
              fragment.fragmentIndex >= 0, fragment.fragmentIndex < fragment.fragmentCount else {
            throw VideoFrameData.DecodeError.dataTooShort
        }
        evictExpired()
        let key = AssemblyKey(displayID: fragment.displayID, seq: fragment.sequenceNumber)
        var assembly = try assembly(for: key,
                                    totalByteCount: fragment.totalByteCount,
                                    fragmentCount: fragment.fragmentCount)
        if assembly.fragments[fragment.fragmentIndex] == nil {
            assembly.fragments[fragment.fragmentIndex] = fragment.payload
            assembly.receivedByteCount += fragment.payload.count
        }
        return try finalize(assembly, key: key)
    }

    private func ingestParity(_ parity: VideoFrameParity) throws -> VideoFrameData? {
        guard parity.fragmentCount > 1, parity.fragmentCount <= Self.maxFragmentCount,
              parity.totalByteCount > 0, parity.totalByteCount <= Self.maxBytes,
              !parity.payload.isEmpty, parity.payload.count <= Self.maxBytes else {
            throw VideoFrameData.DecodeError.dataTooShort
        }
        evictExpired()
        let key = AssemblyKey(displayID: parity.displayID, seq: parity.sequenceNumber)
        var assembly = try assembly(for: key,
                                    totalByteCount: parity.totalByteCount,
                                    fragmentCount: parity.fragmentCount)
        if assembly.parity == nil { assembly.parity = parity.payload }
        return try finalize(assembly, key: key)
    }

    /// Get-or-create an assembly, rejecting a packet whose sizing disagrees with one
    /// already in flight for that (display, sequence).
    private func assembly(for key: AssemblyKey, totalByteCount: Int, fragmentCount: Int) throws -> Assembly {
        let existing = assemblies[key] ?? Assembly(
            createdAt: Date(),
            totalByteCount: totalByteCount,
            fragments: Array(repeating: nil, count: fragmentCount),
            receivedByteCount: 0,
            parity: nil
        )
        guard existing.totalByteCount == totalByteCount,
              existing.fragments.count == fragmentCount else {
            assemblies.removeValue(forKey: key)
            throw VideoFrameData.DecodeError.dataTooShort
        }
        return existing
    }

    /// Attempt FEC recovery, then either complete the frame or store progress.
    private func finalize(_ assembly: Assembly, key: AssemblyKey) throws -> VideoFrameData? {
        var assembly = assembly
        reconstructIfPossible(&assembly)

        guard assembly.receivedByteCount <= assembly.totalByteCount else {
            assemblies.removeValue(forKey: key)
            throw VideoFrameData.DecodeError.dataTooShort
        }
        guard assembly.fragments.allSatisfy({ $0 != nil }) else {
            assemblies[key] = assembly
            return nil
        }
        var wire = Data(capacity: assembly.totalByteCount)
        assembly.fragments.forEach { wire.append($0!) }
        assemblies.removeValue(forKey: key)
        guard wire.count == assembly.totalByteCount else {
            throw VideoFrameData.DecodeError.dataTooShort
        }
        return try VideoFrameData.wireDecode(wire)
    }

    /// XOR-recover the one missing fragment from parity, if exactly one is missing and
    /// the parity packet has arrived. `parity.count` is the zero-padded fragment length
    /// (L): every full fragment is L bytes, the last is `total - (count-1)·L`.
    private func reconstructIfPossible(_ assembly: inout Assembly) {
        guard let parity = assembly.parity, !parity.isEmpty else { return }
        let count = assembly.fragments.count
        var missingIndex = -1
        for i in 0..<count where assembly.fragments[i] == nil {
            if missingIndex != -1 { return }   // more than one missing — unrecoverable
            missingIndex = i
        }
        guard missingIndex != -1 else { return }   // nothing missing

        let L = parity.count
        var recovered = [UInt8](parity)
        for i in 0..<count where i != missingIndex {
            guard let frag = assembly.fragments[i] else { return }
            for (j, byte) in frag.enumerated() where j < L { recovered[j] ^= byte }
        }
        let realLen = missingIndex < count - 1
            ? L
            : assembly.totalByteCount - (count - 1) * L
        guard realLen > 0, realLen <= L else { return }
        let recoveredData = Data(recovered.prefix(realLen))
        assembly.fragments[missingIndex] = recoveredData
        assembly.receivedByteCount += recoveredData.count
    }

    private func evictExpired() {
        let cutoff = Date().addingTimeInterval(-2)
        assemblies = assemblies.filter { $0.value.createdAt >= cutoff }
        if assemblies.count > 4 {
            let oldest = assemblies.min { $0.value.createdAt < $1.value.createdAt }?.key
            if let oldest { assemblies.removeValue(forKey: oldest) }
        }
    }
}

// MARK: - Video Receiving State

public enum VideoReceivingState: String, Sendable, Hashable {
    case idle
    case waitingForFirstFrame
    case receiving
    case stalled
}

// MARK: - Stream Diagnostics

public struct StreamDiagnostics: Sendable, Hashable {
    public var framesSent: UInt64
    public var framesReceived: UInt64
    /// Number of keyframes (IDR frames with parameter sets) received by the client.
    /// Zero despite framesReceived > 0 means the decoder is stuck waiting for an I-frame.
    public var keyframesReceived: UInt64
    public var bytesSent: UInt64
    public var bytesReceived: UInt64
    public var firstFrameReceivedAt: Date?
    public var lastFrameReceivedAt: Date?
    public var lastFrameSentAt: Date?
    public var receivingState: VideoReceivingState
    public var restartCount: Int

    public init(
        framesSent: UInt64 = 0,
        framesReceived: UInt64 = 0,
        keyframesReceived: UInt64 = 0,
        bytesSent: UInt64 = 0,
        bytesReceived: UInt64 = 0,
        firstFrameReceivedAt: Date? = nil,
        lastFrameReceivedAt: Date? = nil,
        lastFrameSentAt: Date? = nil,
        receivingState: VideoReceivingState = .idle,
        restartCount: Int = 0
    ) {
        self.framesSent = framesSent
        self.framesReceived = framesReceived
        self.keyframesReceived = keyframesReceived
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.firstFrameReceivedAt = firstFrameReceivedAt
        self.lastFrameReceivedAt = lastFrameReceivedAt
        self.lastFrameSentAt = lastFrameSentAt
        self.receivingState = receivingState
        self.restartCount = restartCount
    }

    /// Returns true if in receiving state but no frame arrived within the threshold.
    public func isStalled(threshold: TimeInterval = 3.0) -> Bool {
        guard receivingState == .receiving, let lastReceived = lastFrameReceivedAt else {
            return false
        }
        return Date().timeIntervalSince(lastReceived) > threshold
    }

    public var summaryText: String {
        var parts: [String] = []
        parts.append("Sent: \(framesSent)")
        parts.append("Recv: \(framesReceived)")
        parts.append("State: \(receivingState.rawValue)")
        if let first = firstFrameReceivedAt {
            parts.append("First: \(first.formatted(date: .omitted, time: .standard))")
        }
        return parts.joined(separator: " · ")
    }
}
