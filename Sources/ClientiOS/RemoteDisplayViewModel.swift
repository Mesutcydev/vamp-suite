import Foundation
import SharedModels
import TransportWebRTC
import os

/// Client-side view model for the remote desktop display.
/// Receives video frames from the WebRTC session manager and manages
/// connection/receiving/stall state for the UI.
@MainActor
final class RemoteDisplayViewModel: ObservableObject {
    enum ViewState: Equatable {
        case disconnected
        case connecting
        case waitingForVideo
        case receiving(width: Int, height: Int)
        case stalled
        case error(String)
    }

    @Published private(set) var viewState: ViewState = .disconnected
    @Published private(set) var diagnostics: StreamDiagnostics = StreamDiagnostics()
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var lastFrameSize: (width: Int, height: Int)?
    /// Number of active video frame subscribers — used in the diagnostic panel.
    @Published private(set) var videoSubscriberCount: Int = 0
    /// Cumulative re-subscriptions triggered by the stall checker — useful for diagnosing Release-only hangs.
    @Published private(set) var resubscribeCount: Int = 0

    private let webRTCSessionManager: any WebRTCSessionManaging
    private let logger = Logger(subsystem: "com.mesutcy.remotedesktop.terminal", category: "DisplayViewModel")

    private var connectionTask: Task<Void, Never>?
    private var videoTask: Task<Void, Never>?
    private var stallCheckTask: Task<Void, Never>?

    /// Generation counter for `videoTask`. Incremented on each re-subscription so that
    /// a superseded task self-terminates rather than racing with the new subscriber.
    private var videoTaskGeneration: UInt64 = 0

    init(webRTCSessionManager: any WebRTCSessionManaging) {
        self.webRTCSessionManager = webRTCSessionManager
    }

    func startObserving() {
        stopObserving()
        logger.info("DisplayViewModel: startObserving")
        connectionTask = Task { [weak self] in
            guard let self else { return }
            for await state in webRTCSessionManager.connectionStateUpdates() {
                guard !Task.isCancelled else { break }
                self.logger.debug("DisplayViewModel: connectionState → \(state.rawValue)")
                self.connectionState = state
                self.updateViewState()
            }
        }

        startVideoTask()

        stallCheckTask = Task { [weak self] in
            var framesReceivedAtLastCheck: UInt64 = 0
            // Timestamp of the last re-subscription so we don't thrash every second.
            var lastResubscribeTime: Date = .distantPast
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.diagnostics = webRTCSessionManager.streamDiagnostics
                self.videoSubscriberCount = webRTCSessionManager.videoFrameSubscriberCount
                if self.diagnostics.isStalled() && self.viewState != .stalled {
                    self.viewState = .stalled
                }
                let newCount = self.diagnostics.framesReceived
                // Re-subscribe if frames are arriving but lastFrameSize is still nil.
                // Guard with a 3-second cooldown so we don't cancel/recreate the Task
                // faster than it can register — that was the Release-build race.
                let cooldownElapsed = Date().timeIntervalSince(lastResubscribeTime) >= 3.0
                if self.connectionState == .connected,
                   self.lastFrameSize == nil,
                   newCount > framesReceivedAtLastCheck,
                   cooldownElapsed {
                    self.logger.warning(
                        "DisplayViewModel: transport receiving frames (\(newCount)) but videoTask has no lastFrameSize — re-subscribing (attempt \(self.resubscribeCount + 1), subscribers=\(self.videoSubscriberCount))"
                    )
                    lastResubscribeTime = Date()
                    self.resubscribeCount += 1
                    self.startVideoTask()
                }
                framesReceivedAtLastCheck = newCount
            }
        }
    }

    /// Creates a new videoTask with an incremented generation. The old task will detect
    /// the stale generation and self-terminate after its next frame, so there is never
    /// a window where zero subscribers exist in `videoFrameContinuations`.
    private func startVideoTask() {
        videoTaskGeneration &+= 1
        let generation = videoTaskGeneration
        // Do NOT cancel the old task here — let it self-terminate via the generation
        // check below. Cancelling it first removes the old continuation from
        // videoFrameContinuations before the new one is registered, creating a gap
        // that caused the "stuck at waiting frame" bug in Release builds.
        videoTask = Task { [weak self] in
            guard let self else { return }
            guard self.videoTaskGeneration == generation else { return }
            self.logger.info("DisplayViewModel: videoTask gen=\(generation) subscribed")
            for await frame in webRTCSessionManager.receivedVideoFrames() {
                guard !Task.isCancelled else { break }
                // Exit if a newer generation has been started; the new task is already
                // subscribed so there's no gap in coverage.
                guard self.videoTaskGeneration == generation else { break }
                if self.lastFrameSize == nil {
                    self.logger.info(
                        "DisplayViewModel: gen=\(generation) first frame \(frame.width)×\(frame.height)"
                    )
                }
                self.lastFrameSize = (width: frame.width, height: frame.height)
                self.updateViewState()
            }
            self.logger.info("DisplayViewModel: videoTask gen=\(generation) stream ended")
        }
    }

    func stopObserving() {
        videoTaskGeneration &+= 1   // invalidate any running videoTask
        connectionTask?.cancel()
        videoTask?.cancel()
        stallCheckTask?.cancel()
        connectionTask = nil
        videoTask = nil
        stallCheckTask = nil
    }

    private func updateViewState() {
        switch connectionState {
        case .idle, .discovering:
            viewState = .disconnected
        case .signaling, .connecting, .reconnecting:
            viewState = .connecting
        case .connected:
            if let size = lastFrameSize {
                viewState = .receiving(width: size.width, height: size.height)
            } else {
                viewState = .waitingForVideo
            }
        case .disconnected:
            viewState = .disconnected
        case .failed:
            viewState = .error("Connection failed")
        }
    }

    var stateText: String {
        switch viewState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .waitingForVideo: return "Waiting for video…"
        case .receiving(let w, let h): return "Receiving \(w)×\(h)"
        case .stalled: return "Video stalled"
        case .error(let msg): return msg
        }
    }

    var diagnosticsSummary: String {
        diagnostics.summaryText
    }
}
