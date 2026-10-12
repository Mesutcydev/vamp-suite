#if os(macOS)
import CaptureEngine
import CoreMedia
import EncodeEngine
import os

final class EncoderCaptureFrameBridge: CaptureFrameReceiver, @unchecked Sendable {
    private let encoder: VideoToolboxEncoder
    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "EncoderBridge")
    private let lock = NSLock()
    private let encodeQueue = DispatchQueue(
        label: "com.remotedesktop.host.capture-encode",
        qos: .userInteractive
    )
    private var pendingFrame: (CMSampleBuffer, String)?
    private var drainScheduled = false
    private var coalescedFrames: UInt64 = 0
    var sampleBufferMirroringHandler: (@Sendable (CMSampleBuffer, String) -> Void)?

    init(encoder: VideoToolboxEncoder) {
        self.encoder = encoder
    }

    func didCaptureFrame(_ sampleBuffer: CMSampleBuffer, displayID: String) {
        sampleBufferMirroringHandler?(sampleBuffer, displayID)
        guard encoder.isEncoding else { return }

        let shouldSchedule = lock.withLock { () -> Bool in
            if pendingFrame != nil {
                coalescedFrames &+= 1
            }
            pendingFrame = (sampleBuffer, displayID)
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        encodeQueue.async { [weak self] in
            self?.drainLatestFrames()
        }
    }

    private func drainLatestFrames() {
        while true {
            let next = lock.withLock { () -> (CMSampleBuffer, String)? in
                guard let pendingFrame else {
                    drainScheduled = false
                    return nil
                }
                self.pendingFrame = nil
                return pendingFrame
            }
            guard let (sampleBuffer, _) = next else { return }
            guard encoder.isEncoding else { continue }
            do {
                try encoder.encodeSampleBuffer(sampleBuffer)
            } catch {
                logger.error("Bridge encode error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
#endif
