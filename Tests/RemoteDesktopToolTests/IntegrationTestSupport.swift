import CoreMedia
import XCTest
@testable import CaptureEngine
@testable import ClientiOS
@testable import Diagnostics
@testable import Discovery
@testable import EncodeEngine
@testable import HostApp
@testable import InputControl
@testable import Permissions
@testable import SharedModels
@testable import SharedProtocol
@testable import TransportWebRTC

func waitUntilAsync(
    timeout: TimeInterval,
    pollInterval: UInt64 = 20_000_000,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(nanoseconds: pollInterval)
    }
    XCTFail("Condition not satisfied within \(timeout)s")
    throw NSError(domain: "InProcessPipelineHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "Condition not satisfied within \(timeout)s"])
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

final class InProcessTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ message: String) {
        lock.withLock {
            entries.append(message)
        }
    }

    func snapshot() -> [String] {
        lock.withLock { entries }
    }
}

final class InProcessSessionSignaling: SessionCoordinatorSignaling, @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var listeners: [UInt16: InProcessSessionSignaling] = [:]
    private static var nextPort: UInt16 = 41000

    private let lock = NSLock()
    private let role: RemoteDesktopRole
    private let peerID: UUID
    private let displayName: String
    private weak var peer: InProcessSessionSignaling?
    private var listeningPort: UInt16?
    private var messageContinuations: [UUID: AsyncThrowingStream<VersionedSignalingMessage, Error>.Continuation] = [:]
    private var pendingMessages: [VersionedSignalingMessage] = []
    var traceHandler: (@Sendable (String) -> Void)?

    init(role: RemoteDesktopRole, peerID: UUID, displayName: String) {
        self.role = role
        self.peerID = peerID
        self.displayName = displayName
    }

    func startListening(port: UInt16) throws -> UInt16 {
        if let existing = lock.withLock({ listeningPort }) {
            return existing
        }
        let assignedPort = Self.registryLock.withLock { () -> UInt16 in
            let candidate: UInt16
            if port == 0 {
                candidate = Self.nextPort
                Self.nextPort &+= 1
            } else {
                candidate = port
            }
            Self.listeners[candidate] = self
            return candidate
        }
        lock.withLock {
            listeningPort = assignedPort
        }
        return assignedPort
    }

    func stopListening() {
        let port = lock.withLock { () -> UInt16? in
            let current = listeningPort
            listeningPort = nil
            return current
        }
        if let port {
            Self.registryLock.withLock {
                Self.listeners[port] = nil
            }
        }
        disconnect()
    }

    func connect(host: String, port: UInt16) async throws {
        let remote = Self.registryLock.withLock { Self.listeners[port] }
        guard let remote else {
            throw BonjourSignalingService.SignalingError.notConnected
        }
        traceHandler?("signaling.connect.\(role.rawValue)")
        lock.withLock {
            peer = remote
        }
        remote.lock.withLock {
            remote.peer = self
        }
    }

    func disconnect() {
        let remote = lock.withLock { () -> InProcessSessionSignaling? in
            let current = peer
            peer = nil
            return current
        }
        remote?.lock.withLock {
            if remote?.peer === self {
                remote?.peer = nil
            }
        }
        finishStreams()
    }

    func dropCurrentConnection() {
        // In-process signaling: same as disconnect for test purposes
        disconnect()
    }

    func startAdvertising(host: HostIdentity) async throws {}

    func stopAdvertising() async {
        stopListening()
    }

    func send(_ message: VersionedSignalingMessage) async throws {
        guard let remote = lock.withLock({ peer }) else {
            throw BonjourSignalingService.SignalingError.notConnected
        }
        traceHandler?("signaling.send.\(role.rawValue).\(message.envelope.event.kind.rawValue)")
        remote.deliver(message)
    }

    func receiveMessages() -> AsyncThrowingStream<VersionedSignalingMessage, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            let queuedMessages = lock.withLock { () -> [VersionedSignalingMessage] in
                messageContinuations[id] = continuation
                let snapshot = pendingMessages
                pendingMessages.removeAll()
                return snapshot
            }
            self.traceHandler?("signaling.receive.register.\(self.role.rawValue)")
            queuedMessages.forEach { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.messageContinuations[id] = nil
                }
            }
        }
    }

    func sendSignalingMessage(_ message: VersionedSignalingMessage) async throws {
        try await send(message)
    }

    func incomingSignalingMessages() -> AsyncThrowingStream<VersionedSignalingMessage, Error> {
        receiveMessages()
    }

    func sendHello(_ message: HelloMessage, to host: HostIdentity) async throws {}

    func sendOffer(_ message: SessionOfferMessage, to host: HostIdentity) async throws {
        try await send(versionedMessage(event: .offer(message), sessionID: message.sessionID))
    }

    func sendAnswer(_ message: SessionAnswerMessage, to client: ClientIdentity) async throws {
        try await send(versionedMessage(event: .answer(message), sessionID: message.sessionID))
    }

    func sendCandidate(_ message: ICECandidateMessage) async throws {
        try await send(versionedMessage(event: .iceCandidate(message), sessionID: message.sessionID))
    }

    private func versionedMessage(event: SignalingEvent, sessionID: UUID?) -> VersionedSignalingMessage {
        VersionedSignalingMessage(
            envelope: SignalingEnvelope(
                protocolVersion: 1,
                sessionID: sessionID,
                sender: SignalingPeer(id: peerID, role: role, displayName: displayName),
                event: event
            )
        )
    }

    private func deliver(_ message: VersionedSignalingMessage) {
        traceHandler?("signaling.deliver.\(role.rawValue).\(message.envelope.event.kind.rawValue)")
        let continuations = lock.withLock { () -> [AsyncThrowingStream<VersionedSignalingMessage, Error>.Continuation] in
            let activeContinuations = Array(messageContinuations.values)
            if activeContinuations.isEmpty {
                pendingMessages.append(message)
            }
            return activeContinuations
        }
        continuations.forEach { $0.yield(message) }
    }

    private func finishStreams() {
        let continuations = lock.withLock { () -> [AsyncThrowingStream<VersionedSignalingMessage, Error>.Continuation] in
            let snapshot = Array(messageContinuations.values)
            messageContinuations.removeAll()
            return snapshot
        }
        continuations.forEach { $0.finish() }
    }
}

