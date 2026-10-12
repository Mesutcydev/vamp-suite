import XCTest
@testable import ClientiOS
@testable import Discovery
@testable import HostApp
@testable import InputControl
@testable import Permissions
@testable import SharedModels
@testable import SharedProtocol
import SharedUtilities
@testable import TransportWebRTC

final class SignedSignalingRejectionTests: XCTestCase {

    func testRejectsUnsignedSignalingMessageWhenEnforced() {
        let service = BonjourSignalingService()
        service.enforceSignedMessages = true

        let sender = SignalingPeer(
            id: UUID(),
            role: .client,
            displayName: "Unsigned Client",
            publicKeyFingerprint: "deadbeef"
        )
        let message = VersionedSignalingMessage(
            envelope: SignalingEnvelope(
                protocolVersion: 1,
                sessionID: UUID(),
                sender: sender,
                event: .hostBusy(HostBusyMessage(hostID: UUID()))
            )
        )

        XCTAssertFalse(service.verifySignalingMessage(message))
    }

    func testRejectsSignedMessageWhenFingerprintDoesNotMatchKey() throws {
        let service = BonjourSignalingService()
        service.enforceSignedMessages = true

        let signer = CryptoIdentityService(tag: "com.remotedesktop.tests.signer.\(UUID().uuidString)")
        defer { signer.deleteKeyPair() }

        let sender = SignalingPeer(
            id: UUID(),
            role: .client,
            displayName: "Mismatched Client",
            publicKeyFingerprint: "0000badfingerprint"
        )

        var message = VersionedSignalingMessage(
            envelope: SignalingEnvelope(
                protocolVersion: 1,
                sessionID: UUID(),
                sender: sender,
                event: .hostBusy(HostBusyMessage(hostID: UUID()))
            )
        )
        message.senderPublicKey = signer.publicKeyData
        message.signature = try signer.sign(try message.unsignedPayloadData())

        XCTAssertFalse(service.verifySignalingMessage(message))
    }
}

@MainActor
final class ControlChannelAuthEnforcementTests: XCTestCase {

    func testInputRejectedBeforeControlAuthHandshake() async throws {
        let sessionManager = ControlAuthTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeProvider = HostSessionModeController(mode: .fullControl)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeProvider
        )

