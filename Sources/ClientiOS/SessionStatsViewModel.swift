import Foundation
import SharedModels
import TransportWebRTC

@MainActor
final class SessionStatsViewModel: ObservableObject {
    @Published private(set) var metrics = SessionMetricsSnapshot(connectionState: .idle)
    @Published private(set) var quality: NetworkQuality = .good

    private let webRTCSessionManager: any WebRTCSessionManaging
    private let sessionCoordinator: ClientSessionCoordinator
    private let codecProvider: @Sendable () -> String?
    private let formatter = SessionStatsFormatter()
    private let qualityService: any NetworkQualityClassifying
    private var task: Task<Void, Never>?
    private var lastSample: Sample?

    init(
        webRTCSessionManager: any WebRTCSessionManaging,
        sessionCoordinator: ClientSessionCoordinator,
        codecProvider: @escaping @Sendable () -> String? = { nil },
        qualityService: any NetworkQualityClassifying = NetworkQualityIndicatorService()
    ) {
        self.webRTCSessionManager = webRTCSessionManager
        self.sessionCoordinator = sessionCoordinator
        self.codecProvider = codecProvider
        self.qualityService = qualityService
    }

    func start(refreshInterval: TimeInterval = 1.0) {
        stop()
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let diagnostics = webRTCSessionManager.streamDiagnostics
                let now = Date()
                let current = Sample(
                    timestamp: now,
                    framesReceived: diagnostics.framesReceived,
                    bytesReceived: diagnostics.bytesReceived
                )
                let metrics = buildSnapshot(diagnostics: diagnostics, current: current)
                self.metrics = metrics
                self.quality = qualityService.classify(
                    metrics: metrics,
                    isReconnecting: sessionCoordinator.phase == .connecting
                        || sessionCoordinator.phase == .negotiating
                )
                self.lastSample = current
                try? await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        lastSample = nil
    }

    var fpsText: String { formatter.fpsText(for: metrics.framesPerSecond) }
    var bitrateText: String { formatter.bitrateText(for: metrics.bitrateKbps) }
    var latencyText: String { formatter.latencyText(for: metrics.latencyMs) }
    var packetLossText: String { formatter.packetLossText(for: metrics.packetLossPercent) }
    var codecText: String { metrics.codecName ?? "--" }

    private func buildSnapshot(
        diagnostics: StreamDiagnostics,
        current: Sample
    ) -> SessionMetricsSnapshot {
        let previous = lastSample
        let deltaSeconds = previous.map { max(0.001, current.timestamp.timeIntervalSince($0.timestamp)) }
        let fps = deltaSeconds.map { seconds in
            Double(safeCounterDelta(current.framesReceived, previous?.framesReceived)) / seconds
        }
        let bitrate = deltaSeconds.map { seconds in
            (Double(safeCounterDelta(current.bytesReceived, previous?.bytesReceived)) * 8) / seconds / 1000
        }

        return SessionMetricsSnapshot(
            measuredAt: current.timestamp,
            framesPerSecond: fps,
            bitrateKbps: bitrate,
            latencyMs: sessionCoordinator.lastRoundTripLatencyMs,
            // Real downlink video loss (from the receiver-side EMA used for adaptive
            // bitrate), in percent — replaces the old control-channel ping-loss estimate,
            // which didn't reflect what the video stream actually dropped.
            packetLossPercent: Double(webRTCSessionManager.recentVideoLossPermille) / 10.0,
            codecName: codecProvider(),
            displayName: sessionCoordinator.connectedHostName,
            connectionState: webRTCSessionManager.connectionState
        )
    }

    private struct Sample {
        var timestamp: Date
        var framesReceived: UInt64
        var bytesReceived: UInt64
    }

    private func safeCounterDelta(_ current: UInt64, _ previous: UInt64?) -> UInt64 {
        guard let previous else { return current }
        // Diagnostics counters can reset between reconnects; avoid UInt64 underflow traps.
        return current >= previous ? (current - previous) : 0
    }
}