final class RecordingEventLogStore: EventLogStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [EventLogItem] = []

    func append(_ item: EventLogItem) async {
        lock.withLock {
            items.append(item)
        }
    }

    func recentItems(limit: Int) async -> [EventLogItem] {
        lock.withLock {
            Array(items.suffix(limit))
        }
    }

    func removeAll() async {
        lock.withLock {
            items.removeAll()
        }
    }
}

final class StaticDisplayLayoutProvider: DisplayLayoutProviding, @unchecked Sendable {
    let layout: DisplayLayout

    init(layout: DisplayLayout) {
        self.layout = layout
    }

    func currentDisplayLayout() async throws -> DisplayLayout {
        layout
    }
}

final class FakeCaptureEngine: CaptureEngineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<CaptureState>.Continuation] = [:]
    private(set) var isCapturing: Bool = false
    private(set) var captureState: CaptureState = .stopped
    private(set) var diagnostics: CaptureDiagnostics = CaptureDiagnostics()

    func startCapture(displayID: String, qualityPreset: StreamQualityPreset, allowsHighResolution: Bool) async throws {
        let continuations = lock.withLock { () -> [AsyncStream<CaptureState>.Continuation] in
            isCapturing = true
            captureState = .running
            diagnostics.currentDisplayID = displayID
            diagnostics.qualityPreset = qualityPreset
            return Array(self.continuations.values)
        }
        continuations.forEach { $0.yield(.running) }
    }

    func stopCapture() async {
        let continuations = lock.withLock { () -> [AsyncStream<CaptureState>.Continuation] in
            isCapturing = false
            captureState = .stopped
            return Array(self.continuations.values)
        }
        continuations.forEach { $0.yield(.stopped) }
    }

    func setFrameReceiver(_ receiver: (any CaptureFrameReceiver)?) {}
    func setAudioReceiver(_ receiver: (any CaptureAudioReceiver)?) {}

    func stateChanges() -> AsyncStream<CaptureState> {
        AsyncStream { continuation in
            let id = UUID()
            let current = self.lock.withLock { () -> CaptureState in
                self.continuations[id] = continuation
                return self.captureState
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.continuations[id] = nil
                }
            }
        }
    }
}