        let sessionID = UUID()
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)

        let input = InputCommandMessage(
            sessionID: sessionID,
            command: .text(TextInputCommand(text: "blocked-before-auth"))
        )
        let envelope = try DataChannelEnvelope.inputCommand(input)
            .authenticated(using: token, counter: 1)
        XCTAssertNotNil(envelope)

        try sessionManager.emit(envelope!)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(inputService.snapshotCommands().isEmpty)
        XCTAssertGreaterThanOrEqual(router.commandsRejected, 1)
        router.stopListening()
    }

    func testInputAcceptedAfterControlAuthHandshake() async throws {
        let sessionManager = ControlAuthTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeProvider = HostSessionModeController(mode: .fullControl)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeProvider
        )

        let sessionID = UUID()
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)

        let handshake = try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        )
        try sessionManager.emit(handshake)

        let input = InputCommandMessage(
            sessionID: sessionID,
            command: .text(TextInputCommand(text: "allowed-after-auth"))
        )
        let envelope = try DataChannelEnvelope.inputCommand(input)
            .authenticated(using: token, counter: 1)
        XCTAssertNotNil(envelope)

        try sessionManager.emit(envelope!)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(inputService.snapshotCommands().count, 1)
        router.stopListening()
    }

    func testApplicationListReachesHandlerAfterAuth() async throws {
        let sessionManager = ControlAuthTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeProvider = HostSessionModeController(mode: .fullControl)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeProvider
        )

        let sessionID = UUID()
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())

        let reached = expectation(description: "applicationList reached handler")
        router.onApplicationListRequest = { _ in reached.fulfill() }

        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        try sessionManager.emit(try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ))

        let req = ApplicationListRequestMessage(sessionID: sessionID, senderDeviceID: UUID())
        let envelope = try XCTUnwrap(
            try DataChannelEnvelope.applicationListRequest(req).authenticated(using: token, counter: 1)
        )
        try sessionManager.emit(envelope)

        await fulfillment(of: [reached], timeout: 1.0)
        XCTAssertEqual(router.commandsRejected, 0, "applicationList should not be rejected after valid auth")
        router.stopListening()
    }

    func testImmediateApplicationListReachesViewOnlyHostOverBroadcastTransport() async throws {
        // Use the production broadcast stream: unlike ControlAuthTestSessionManager,
        // it drops packets received before a subscriber is registered.
        let provider = MockPeerConnectionProvider()
        let sessionManager = WebRTCSessionManager(peerConnectionProvider: provider)
        let sessionID = UUID()
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        try await sessionManager.prepareSession(id: sessionID, role: .client)
        let connection = try XCTUnwrap(provider.lastCreatedConnection)
        let channel = MockDataChannel(label: DataChannelConfiguration.controlChannel.label)
        connection.simulateDataChannelOpened(channel)
        connection.simulateConnectionStateChange(.connected)

        let router = HostInputCommandRouter(
            inputService: RecordingInputInjectionService(),
            webRTCSessionManager: sessionManager,
            eventLogStore: RecordingEventLogStore(),
            modeProvider: HostSessionModeController(mode: .viewOnly)
        )
        defer { router.stopListening() }
        let reached = expectation(description: "immediate application list reached View Only host")
        router.onApplicationListRequest = { _ in reached.fulfill() }

        let handshake = try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ).wireEncode()
        let request = ApplicationListRequestMessage(sessionID: sessionID, senderDeviceID: UUID())
        let requestData = try XCTUnwrap(
            try DataChannelEnvelope.applicationListRequest(request).authenticated(using: token, counter: 1)
        ).wireEncode()
        router.onSessionStarted = { _ in
            channel.simulateReceive(handshake)
            channel.simulateReceive(requestData)
        }

        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        await fulfillment(of: [reached], timeout: 1.0)
        XCTAssertEqual(router.commandsRejected, 0)
        await sessionManager.closeSession()
    }

    func testApplicationListArrivingDuringConnectionAnswerIsNotLost() async throws {
        let services = PlaceholderHostServices()
        let eventLog = RecordingEventLogStore()
        let provider = MockPeerConnectionProvider()
        let sessionManager = WebRTCSessionManager(peerConnectionProvider: provider)
        let mode = HostSessionModeController(mode: .viewOnly)
        let router = HostInputCommandRouter(
            inputService: RecordingInputInjectionService(), webRTCSessionManager: sessionManager,
            eventLogStore: eventLog, modeProvider: mode
        )
        let host = HostIdentity(displayName: "Test Host", modelName: "Mac", osVersion: "macOS", appVersion: "1", publicKeyFingerprint: String(repeating: "b", count: 64))
        let clientID = UUID()
        let clientName = "Test Stream"
        let fingerprint = String(repeating: "a", count: 64)
        let clientPeer = SignalingPeer(id: clientID, role: .client, displayName: clientName, publicKeyFingerprint: fingerprint)
        let hostSignaling = InProcessSessionSignaling(role: .host, peerID: host.id, displayName: host.displayName)
        let clientSignaling = InProcessSessionSignaling(role: .client, peerID: clientID, displayName: clientName)
        let trustDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: trustDirectory) }
        let trustStore = PersistentTrustedPeerStore(directory: trustDirectory)
        try await trustStore.trustPeer(TrustedPeer(id: clientID, displayName: clientName, fingerprint: fingerprint))
        let coordinator = HostSessionCoordinator(
            hostIdentity: host, captureEngine: services, encoderPipeline: services,
            displayLayoutProvider: services, permissionService: services,
            webRTCSessionManager: sessionManager, peerTrustGate: PeerTrustGate(store: trustStore),
            streamingCoordinator: HostStreamingCoordinator(
                encoderPipeline: services, webRTCSessionManager: sessionManager,
                eventLogStore: eventLog, recordingService: SessionRecordingService()
            ),
            inputCommandRouter: router, eventLogStore: eventLog, signalingService: hostSignaling,
            sessionModeController: mode, performanceStateController: HostPerformanceStateController(),
            fileTransferManager: HostFileTransferManager(
                settings: HostFileTransferSettingsStore(supportsDefaultDownloadsLocation: false),
                store: HostFileTransferStore()
            ),
            productMode: .mini, runtimePolicy: MacHostRuntimePolicy(isSandboxedDistribution: true)
        )
        let sessionID = UUID()
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        let handshake = try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ).wireEncode()
        let request = ApplicationListRequestMessage(sessionID: sessionID, senderDeviceID: clientID)
        let requestData = try XCTUnwrap(
            try DataChannelEnvelope.applicationListRequest(request).authenticated(using: token, counter: 1)
        ).wireEncode()
        let reached = expectation(description: "application list delivered while connection answer is sent")
        router.onApplicationListRequest = { _ in reached.fulfill() }
        // A fast client can open the data connection and authenticate before sendAnswer returns.
        hostSignaling.traceHandler = { event in
            guard event == "signaling.send.host.answer",
                  let connection = provider.lastCreatedConnection,
                  let channel = connection.dataChannels[DataChannelConfiguration.controlChannel.label] else { return }
            connection.simulateConnectionStateChange(.connected)
            channel.simulateReceive(handshake)
            channel.simulateReceive(requestData)
        }

        await coordinator.startSession()
        try await clientSignaling.connect(host: "localhost", port: RemoteDesktopConstants.defaultSignalingPort)
        let offer = SessionOfferMessage(
            sessionID: sessionID, sdp: "test-offer", qualityPreset: .balanced,
            sessionToken: token, clientCapabilities: .currentClient(isMacClient: false)
        )
        try await clientSignaling.send(VersionedSignalingMessage(envelope: SignalingEnvelope(
            protocolVersion: 1, sessionID: sessionID, sender: clientPeer, event: .offer(offer)
        )))
        await fulfillment(of: [reached], timeout: 1.0)
        XCTAssertEqual(router.commandsRejected, 0)
        await coordinator.stopSession()
        clientSignaling.disconnect()
    }

    func testStreamInventoryRetryRecoversAfterLostInitialAuthentication() async throws {
        let sessionID = UUID()
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        let hostProvider = MockPeerConnectionProvider()
        let hostTransport = WebRTCSessionManager(peerConnectionProvider: hostProvider)
        try await hostTransport.prepareSession(id: sessionID, role: .host)
        let hostConnection = try XCTUnwrap(hostProvider.lastCreatedConnection)
        let hostChannel = try XCTUnwrap(hostConnection.dataChannels[DataChannelConfiguration.controlChannel.label])
        hostConnection.simulateConnectionStateChange(.connected)

        let clientProvider = MockPeerConnectionProvider()
        let clientTransport = WebRTCSessionManager(peerConnectionProvider: clientProvider)
        try await clientTransport.prepareSession(id: sessionID, role: .host)
        clientTransport.configureControlChannelAuth(sessionTokenHex: token)
        let clientChannel = try XCTUnwrap(clientProvider.lastCreatedConnection?.dataChannels[DataChannelConfiguration.controlChannel.label])
        // Reproduce an older host dropping the one-shot handshake before it subscribes.
        hostChannel.simulateReceive(try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ).wireEncode())

        let router = HostInputCommandRouter(
            inputService: RecordingInputInjectionService(), webRTCSessionManager: hostTransport,
            eventLogStore: RecordingEventLogStore(), modeProvider: HostSessionModeController(mode: .viewOnly)
        )
        defer { router.stopListening() }
        let reached = expectation(description: "Stream retry authenticates and loads the app list")
        router.onApplicationListRequest = { _ in reached.fulfill() }
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        try AppStreamViewModel.sendApplicationListRequest(
            ApplicationListRequestMessage(sessionID: sessionID, senderDeviceID: UUID()),
            sessionTokenHex: token, over: clientTransport
        )
        for packet in clientChannel.sentData { hostChannel.simulateReceive(packet) }

        await fulfillment(of: [reached], timeout: 1.0)
        XCTAssertEqual(router.commandsRejected, 0)
        await clientTransport.closeSession()
        await hostTransport.closeSession()
    }

    func testApplicationCloseReachesHandlerAfterAuth() async throws {
        let sessionManager = ControlAuthTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeProvider = HostSessionModeController(mode: .fullControl)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeProvider
        )

        let sessionID = UUID()
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())

        let reached = expectation(description: "applicationClose reached handler")
        router.onApplicationCloseRequest = { _ in reached.fulfill() }

        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        try sessionManager.emit(try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ))

        let req = ApplicationCloseRequestMessage(
            sessionID: sessionID,
            bundleIdentifier: "com.apple.Safari",
            senderDeviceID: UUID()
        )
        let envelope = try XCTUnwrap(
            try DataChannelEnvelope.applicationCloseRequest(req).authenticated(using: token, counter: 1)
        )
        try sessionManager.emit(envelope)

        await fulfillment(of: [reached], timeout: 1.0)
        XCTAssertEqual(router.commandsRejected, 0, "applicationClose should not be rejected after valid auth")
        router.stopListening()
    }

    func testTerminalOnlyHostRejectsRemoteInputAfterAuthentication() async throws {
        let sessionManager = ControlAuthTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeProvider = HostSessionModeController(mode: .fullControl)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeProvider
        )

        let sessionID = UUID()
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        router.startListening(
            sessionID: sessionID,
            expectedSessionTokenHex: token,
            terminalOnly: true
        )

        try sessionManager.emit(try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ))
        let input = InputCommandMessage(
            sessionID: sessionID,
            command: .text(TextInputCommand(text: "must-not-reach-input-service"))
        )
        let envelope = try DataChannelEnvelope.inputCommand(input)
            .authenticated(using: token, counter: 1)
        try sessionManager.emit(try XCTUnwrap(envelope))
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(inputService.snapshotCommands().isEmpty)
        XCTAssertGreaterThanOrEqual(router.commandsRejected, 1)
        router.stopListening()
    }

    func testRejectsCounterReplayAfterSuccessfulAuth() async throws {
        let sessionManager = ControlAuthTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeProvider = HostSessionModeController(mode: .fullControl)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeProvider
        )

        let sessionID = UUID()
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)

        let handshake = try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        )
        try sessionManager.emit(handshake)

        let input = InputCommandMessage(
            sessionID: sessionID,
            command: .text(TextInputCommand(text: "replay-check"))
        )
        let first = try DataChannelEnvelope.inputCommand(input)
            .authenticated(using: token, counter: 1)
        XCTAssertNotNil(first)
        try sessionManager.emit(first!)

        // Re-send exact same envelope (same counter + MAC)
        try sessionManager.emit(first!)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(inputService.snapshotCommands().count, 1)
        XCTAssertGreaterThanOrEqual(router.commandsRejected, 1)
        router.stopListening()
    }

    func testRepeatedHandshakeCannotResetAcceptedCounter() async throws {
        let sessionManager = ControlAuthTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeProvider = HostSessionModeController(mode: .fullControl)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeProvider
        )

        let sessionID = UUID()
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)

        let handshake = try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        )
        try sessionManager.emit(handshake)

        let accepted = try DataChannelEnvelope.inputCommand(
            InputCommandMessage(sessionID: sessionID, command: .text(TextInputCommand(text: "counter-two")))
        ).authenticated(using: token, counter: 2)
        try sessionManager.emit(accepted!)

        // A captured handshake must not move the receive window backwards.
        try sessionManager.emit(handshake)
        let stale = try DataChannelEnvelope.inputCommand(
            InputCommandMessage(sessionID: sessionID, command: .text(TextInputCommand(text: "stale-counter-one")))
        ).authenticated(using: token, counter: 1)
        try sessionManager.emit(stale!)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(inputService.snapshotCommands().count, 1)
        router.stopListening()
    }

    func testRejectsTamperedMACEnvelope() async throws {
        let sessionManager = ControlAuthTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeProvider = HostSessionModeController(mode: .fullControl)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeProvider
        )

        let sessionID = UUID()
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)

        let handshake = try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        )
        try sessionManager.emit(handshake)

        let input = InputCommandMessage(
            sessionID: sessionID,
            command: .text(TextInputCommand(text: "tamper-check"))
        )
        var envelope = try XCTUnwrap(
            try DataChannelEnvelope.inputCommand(input)
                .authenticated(using: token, counter: 2)
        )

        // Tamper payload after MAC creation; verification must fail.
        envelope.payload.append(0xFF)
        try sessionManager.emit(envelope)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(inputService.snapshotCommands().isEmpty)
        XCTAssertGreaterThanOrEqual(router.commandsRejected, 1)
        router.stopListening()
    }
}

