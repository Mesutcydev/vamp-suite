#if os(macOS)
@preconcurrency import AVFoundation
import CaptureEngine
@preconcurrency import CoreMedia
import Foundation
import SharedProtocol
import TransportWebRTC

/// Receives raw Float32 PCM audio from ScreenCaptureKit, encodes it to AAC-LC,
/// and ships it as AudioFrameMessage over the data channel.
/// Activated only when the negotiated session declares supportsAudio.
actor HostAudioCapturePipeline: @preconcurrency CaptureAudioReceiver {

    private var sessionID: UUID?
    private var sendEnvelope: ((DataChannelEnvelope) throws -> Void)?
    private var frameCounter: UInt64 = 0
    private var sessionStartTime: TimeInterval = 0

    private var encoder: AVAudioConverter?
    private var encoderInputFormat: AVAudioFormat?

    // Opus is preferred when the client negotiated it (lower latency than AAC); the
    // pipeline still falls back to AAC per-stream if the rate/channels aren't Opus-compatible.
    private var preferOpus = false
    private var opusEncoder: OpusAudioEncoder?
    private var opusFormatKey = ""

    // MARK: - Session lifecycle

    func activate(sessionID: UUID, preferOpus: Bool, send: @escaping (DataChannelEnvelope) throws -> Void) {
        self.sessionID = sessionID
        self.sendEnvelope = send
        self.frameCounter = 0
        self.sessionStartTime = CACurrentMediaTime()
        self.preferOpus = preferOpus
        encoder = nil
        encoderInputFormat = nil
        opusEncoder = nil
        opusFormatKey = ""
    }

    func deactivate() {
        sessionID = nil
        sendEnvelope = nil
        encoder = nil
        encoderInputFormat = nil
        opusEncoder = nil
        opusFormatKey = ""
    }

    // MARK: - CaptureAudioReceiver

    func didCaptureAudioBuffer(_ sampleBuffer: CMSampleBuffer) async {
        guard let sessionID, let sendEnvelope else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sampleTime = (pts.value == 0 && pts.timescale == 0)
            ? CACurrentMediaTime() - sessionStartTime
            : CMTimeGetSeconds(pts)

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return }

        let sampleRate = Double(asbd.mSampleRate)
        let channelCount = Int(asbd.mChannelsPerFrame)

        // Opus path: one capture buffer may yield zero or more 20 ms packets; each is its
        // own AudioFrameMessage. `encodeToOpus` returns nil only when Opus can't be used
        // for this stream (rate/channels) — then we fall through to AAC.
        if preferOpus, let packets = encodeToOpus(sampleBuffer, sampleRate: sampleRate, channelCount: channelCount) {
            for packet in packets {
                let message = AudioFrameMessage(
                    frameID: frameCounter,
                    sampleTime: sampleTime,
                    audioData: packet,
                    sampleRate: sampleRate,
                    channelCount: channelCount,
                    codec: "opus"
                )
                frameCounter += 1
                if let envelope = try? DataChannelEnvelope.audioFrame(message, sessionID: sessionID) {
                    try? sendEnvelope(envelope)
                }
            }
            return
        }

        guard let aacData = encodeToAAC(sampleBuffer, sampleRate: sampleRate, channelCount: channelCount) else { return }

        let message = AudioFrameMessage(
            frameID: frameCounter,
            sampleTime: sampleTime,
            audioData: aacData,
            sampleRate: sampleRate,
            channelCount: channelCount,
            codec: "aac"
        )
        frameCounter += 1

        guard let envelope = try? DataChannelEnvelope.audioFrame(message, sessionID: sessionID) else { return }
        try? sendEnvelope(envelope)
    }

    // MARK: - Opus Encoding

    /// Returns Opus packets (possibly empty while buffering a 20 ms frame), or nil if Opus
    /// can't encode this stream's rate/channels — signalling the caller to use AAC.
    private func encodeToOpus(_ sampleBuffer: CMSampleBuffer, sampleRate: Double, channelCount: Int) -> [Data]? {
        let key = "\(sampleRate)_\(channelCount)"
        if opusFormatKey != key {
            opusFormatKey = key
            opusEncoder = OpusAudioEncoder(sampleRate: Int(sampleRate), channelCount: channelCount)
        }
        guard let enc = opusEncoder else { return nil } // unsupported rate/channels → AAC
        guard let interleaved = interleavedPCM(from: sampleBuffer, sampleRate: sampleRate, channelCount: channelCount) else {
            return []
        }
        return enc.encode(interleaved)
    }

    /// Extract the capture buffer as interleaved Float32 PCM (Opus's input layout).
    private func interleavedPCM(from sampleBuffer: CMSampleBuffer, sampleRate: Double, channelCount: Int) -> [Float]? {
        guard sampleRate > 0, channelCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channelCount), interleaved: false) else { return nil }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0,
              let pcm = extractPCMBuffer(from: sampleBuffer, format: format, frameCount: numSamples),
              let channels = pcm.floatChannelData else { return nil }
        let frames = Int(pcm.frameLength)
        var out = [Float](repeating: 0, count: frames * channelCount)
        for f in 0..<frames {
            for c in 0..<channelCount {
                out[f * channelCount + c] = channels[c][f]
            }
        }
        return out
    }

    // MARK: - AAC Encoding

    private func encodeToAAC(_ sampleBuffer: CMSampleBuffer, sampleRate: Double, channelCount: Int) -> Data? {
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        guard sampleRate > 0, channelCount > 0,
              let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
              ) else { return nil }

        if encoder == nil || encoderInputFormat != inputFormat {
            guard let newEncoder = makeAACEncoder(from: inputFormat) else { return nil }
            encoder = newEncoder
            encoderInputFormat = inputFormat
        }
        guard let enc = encoder else { return nil }

        guard let pcmBuffer = extractPCMBuffer(from: sampleBuffer, format: inputFormat, frameCount: numSamples) else { return nil }

        return encodeBuffer(pcmBuffer, using: enc)
    }

    private func makeAACEncoder(from inputFormat: AVAudioFormat) -> AVAudioConverter? {
        let channelCount = Int(inputFormat.channelCount)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: channelCount == 1 ? 64_000 : 128_000,
        ]
        guard let outputFormat = AVAudioFormat(settings: outputSettings) else { return nil }
        return AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    private func extractPCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat, frameCount: Int) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0,
            lengthAtOffsetOut: nil, totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        let channelCount = Int(format.channelCount)
        let float32Samples = totalLength / MemoryLayout<Float32>.size
        guard float32Samples >= frameCount * channelCount else { return nil }

        // SCKit non-interleaved layout: [ch0_0..ch0_N][ch1_0..ch1_N]
        dataPointer.withMemoryRebound(to: Float32.self, capacity: float32Samples) { src in
            guard let floatChannelData = pcmBuffer.floatChannelData else { return }
            for ch in 0..<channelCount {
                floatChannelData[ch].update(from: src.advanced(by: ch * frameCount), count: frameCount)
            }
        }

        return pcmBuffer
    }

    private func encodeBuffer(_ pcmBuffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> Data? {
        let maxPacketSize = converter.maximumOutputPacketSize
        guard maxPacketSize > 0 else { return nil }
        let outputBuffer = AVAudioCompressedBuffer(
            format: converter.outputFormat,
            packetCapacity: 1,
            maximumPacketSize: maxPacketSize
        )

        var inputConsumed = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
            if inputConsumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            inputStatus.pointee = .haveData
            return pcmBuffer
        }

        guard status != .error, outputBuffer.byteLength > 0 else { return nil }
        return Data(bytes: outputBuffer.data, count: Int(outputBuffer.byteLength))
    }
}
#endif