final class FakeEncoderPipeline: EncoderPipelineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<EncoderState>.Continuation] = [:]
    private var receiver: (any EncodedFrameReceiver)?
    private(set) var configuredDisplay: DisplayDescriptor?
    private(set) var configuredQuality: StreamQualityPreset?
    private(set) var isEncoding: Bool = false
    private(set) var encoderState: EncoderState = .idle
    private(set) var encoderDiagnostics: EncoderDiagnostics = EncoderDiagnostics()

    func configure(for display: DisplayDescriptor, qualityPreset: StreamQualityPreset, codec: EncodedFrameCodec) async throws {
        let continuations = lock.withLock { () -> [AsyncStream<EncoderState>.Continuation] in
            configuredDisplay = display
            configuredQuality = qualityPreset
            encoderState = .configured
            encoderDiagnostics.configuredCodec = codec
            encoderDiagnostics.configuredWidth = Int(display.frame.size.width)
            encoderDiagnostics.configuredHeight = Int(display.frame.size.height)
            return Array(self.continuations.values)
        }
        continuations.forEach { $0.yield(.configured) }
    }

    func reconfigure(for display: DisplayDescriptor, qualityPreset: StreamQualityPreset, codec: EncodedFrameCodec) async throws {
        try await configure(for: display, qualityPreset: qualityPreset, codec: codec)
    }

    func configure(
        for display: DisplayDescriptor,
        qualityPreset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        dynamicRange: StreamDynamicRange,
        minLongEdge: Int
    ) async throws {
        try await configure(for: display, qualityPreset: qualityPreset, codec: codec)
    }

    func reconfigure(
        for display: DisplayDescriptor,
        qualityPreset: StreamQualityPreset,
        codec: EncodedFrameCodec,
        dynamicRange: StreamDynamicRange,
        minLongEdge: Int
    ) async throws {
        try await reconfigure(for: display, qualityPreset: qualityPreset, codec: codec)
    }

    func startEncoding() async throws {
        let continuations = lock.withLock { () -> [AsyncStream<EncoderState>.Continuation] in
            isEncoding = true
            encoderState = .encoding
            return Array(self.continuations.values)
        }
        continuations.forEach { $0.yield(.encoding) }
    }

    func flush() async throws {}

    func stopEncoding() async {
        let continuations = lock.withLock { () -> [AsyncStream<EncoderState>.Continuation] in
            isEncoding = false
            encoderState = .idle
            return Array(self.continuations.values)
        }
        continuations.forEach { $0.yield(.idle) }
    }

    func setEncodedFrameReceiver(_ receiver: (any EncodedFrameReceiver)?) {
        lock.withLock {
            self.receiver = receiver
        }
    }

    func stateChanges() -> AsyncStream<EncoderState> {
        AsyncStream { continuation in
            let id = UUID()
            let current = self.lock.withLock { () -> EncoderState in
                self.continuations[id] = continuation
                return self.encoderState
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.continuations[id] = nil
                }
            }
        }
    }

    func forceKeyframe() {}

    func emitFrame(
        codec: EncodedFrameCodec = .h264,
        bytes: Data = Data([0x01, 0x02, 0x03, 0x04]),
        isKeyframe: Bool = true,
        width: Int = 1920,
        height: Int = 1080,
        sequenceNumber: UInt64 = 1,
        parameterSets: Data? = Data([0x67, 0x64, 0x00, 0x1F])
    ) async {
        let receiver = lock.withLock { () -> (any EncodedFrameReceiver)? in
            encoderDiagnostics.encodedFrames += 1
            if isKeyframe {
                encoderDiagnostics.keyframes += 1
            }
            encoderDiagnostics.lastEncodeTimestamp = Date()
            return self.receiver
        }

        let frame = EncodedFrame(
            codec: codec,
            data: bytes,
            isKeyframe: isKeyframe,
            presentationTimestamp: CMTime(seconds: 1, preferredTimescale: 600),
            duration: CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600),
            width: width,
            height: height,
            sequenceNumber: sequenceNumber,
            parameterSets: parameterSets
        )
        receiver?.didEncode(frame)
    }
}

