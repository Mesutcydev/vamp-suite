import CaptureEngine
import Diagnostics
import EncodeEngine
import Foundation
import SharedModels
import TransportWebRTC
import os

/// Orchestrates the host streaming pipeline by wiring the encoder output
/// to the WebRTC transport layer. Observes connection and encoder state
/// to activate/deactivate the frame bridge automatically.
///
/// Capture start/stop remains in `CaptureStreamingViewModel`.
/// This coordinator only manages the encoder→transport bridge.
@MainActor
final class HostStreamingCoordinator: ObservableObject {
    enum StreamingPhase: String, Equatable {
        case idle
        case awaitingConnection
        case bridgeActive
        case paused
        case error
    }

    @Published private(set) var phase: StreamingPhase = .idle
    @Published private(set) var streamDiagnostics: StreamDiagnostics = StreamDiagnostics()
    @Published private(set) var errorMessage: String?

    private let encoderPipeline: any EncoderPipelineProtocol
    private let webRTCSessionManager: any WebRTCSessionManaging
    private let eventLogStore: any EventLogStoreProtocol
    let recordingService: SessionRecordingService
    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "StreamCoordinator")

    private var transportBridge: EncoderToTransportBridge?
    private var connectionObserverTask: Task<Void, Never>?
    private var encoderObserverTask: Task<Void, Never>?
    private var videoChannelObserverTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var videoChannelIsOpen = false

    init(
        encoderPipeline: any EncoderPipelineProtocol,
        webRTCSessionManager: any WebRTCSessionManaging,
        eventLogStore: any EventLogStoreProtocol,
        recordingService: SessionRecordingService
    ) {
        self.encoderPipeline = encoderPipeline
        self.webRTCSessionManager = webRTCSessionManager
        self.eventLogStore = eventLogStore
        self.recordingService = recordingService
    }

    // MARK: - Start / Stop

    func startCoordinating() {
        // If a previous session left us in a non-idle state, reset first.
        if phase != .idle {
            stopCoordinating()
        }
        phase = .awaitingConnection

        let bridge = EncoderToTransportBridge()
        transportBridge = bridge
        encoderPipeline.setEncodedFrameReceiver(bridge)

        connectionObserverTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await state in webRTCSessionManager.connectionStateUpdates() {
                self.handleConnectionState(state)
            }
        }

        encoderObserverTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await state in encoderPipeline.stateChanges() {
                self.handleEncoderState(state)
            }
        }

        // Force a fresh keyframe the moment the video data channel opens.
        // This is the critical fix: when the peer connection goes .connected the
        // channel may still be .connecting, so the keyframe forced by
        // handleConnectionState gets encoded and then silently dropped by
        // sendVideoFrame because the channel isn't open yet.  By observing the
        // channel state directly we guarantee the first sent frame is an I-frame.
        videoChannelObserverTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await state in webRTCSessionManager.videoChannelStateUpdates() {
                self.videoChannelIsOpen = (state == .open)
                guard state == .open else { continue }
                guard self.encoderPipeline.isEncoding else {
                    // Encoder not running yet — keyframe will be forced in handleEncoderState
                    self.logger.info("Video channel opened but encoder not running — keyframe deferred to encoder start")
                    continue
                }
                self.encoderPipeline.forceKeyframe()
                self.logger.info("Video channel opened — forcing keyframe for reliable decoder init")
            }
        }

        diagnosticsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                let diag = webRTCSessionManager.streamDiagnostics
                await MainActor.run { self.streamDiagnostics = diag }
            }
        }

        // Bootstrap from current state in case connection/encoder states were already
        // ready before the observer loops begin yielding updates.
        refreshBridgeActivationIfReady()

        logger.info("Streaming coordinator started")
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Streaming",
                message: "Streaming coordinator started"
            ))
        }
    }

    func stopCoordinating() {
        connectionObserverTask?.cancel()
        connectionObserverTask = nil
        encoderObserverTask?.cancel()
        encoderObserverTask = nil
        videoChannelObserverTask?.cancel()
        videoChannelObserverTask = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil

        deactivateBridge()
        encoderPipeline.setEncodedFrameReceiver(nil)
        transportBridge = nil
        phase = .idle
        errorMessage = nil
        videoChannelIsOpen = false

        logger.info("Streaming coordinator stopped")
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Streaming",
                message: "Streaming coordinator stopped"
            ))
        }
    }

    func handleDisplayRestart() {
        guard phase == .bridgeActive else { return }
        phase = .paused
        deactivateBridge()
        streamDiagnostics.restartCount += 1
        logger.info("Display restart: bridge paused, awaiting encoder restart")
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Streaming",
                message: "Display restart: bridge paused (restart #\(streamDiagnostics.restartCount))"
            ))
        }
    }

    // MARK: - State Handlers

    private func handleConnectionState(_ state: ConnectionState) {
        switch state {
        case .connected:
            if encoderPipeline.isEncoding {
                if phase != .bridgeActive {
                    activateBridge()
                } else {
                    // Bridge was activated before the client's TCP connection arrived.
                    // The first keyframe was likely sent while the video channel was still
                    // .connecting and got dropped silently. Force a fresh keyframe now
                    // that the channel is .open so the decoder can initialize.
                    encoderPipeline.forceKeyframe()
                    logger.info("TCP connected with bridge already active — forcing keyframe")
                }
            } else {
                phase = .awaitingConnection
            }
        case .disconnected, .failed, .idle:
            if phase == .bridgeActive || phase == .paused {
                deactivateBridge()
                phase = .awaitingConnection
            }
        default:
            break
        }
    }

    private func handleEncoderState(_ state: EncoderState) {
        switch state {
        case .encoding:
            // Attach source as soon as encoder is running. Video channel send attempts
            // are best-effort and begin flowing once the channel opens.
            if phase != .bridgeActive {
                activateBridge()
                // If the video channel opened before the encoder started, the
                // videoChannelObserverTask skipped the keyframe because isEncoding
                // was false. Force one now so the client decoder can initialize.
                if videoChannelIsOpen {
                    encoderPipeline.forceKeyframe()
                    logger.info("Encoder started with video channel already open — forcing keyframe")
                }
            }
        case .idle, .configured, .failed:
            if phase == .bridgeActive {
                deactivateBridge()
                phase = webRTCSessionManager.connectionState == .connected
                    ? .awaitingConnection : .idle
            }
        }
    }

    private func refreshBridgeActivationIfReady() {
        if encoderPipeline.isEncoding {
            if phase != .bridgeActive {
                activateBridge()
            }
            return
        }

        if phase == .bridgeActive &&
            (webRTCSessionManager.connectionState != .connected || !encoderPipeline.isEncoding) {
            deactivateBridge()
            phase = webRTCSessionManager.connectionState == .connected ? .awaitingConnection : .idle
        }
    }

    // MARK: - Bridge Management

    private func activateBridge() {
        guard let bridge = transportBridge else { return }
        bridge.activate()
        webRTCSessionManager.attachVideoSource(bridge)
        phase = .bridgeActive
        logger.info("Transport bridge activated — frames flowing")
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Streaming",
                message: "Transport bridge activated"
            ))
        }
    }

    private func deactivateBridge() {
        transportBridge?.deactivate()
        webRTCSessionManager.attachVideoSource(nil)
    }

    func startRecording() {
        do {
            let url = try recordingService.start()
            Task {
                await eventLogStore.append(EventLogItem(
                    severity: .info,
                    category: "Recording",
                    message: "Session recording started",
                    metadata: ["directory": url.lastPathComponent]
                ))
            }
        } catch {
            Task {
                await eventLogStore.append(EventLogItem(
                    severity: .error,
                    category: "Recording",
                    message: "Failed to start recording: \(error.localizedDescription)"
                ))
            }
        }
    }

    func stopRecording() {
        Task { [weak self] in
            guard let self else { return }
            let result = await recordingService.stop()
            await eventLogStore.append(EventLogItem(
                severity: result == nil ? .warning : .info,
                category: "Recording",
                message: result == nil ? "Session recording stopped with errors" : "Session recording stopped",
                metadata: result.map { ["file": $0.lastPathComponent] } ?? [:]
            ))
        }
    }
}
