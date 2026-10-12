@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import SharedProtocol
import SharedUtilities

/// Receives AudioFrameMessage packets from the Mac host, decodes AAC-LC to Float32 PCM,
/// and plays them via AVAudioEngine + AVAudioPlayerNode.
@MainActor
final class ClientAudioRenderer: ObservableObject {

    @Published private(set) var isActive = false
    @Published var isMuted = false

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var lastFrameID: UInt64 = 0

    private var decoder: AVAudioConverter?
    private var decoderKey: String = ""

    private var opusDecoder: OpusAudioDecoder?
    private var opusDecoderKey: String = ""

    private var configurationObserver: NSObjectProtocol?
    private var pendingFormat: AVAudioFormat?

    // MARK: - Lifecycle

    func start() {
        guard !isActive else { return }
        isActive = true
        // Defer engine start off the SwiftUI appearance/layout pass. Starting
        // AVAudioPlayerNode during window ordering (especially right after sleep/wake)
        // can raise an ObjC exception that AppKit turns into a hard crash.
        DispatchQueue.main.async { [weak self] in
            self?.setupEngineIfNeeded()
        }
    }

    func stop() {
        guard isActive else { return }
        tearDownEngine()
        pendingFormat = nil
        decoder = nil
        decoderKey = ""
        opusDecoder = nil
        opusDecoderKey = ""
        lastFrameID = 0
        isActive = false
    }

    // MARK: - Receive

    func receive(_ message: AudioFrameMessage) {
        guard isActive, !isMuted, message.codec == "aac" || message.codec == "opus" else { return }

        if message.frameID + 4 < lastFrameID { return }
        lastFrameID = max(lastFrameID, message.frameID)

        // sampleRate/channelCount come from the remote peer — invalid values make AVAudioFormat
        // return nil; a force-unwrap here would let a malformed audio frame crash the client.
        // Bound to sane audio ranges so a malformed/hostile frame can't request an absurd format.
        guard message.sampleRate >= 8000, message.sampleRate <= 192_000,
              message.channelCount >= 1, message.channelCount <= 8,
              let neededFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: message.sampleRate,
                channels: AVAudioChannelCount(message.channelCount),
                interleaved: false
              ) else { return }

        if playbackFormat != neededFormat || playerNode == nil || engine?.isRunning != true {
            playbackFormat = neededFormat
            rebuildEngine(format: neededFormat)
        }

        guard let playerNode, !message.audioData.isEmpty else { return }

        let pcmBuffer: AVAudioPCMBuffer?
        if message.codec == "opus" {
            pcmBuffer = decodeOpus(message, format: neededFormat)
        } else {
            let key = "\(message.sampleRate)_\(message.channelCount)"
            if decoderKey != key {
                decoderKey = key
                decoder = makeDecoder(sampleRate: message.sampleRate, channelCount: message.channelCount, pcmFormat: neededFormat)
            }
            guard let dec = decoder else { return }
            pcmBuffer = decodeAAC(message.audioData, using: dec)
        }
        guard let buffer = pcmBuffer else { return }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - Opus Decoding

    private func decodeOpus(_ message: AudioFrameMessage, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let key = "\(message.sampleRate)_\(message.channelCount)"
        if opusDecoderKey != key {
            opusDecoderKey = key
            opusDecoder = OpusAudioDecoder(sampleRate: Int(message.sampleRate), channelCount: message.channelCount)
        }
        guard let dec = opusDecoder, let interleaved = dec.decode(message.audioData), !interleaved.isEmpty else { return nil }
        let channels = message.channelCount
        let frames = interleaved.count / channels
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let chans = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        // De-interleave Opus's interleaved output into the non-interleaved playback buffer.
        for f in 0..<frames {
            for c in 0..<channels {
                chans[c][f] = interleaved[f * channels + c]
            }
        }
        return buffer
    }

    // MARK: - AAC Decoding

    private func makeDecoder(sampleRate: Double, channelCount: Int, pcmFormat: AVAudioFormat) -> AVAudioConverter? {
        var aacASBD = AudioStreamBasicDescription()
        aacASBD.mSampleRate = sampleRate
        aacASBD.mFormatID = kAudioFormatMPEG4AAC
        aacASBD.mFormatFlags = 2 // kMPEG4Object_AAC_LC
        aacASBD.mChannelsPerFrame = UInt32(channelCount)
        aacASBD.mFramesPerPacket = 1024
        guard let aacFormat = AVAudioFormat(streamDescription: &aacASBD) else { return nil }
        return AVAudioConverter(from: aacFormat, to: pcmFormat)
    }

    private func decodeAAC(_ data: Data, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let compressedBuffer = AVAudioCompressedBuffer(
            format: converter.inputFormat,
            packetCapacity: 1,
            maximumPacketSize: data.count
        )

        data.copyBytes(to: compressedBuffer.data.assumingMemoryBound(to: UInt8.self), count: data.count)
        compressedBuffer.byteLength = UInt32(data.count)
        compressedBuffer.packetCount = 1
        compressedBuffer.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(data.count)
        )

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: 1024
        ) else { return nil }

        var inputConsumed = false
        var error: NSError?
        let status = converter.convert(to: pcmBuffer, error: &error) { _, inputStatus in
            if inputConsumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            inputStatus.pointee = .haveData
            return compressedBuffer
        }

        guard status != .error, pcmBuffer.frameLength > 0 else { return nil }
        return pcmBuffer
    }

    // MARK: - Engine Setup

    private func setupEngineIfNeeded() {
        guard isActive, engine == nil else { return }
        setupEngine()
    }

    private func setupEngine() {
        guard let defaultFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        ) else { return }
        rebuildEngine(format: defaultFormat)
    }

    private func tearDownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        playbackFormat = nil
    }

    private func rebuildEngine(format: AVAudioFormat?) {
        tearDownEngine()

        guard let format else { return }
        pendingFormat = format

        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        newEngine.attach(newPlayer)
        newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: format)
        newEngine.mainMixerNode.outputVolume = 1.0

        // After sleep/wake CoreAudio can briefly expose a zero sample-rate device.
        // Starting the player in that state raises NSException on recent macOS builds.
        let outputFormat = newEngine.outputNode.outputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            scheduleEngineRetry()
            return
        }

        do {
            #if os(iOS) || os(tvOS) || os(watchOS)
            // .mixWithOthers lets remote audio coexist with other playback on the shared session.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            newEngine.prepare()
            try newEngine.start()
            guard newEngine.isRunning else {
                scheduleEngineRetry()
                return
            }
            try ObjCExceptionCatcher.startAudioPlayerNode(newPlayer)
            engine = newEngine
            playerNode = newPlayer
            playbackFormat = format
            pendingFormat = nil
            observeEngineConfigurationChanges(newEngine)
        } catch {
            engine = nil
            playerNode = nil
            scheduleEngineRetry()
        }
    }

    private func observeEngineConfigurationChanges(_ engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                let format = self.pendingFormat ?? self.playbackFormat
                self.rebuildEngine(format: format)
            }
        }
    }

    private func scheduleEngineRetry() {
        guard isActive else { return }
        let format = pendingFormat ?? playbackFormat
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.isActive, self.engine == nil else { return }
            self.rebuildEngine(format: format)
        }
    }
}