final class RecordingInputInjectionService: InputInjectionServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var commands: [InputCommand] = []
    private(set) var shortcuts: [ShortcutCommand] = []

    func inject(_ command: InputCommand) async throws {
        lock.withLock {
            commands.append(command)
        }
    }

    func perform(_ shortcut: ShortcutCommand) async throws {
        lock.withLock {
            shortcuts.append(shortcut)
        }
    }

    func snapshotCommands() -> [InputCommand] {
        lock.withLock { commands }
    }
}

final class InProcessWebRTCSessionManager: WebRTCSessionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private let name: String
    private weak var peer: InProcessWebRTCSessionManager?
    private var attachedVideoTask: Task<Void, Never>?
    private var currentSessionID: UUID?
    private var currentRole: WebRTCSessionRole?
    private var inputContinuations: [UUID: AsyncStream<DataChannelEnvelope>.Continuation] = [:]
    private var videoContinuations: [UUID: AsyncStream<VideoFrameData>.Continuation] = [:]
    private var pendingInputMessages: [DataChannelEnvelope] = []
    private var pendingVideoFrames: [VideoFrameData] = []
    private var connectionContinuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    private var dataStateContinuations: [UUID: AsyncStream<DataChannelState>.Continuation] = [:]
    private var localICEContinuations: [UUID: AsyncStream<ICECandidateMessage>.Continuation] = [:]
    private var controlChannelAuthTokenHex: String?
    private var outboundControlAuthCounter: UInt64 = 0
    private(set) var dataMessageSubscriberCount: Int = 0
    private(set) var inputMessagesQueued: UInt64 = 0
    private(set) var inputMessagesDelivered: UInt64 = 0
    private(set) var connectionState: ConnectionState = .idle
    private(set) var peerConnectionState: PeerConnectionState = .closed
    private(set) var dataChannelState: DataChannelState = .closed
    private(set) var mediaChannelReadiness: MediaChannelReadiness = MediaChannelReadiness()
    private(set) var streamDiagnostics: StreamDiagnostics = StreamDiagnostics()
    var videoFrameSubscriberCount: Int { lock.withLock { videoContinuations.count } }
    var traceHandler: (@Sendable (String) -> Void)?

    init(name: String) {
        self.name = name
    }

    deinit {
        attachedVideoTask?.cancel()
    }

    static func makePair() -> (InProcessWebRTCSessionManager, InProcessWebRTCSessionManager) {
        let host = InProcessWebRTCSessionManager(name: "host")
        let client = InProcessWebRTCSessionManager(name: "client")
        host.peer = client
        client.peer = host
        return (host, client)
    }

    func prepareSession(id: UUID, role: WebRTCSessionRole) async throws {
        traceHandler?("webrtc.\(name).prepare.\(role.rawValue)")
        let continuations = lock.withLock { () -> [AsyncStream<ConnectionState>.Continuation] in
            currentSessionID = id
            currentRole = role
            connectionState = .connecting
            peerConnectionState = .connecting
            dataChannelState = .connecting
            mediaChannelReadiness = MediaChannelReadiness(dataChannelState: .connecting, videoTrackAttached: false, audioTrackAttached: false)
            return Array(connectionContinuations.values)
        }
        continuations.forEach { $0.yield(.connecting) }
    }

    func createOffer(
        sessionID: UUID,
        qualityPreset: StreamQualityPreset,
        displayID: String?
    ) async throws -> SessionOfferMessage {
        SessionOfferMessage(
            sessionID: sessionID,
            sdp: "offer-\(name)-\(sessionID.uuidString)",
            requestedDisplayID: displayID,
            qualityPreset: qualityPreset
        )
    }

    func applyRemoteOffer(_ message: SessionOfferMessage) async throws -> SessionAnswerMessage {
        traceHandler?("webrtc.\(name).applyRemoteOffer")
        let continuations = lock.withLock { () -> [AsyncStream<ConnectionState>.Continuation] in
            currentSessionID = message.sessionID
            connectionState = .connecting
            peerConnectionState = .connecting
            return Array(connectionContinuations.values)
        }
        continuations.forEach { $0.yield(.connecting) }

        return SessionAnswerMessage(
            sessionID: message.sessionID,
            sdp: "answer-\(name)-\(message.sessionID.uuidString)",
            acceptedDisplayID: message.requestedDisplayID
        )
    }

    func applyRemoteAnswer(_ message: SessionAnswerMessage) async throws {
        traceHandler?("webrtc.\(name).applyRemoteAnswer")
        establishTransport(with: message.sessionID)
    }

    func addRemoteCandidate(_ message: ICECandidateMessage) async throws {}

    func closeSession() async {
        attachedVideoTask?.cancel()
        attachedVideoTask = nil
        transitionToDisconnected(.idle, peerState: .closed, dataState: .closed)
    }

    func sendInputCommand(_ message: InputCommandMessage) async throws {
        traceHandler?("webrtc.\(name).sendInputCommand")
        let envelope = try DataChannelEnvelope.inputCommand(message)
        let auth = lock.withLock { () -> (String?, UInt64) in
            if controlChannelAuthTokenHex != nil {
                outboundControlAuthCounter += 1
            }
            return (controlChannelAuthTokenHex, outboundControlAuthCounter)
        }
        if let token = auth.0,
           let authenticated = envelope.authenticated(using: token, counter: auth.1) {
            try sendDataMessage(authenticated)
        } else {
            try sendDataMessage(envelope)
        }
    }

    func sendDataMessage(_ message: DataChannelEnvelope) throws {
        guard connectionState == .connected else {
            throw WebRTCSessionError.dataChannelUnavailable
        }
        peer?.enqueueDataMessage(message)
    }

    func configureControlChannelAuth(sessionTokenHex: String?) {
        lock.withLock {
            controlChannelAuthTokenHex = sessionTokenHex
            outboundControlAuthCounter = 0
        }
    }

    func receiveDataMessages() -> AsyncStream<DataChannelEnvelope> {
        AsyncStream { continuation in
            let id = UUID()
            let pendingMessages = self.lock.withLock { () -> [DataChannelEnvelope] in
                self.inputContinuations[id] = continuation
                self.dataMessageSubscriberCount = self.inputContinuations.count
                let queued = self.pendingInputMessages
                self.pendingInputMessages.removeAll()
                return queued
            }
            self.traceHandler?("webrtc.\(self.name).receiveDataMessages.register")
            pendingMessages.forEach { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.inputContinuations[id] = nil
                    self?.dataMessageSubscriberCount = self?.inputContinuations.count ?? 0
                }
            }
        }
    }

    func localICECandidates() -> AsyncStream<ICECandidateMessage> {
        AsyncStream { continuation in
            let id = UUID()
            self.lock.withLock {
                self.localICEContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.localICEContinuations[id] = nil
                }
            }
        }
    }

    func attachVideoSource(_ source: (any VideoFrameSource)?) {
        attachedVideoTask?.cancel()
        attachedVideoTask = nil

        lock.withLock {
            mediaChannelReadiness.videoTrackAttached = source != nil
        }

        guard let producer = source as? any VideoFrameProducer else { return }
        attachedVideoTask = Task { [weak self] in
            guard let self else { return }
            for await frame in producer.videoFrames() {
                guard !Task.isCancelled else { break }
                try? self.sendVideoFrame(frame)
            }
        }
    }

    func sendVideoFrame(_ frame: VideoFrameData) throws {
        guard connectionState == .connected else {
            throw WebRTCSessionError.invalidState("Transport not connected")
        }
        let peer = lock.withLock { () -> InProcessWebRTCSessionManager? in
            streamDiagnostics.framesSent += 1
            streamDiagnostics.bytesSent += UInt64(frame.data.count)
            streamDiagnostics.lastFrameSentAt = Date()
            return self.peer
        }
        peer?.enqueueVideoFrame(frame)
    }

    func receivedVideoFrames() -> AsyncStream<VideoFrameData> {
        AsyncStream { continuation in
            let id = UUID()
            let pendingFrames = self.lock.withLock { () -> [VideoFrameData] in
                self.videoContinuations[id] = continuation
                let queued = self.pendingVideoFrames
                self.pendingVideoFrames.removeAll()
                return queued
            }
            pendingFrames.forEach { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.videoContinuations[id] = nil
                }
            }
        }
    }

    func connectionStateUpdates() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            let current = self.lock.withLock { () -> ConnectionState in
                self.connectionContinuations[id] = continuation
                return self.connectionState
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.connectionContinuations[id] = nil
                }
            }
        }
    }

    func dataChannelStateUpdates() -> AsyncStream<DataChannelState> {
        AsyncStream { continuation in
            let id = UUID()
            let current = self.lock.withLock { () -> DataChannelState in
                self.dataStateContinuations[id] = continuation
                return self.dataChannelState
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.dataStateContinuations[id] = nil
                }
            }
        }
    }

    func videoChannelStateUpdates() -> AsyncStream<DataChannelState> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func simulateDisconnect() {
        transitionToDisconnected(.disconnected, peerState: .disconnected, dataState: .closed)
        peer?.transitionToDisconnected(.disconnected, peerState: .disconnected, dataState: .closed)
    }

    func simulateReconnect() {
        transitionToConnected()
        peer?.transitionToConnected()
    }

    private func establishTransport(with sessionID: UUID) {
        traceHandler?("webrtc.\(name).establishTransport")
        lock.withLock {
            currentSessionID = sessionID
        }
        transitionToConnected()
        peer?.transitionToConnected()
    }

    private func transitionToConnected() {
        traceHandler?("webrtc.\(name).connected")
        let snapshots = lock.withLock { () -> ([AsyncStream<ConnectionState>.Continuation], [AsyncStream<DataChannelState>.Continuation]) in
            connectionState = .connected
            peerConnectionState = .connected
            dataChannelState = .open
            mediaChannelReadiness.dataChannelState = .open
            return (Array(connectionContinuations.values), Array(dataStateContinuations.values))
        }
        snapshots.0.forEach { $0.yield(.connected) }
        snapshots.1.forEach { $0.yield(.open) }
    }

    private func transitionToDisconnected(
        _ state: ConnectionState,
        peerState: PeerConnectionState,
        dataState: DataChannelState
    ) {
        let snapshots = lock.withLock { () -> ([AsyncStream<ConnectionState>.Continuation], [AsyncStream<DataChannelState>.Continuation]) in
            connectionState = state
            peerConnectionState = peerState
            dataChannelState = dataState
            mediaChannelReadiness.dataChannelState = dataState
            return (Array(connectionContinuations.values), Array(dataStateContinuations.values))
        }
        snapshots.0.forEach { $0.yield(state) }
        snapshots.1.forEach { $0.yield(dataState) }
    }

    private func enqueueDataMessage(_ message: DataChannelEnvelope) {
        traceHandler?("webrtc.\(name).enqueueDataMessage.\(message.kind.rawValue)")
        let continuations = lock.withLock { () -> [AsyncStream<DataChannelEnvelope>.Continuation] in
            let activeContinuations = Array(inputContinuations.values)
            if activeContinuations.isEmpty {
                pendingInputMessages.append(message)
                inputMessagesQueued += 1
            }
            inputMessagesDelivered += 1
            return activeContinuations
        }
        continuations.forEach { $0.yield(message) }
    }

    private func enqueueVideoFrame(_ frame: VideoFrameData) {
        let continuations = lock.withLock { () -> [AsyncStream<VideoFrameData>.Continuation] in
            streamDiagnostics.framesReceived += 1
            streamDiagnostics.bytesReceived += UInt64(frame.data.count)
            if streamDiagnostics.firstFrameReceivedAt == nil {
                streamDiagnostics.firstFrameReceivedAt = Date()
            }
            streamDiagnostics.lastFrameReceivedAt = Date()
            streamDiagnostics.receivingState = .receiving
            let activeContinuations = Array(videoContinuations.values)
            if activeContinuations.isEmpty {
                pendingVideoFrames.append(frame)
            }
            return activeContinuations
        }
        continuations.forEach { $0.yield(frame) }
    }
}

