import Copus
import Foundation

/// Thin Swift wrappers over the vendored libopus (Sources/Copus). PCM is interleaved
/// Float32 in [-1, 1]. Opus only accepts 8/12/16/24/48 kHz and fixed frame sizes, so the
/// encoder buffers input into 20 ms frames and emits one packet per frame; callers gate
/// on `OpusAudioCodec.supports(sampleRate:channelCount:)` and fall back to AAC otherwise.
public enum OpusAudioCodec {
    public static let supportedSampleRates: Set<Int> = [8000, 12000, 16000, 24000, 48000]

    public static func supports(sampleRate: Int, channelCount: Int) -> Bool {
        supportedSampleRates.contains(sampleRate) && (1...2).contains(channelCount)
    }
}

public final class OpusAudioEncoder {
    private var encoder: OpaquePointer?
    private let channels: Int
    private let frameSize: Int        // samples per channel per packet (20 ms)
    private var pending: [Float] = [] // interleaved samples not yet emitted

    /// Returns nil for unsupported rate/channel combinations (caller falls back to AAC).
    public init?(sampleRate: Int, channelCount: Int, bitrate: Int = 0) {
        guard OpusAudioCodec.supports(sampleRate: sampleRate, channelCount: channelCount) else { return nil }
        self.channels = channelCount
        self.frameSize = sampleRate / 50
        var err: Int32 = 0
        guard let enc = opus_encoder_create(Int32(sampleRate), Int32(channelCount),
                                            OPUS_APPLICATION_RESTRICTED_LOWDELAY, &err),
              err == OPUS_OK else { return nil }
        encoder = enc
        let target = bitrate > 0 ? bitrate : (channelCount == 1 ? 64_000 : 96_000)
        _ = copus_encoder_set_bitrate(enc, Int32(target))
    }

    deinit { if let encoder { opus_encoder_destroy(encoder) } }

    /// Append interleaved PCM and return zero or more complete Opus packets.
    public func encode(_ pcm: [Float]) -> [Data] {
        guard let encoder else { return [] }
        pending.append(contentsOf: pcm)
        let perFrame = frameSize * channels
        guard perFrame > 0 else { return [] }
        var packets: [Data] = []
        var out = [UInt8](repeating: 0, count: 4000)
        while pending.count >= perFrame {
            let frame = Array(pending[0..<perFrame])
            pending.removeFirst(perFrame)
            let n = frame.withUnsafeBufferPointer { fb in
                out.withUnsafeMutableBufferPointer { ob in
                    opus_encode_float(encoder, fb.baseAddress!, Int32(frameSize),
                                      ob.baseAddress!, Int32(ob.count))
                }
            }
            if n > 0 { packets.append(Data(out[0..<Int(n)])) }
        }
        return packets
    }
}

public final class OpusAudioDecoder {
    private var decoder: OpaquePointer?
    private let channels: Int
    private static let maxFrameSize = 5760 // 120 ms @ 48 kHz — Opus's largest packet

    public init?(sampleRate: Int, channelCount: Int) {
        guard OpusAudioCodec.supports(sampleRate: sampleRate, channelCount: channelCount) else { return nil }
        self.channels = channelCount
        var err: Int32 = 0
        decoder = opus_decoder_create(Int32(sampleRate), Int32(channelCount), &err)
        guard err == OPUS_OK, decoder != nil else { return nil }
    }

    deinit { if let decoder { opus_decoder_destroy(decoder) } }

    /// Decode one Opus packet into interleaved Float32 PCM (nil on error).
    public func decode(_ packet: Data) -> [Float]? {
        guard let decoder, !packet.isEmpty else { return nil }
        var out = [Float](repeating: 0, count: Self.maxFrameSize * channels)
        let n = packet.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            out.withUnsafeMutableBufferPointer { ob in
                opus_decode_float(decoder, raw.bindMemory(to: UInt8.self).baseAddress!,
                                  Int32(packet.count), ob.baseAddress!, Int32(Self.maxFrameSize), 0)
            }
        }
        guard n > 0 else { return nil }
        return Array(out[0..<(Int(n) * channels)])
    }
}