private final class ControlAuthTestSessionManager: WebRTCSessionManaging, @unchecked Sendable {
    var connectionState: ConnectionState = .connected
    var peerConnectionState: PeerConnectionState = .connected
    var dataChannelState: DataChannelState = .open
    var mediaChannelReadiness: MediaChannelReadiness = MediaChannelReadiness(dataChannelState: .open, videoTrackAttached: true, audioTrackAttached: false)
    var streamDiagnostics: StreamDiagnostics = StreamDiagnostics()
    var videoFrameSubscriberCount: Int = 0

    private let lock = NSLock()
    private var dataContinuation: AsyncStream<DataChannelEnvelope>.Continuation?
    private var pendingEnvelopes: [DataChannelEnvelope] = []

    func prepareSession(id: UUID, role: WebRTCSessionRole) async throws {}
    func createOffer(sessionID: UUID, qualityPreset: StreamQualityPreset, displayID: String?) async throws -> SessionOfferMessage {
        SessionOfferMessage(sessionID: sessionID, sdp: "", qualityPreset: qualityPreset)
    }
    func applyRemoteOffer(_ message: SessionOfferMessage) async throws -> SessionAnswerMessage {
        SessionAnswerMessage(sessionID: message.sessionID, sdp: "")
    }
    func applyRemoteAnswer(_ message: SessionAnswerMessage) async throws {}
    func addRemoteCandidate(_ message: ICECandidateMessage) async throws {}
    func closeSession() async {}
    func sendInputCommand(_ message: InputCommandMessage) async throws {}
    func sendDataMessage(_ message: DataChannelEnvelope) throws {}
    func configureControlChannelAuth(sessionTokenHex: String?) {}
    func receiveDataMessages() -> AsyncStream<DataChannelEnvelope> {
        AsyncStream { continuation in
            let pending: [DataChannelEnvelope]
            lock.lock()
            dataContinuation = continuation
            pending = pendingEnvelopes
            pendingEnvelopes.removeAll()
            lock.unlock()
            pending.forEach { continuation.yield($0) }
        }
    }
    func localICECandidates() -> AsyncStream<ICECandidateMessage> {
        AsyncStream { continuation in continuation.finish() }
    }
    func attachVideoSource(_ source: (any VideoFrameSource)?) {}
    func sendVideoFrame(_ frame: VideoFrameData) throws {}
    func receivedVideoFrames() -> AsyncStream<VideoFrameData> {
        AsyncStream { continuation in continuation.finish() }
    }
    func connectionStateUpdates() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in continuation.yield(.connected) }
    }

    func dataChannelStateUpdates() -> AsyncStream<DataChannelState> {
        AsyncStream { continuation in continuation.yield(.open) }
    }

    func videoChannelStateUpdates() -> AsyncStream<DataChannelState> {
        AsyncStream { continuation in continuation.finish() }
    }

    func emit(_ envelope: DataChannelEnvelope) throws {
        lock.lock()
        let continuation = dataContinuation
        if continuation == nil {
            pendingEnvelopes.append(envelope)
        }
        lock.unlock()
        continuation?.yield(envelope)
    }
}