@MainActor
final class InProcessPipelineHarness {
    let hostIdentity = HostIdentity(
        displayName: "Integration Host",
        modelName: "Mac",
        osVersion: "macOS",
        appVersion: "1.0",
        publicKeyFingerprint: "host-fingerprint"
    )
    let clientIdentity = ClientIdentity(
        displayName: "Integration Client",
        deviceModel: "iPhone",
        osVersion: "iOS",
        appVersion: "1.0",
        publicKeyFingerprint: "client-fingerprint"
    )

    let displayLayout: DisplayLayout
    let hostEventLog = RecordingEventLogStore()
    let clientEventLog = RecordingEventLogStore()
    let hostCapture = FakeCaptureEngine()
    let hostEncoder = FakeEncoderPipeline()
    let hostInput = RecordingInputInjectionService()
    let hostDisplayProvider: StaticDisplayLayoutProvider
    let hostWebRTC: InProcessWebRTCSessionManager
    let clientWebRTC: InProcessWebRTCSessionManager
    let hostSignaling: InProcessSessionSignaling
    let clientSignaling: InProcessSessionSignaling
    let hostBridge: SignalingWebRTCBridge
    let clientBridge: SignalingWebRTCBridge
    let hostStreamingCoordinator: HostStreamingCoordinator
    let hostInputRouter: HostInputCommandRouter
    private(set) var activeSessionID: UUID?

    private let trustDirectory: URL
    private let traceRecorder = InProcessTraceRecorder()

    var streamingPhase: HostStreamingCoordinator.StreamingPhase {
        hostStreamingCoordinator.phase
    }

    func debugTrace() -> String {
        traceRecorder.snapshot().joined(separator: "\n")
    }

    init() async throws {
        let display = DisplayDescriptor(
            id: "main",
            name: "Main Display",
            frame: DesktopRect(origin: .zero, size: DesktopSize(width: 1920, height: 1080)),
            pixelSize: DesktopSize(width: 3840, height: 2160),
            scaleFactor: 2,
            refreshRate: 60,
            isPrimary: true
        )
        displayLayout = DisplayLayout(displays: [display], primaryDisplayID: display.id, virtualBounds: display.frame)
        hostDisplayProvider = StaticDisplayLayoutProvider(layout: displayLayout)

        let pair = InProcessWebRTCSessionManager.makePair()
        hostWebRTC = pair.0
        clientWebRTC = pair.1
        hostSignaling = InProcessSessionSignaling(role: .host, peerID: hostIdentity.id, displayName: hostIdentity.displayName)
        clientSignaling = InProcessSessionSignaling(role: .client, peerID: clientIdentity.id, displayName: clientIdentity.displayName)
        hostBridge = SignalingWebRTCBridge(sessionManager: hostWebRTC, signalingTransport: hostSignaling)
        clientBridge = SignalingWebRTCBridge(sessionManager: clientWebRTC, signalingTransport: clientSignaling)

        let recorder = traceRecorder
        hostWebRTC.traceHandler = { recorder.record($0) }
        clientWebRTC.traceHandler = { recorder.record($0) }
        hostSignaling.traceHandler = { recorder.record($0) }
        clientSignaling.traceHandler = { recorder.record($0) }

        trustDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: trustDirectory, withIntermediateDirectories: true)
        let store = PersistentTrustedPeerStore(directory: trustDirectory)
        let trustGate = PeerTrustGate(store: store)
        await trustGate.setApprovalHandler { _, _, _ in true }
        let recordingService = await MainActor.run { SessionRecordingService() }
        let modeProvider = await MainActor.run { HostSessionModeController(mode: .fullControl) }

        hostStreamingCoordinator = HostStreamingCoordinator(
            encoderPipeline: hostEncoder,
            webRTCSessionManager: hostWebRTC,
            eventLogStore: hostEventLog,
            recordingService: recordingService
        )
        hostInputRouter = HostInputCommandRouter(
            inputService: hostInput,
            webRTCSessionManager: hostWebRTC,
            eventLogStore: hostEventLog,
            modeProvider: modeProvider
        )
        hostInputRouter.traceHandler = { recorder.record($0) }
        _ = trustGate
    }

    deinit {
        try? FileManager.default.removeItem(at: trustDirectory)
    }

    func startConnectedSession(qualityPreset: StreamQualityPreset = .balanced) async throws {
        let sessionID = UUID()
        let sessionTokenHex = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        traceRecorder.record("harness.startConnectedSession")
        activeSessionID = sessionID
        let signalingPort = try hostSignaling.startListening(port: 0)
        try await clientSignaling.connect(host: "in-process", port: signalingPort)

        try await hostWebRTC.prepareSession(id: sessionID, role: .host)
        try await clientWebRTC.prepareSession(id: sessionID, role: .client)
        hostWebRTC.configureControlChannelAuth(sessionTokenHex: sessionTokenHex)
        clientWebRTC.configureControlChannelAuth(sessionTokenHex: sessionTokenHex)

        let display = try await hostDisplayProvider.currentDisplayLayout().displays.first
        if let display {
            try await hostEncoder.configure(for: display, qualityPreset: qualityPreset, codec: .h264)
        } else {
            XCTFail("No display available for integration harness")
        }
        try await hostEncoder.startEncoding()
        try await hostCapture.startCapture(displayID: displayLayout.primaryDisplayID ?? "main", qualityPreset: qualityPreset)
        hostStreamingCoordinator.startCoordinating()
        hostInputRouter.startListening(sessionID: sessionID, expectedSessionTokenHex: sessionTokenHex)
        try await waitForStage("host input router subscription") {
            self.hostWebRTC.dataMessageSubscriberCount >= 1
        }

        hostBridge.start(
            sessionID: sessionID,
            role: .host,
            localPeer: SignalingPeer(id: hostIdentity.id, role: .host, displayName: hostIdentity.displayName)
        )
        clientBridge.start(
            sessionID: sessionID,
            role: .client,
            localPeer: SignalingPeer(id: clientIdentity.id, role: .client, displayName: clientIdentity.displayName)
        )
        try await clientBridge.sendOffer(sessionID: sessionID, qualityPreset: qualityPreset, displayID: nil)

        try await waitForStage("host WebRTC connected") {
            self.hostWebRTC.connectionState == .connected
        }
        try await waitForStage("client WebRTC connected") {
            self.clientWebRTC.connectionState == .connected
        }
        try await waitForStage("streaming bridge active") {
            await MainActor.run {
                self.streamingPhase == .bridgeActive
            }
        }
        try await waitForStage("host input router enabled") {
            self.hostInputRouter.isEnabled
        }

        try clientWebRTC.sendDataMessage(
            try DataChannelEnvelope.controlAuth(
                ControlChannelAuthMessage(sessionID: sessionID, sessionToken: sessionTokenHex)
            )
        )
        try await waitForStage("host control auth established") {
            self.hostInputRouter.commandsRejected == 0
        }
    }

    func emitVideoFrame(sequenceNumber: UInt64 = 1) async throws {
        traceRecorder.record("harness.emitVideoFrame.\(sequenceNumber)")
        await hostEncoder.emitFrame(sequenceNumber: sequenceNumber)
        try await waitForStage("client received frame \(sequenceNumber)") {
            self.clientWebRTC.streamDiagnostics.framesReceived >= sequenceNumber
        }
    }

    func sendInputCommand(_ command: InputCommand) async throws {
        guard let sessionID = activeSessionID else {
            XCTFail("Client session ID missing before sending input")
            return
        }
        traceRecorder.record("harness.sendInputCommand")
        try await clientWebRTC.sendInputCommand(InputCommandMessage(sessionID: sessionID, command: command))
        try await waitForStage("host transport received input envelope") {
            self.hostWebRTC.inputMessagesDelivered >= 1
        }
    }

    func simulateDisconnect() {
        hostWebRTC.simulateDisconnect()
    }

    func simulateReconnect() {
        hostWebRTC.simulateReconnect()
    }

    func stop() async {
        traceRecorder.record("harness.stop")
        clientBridge.stop()
        hostBridge.stop()
        hostInputRouter.stopListening()
        hostStreamingCoordinator.stopCoordinating()
        await clientWebRTC.closeSession()
        await hostWebRTC.closeSession()
        await hostCapture.stopCapture()
        await hostEncoder.stopEncoding()
        clientSignaling.disconnect()
        hostSignaling.stopListening()
        activeSessionID = nil
    }

    private func waitForStage(
        _ stage: String,
        timeout: TimeInterval = 3.0,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        do {
            try await waitUntilAsync(timeout: timeout, condition: condition)
            traceRecorder.record("stage.ok.\(stage)")
        } catch {
            let trace = debugTrace()
            XCTFail("Stage failed: \(stage)\n\(trace)")
            throw NSError(
                domain: "InProcessPipelineHarness",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Stage failed: \(stage)\n\(trace)"]
            )
        }
    }
}

extension XCTestCase {
    func waitUntil(
        timeout: TimeInterval,
        pollInterval: UInt64 = 20_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        try await waitUntilAsync(timeout: timeout, pollInterval: pollInterval, condition: condition)
    }
}
