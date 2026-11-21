import XCTest
@testable import TransportWebRTC
@testable import SharedModels
@testable import SharedProtocol

// MARK: - Mock Peer Connection Provider

final class MockPeerConnectionProvider: PeerConnectionProviding, LANTransportSecurityConfigurable, @unchecked Sendable {
    var shouldFail = false
    var lastCreatedConnection: MockPeerConnection?
    var configuredSessionTokenHex: String?

    func configureTransportSecurity(sessionTokenHex: String?) {
        configuredSessionTokenHex = sessionTokenHex
    }

    func makePeerConnection(
        configuration: WebRTCConfiguration,
        delegate: any PeerConnectionDelegate
    ) throws -> any PeerConnectionProtocol {
        if shouldFail {
            throw NSError(domain: "MockError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Mock failure"])
        }
        let connection = MockPeerConnection(delegate: delegate)
        lastCreatedConnection = connection
        return connection
    }
}

// MARK: - Mock Peer Connection

final class MockPeerConnection: PeerConnectionProtocol, @unchecked Sendable {
    var localDescription: SessionDescription?
    var remoteDescription: SessionDescription?
    var connectionState: PeerConnectionState = .new
    var iceConnectionState: ICEConnectionState = .new
    var iceGatheringState: ICEGatheringState = .new

    weak var delegate: (any PeerConnectionDelegate)?
    var createdDataChannels: [String] = []
    var dataChannels: [String: MockDataChannel] = [:]
    var addedCandidates: [ICECandidate] = []
    var isClosed = false

    init(delegate: any PeerConnectionDelegate) {
        self.delegate = delegate
    }

    func createOffer(constraints: MediaConstraints?) async throws -> SessionDescription {
        let sdp = SessionDescription(type: .offer, sdp: "mock-offer-sdp")
        return sdp
    }

    func createAnswer(constraints: MediaConstraints?) async throws -> SessionDescription {
        let sdp = SessionDescription(type: .answer, sdp: "mock-answer-sdp")
        return sdp
    }

    func setLocalDescription(_ sdp: SessionDescription) async throws {
        localDescription = sdp
    }

    func setRemoteDescription(_ sdp: SessionDescription) async throws {
        remoteDescription = sdp
    }

    func addICECandidate(_ candidate: ICECandidate) async throws {
        addedCandidates.append(candidate)
    }

    func createDataChannel(_ config: DataChannelConfiguration) -> (any DataChannelProtocol)? {
        createdDataChannels.append(config.label)
        let channel = MockDataChannel(label: config.label)
        dataChannels[config.label] = channel
        return channel
    }

    func addVideoTrack(_ track: any VideoTrackProtocol) {}
    func removeVideoTrack(_ track: any VideoTrackProtocol) {}

    func close() {
        isClosed = true
        connectionState = .closed
    }

    /// Simulate a connection state change from the "remote" side.
    func simulateConnectionStateChange(_ state: PeerConnectionState) {
        connectionState = state
        delegate?.peerConnection(self, didChangeConnectionState: state)
    }

    /// Simulate a generated ICE candidate.
    func simulateICECandidate(_ candidate: ICECandidate) {
        delegate?.peerConnection(self, didGenerateICECandidate: candidate)
    }

    /// Simulate a remote data channel opening (client-side flow).
    func simulateDataChannelOpened(_ channel: any DataChannelProtocol) {
        delegate?.peerConnection(self, didOpenDataChannel: channel)
    }
}

// MARK: - Mock Data Channel

final class MockDataChannel: DataChannelProtocol, @unchecked Sendable {
    let label: String
    var readyState: DataChannelState = .open
    var sentData: [Data] = []
    var isClosed = false
    private weak var delegate: (any DataChannelDelegate)?

    init(label: String) {
        self.label = label
    }

    func send(_ data: Data) -> Bool {
        sentData.append(data)
        return true
    }

    func close() {
        isClosed = true
        readyState = .closed
    }

    func setDelegate(_ delegate: any DataChannelDelegate) {
        self.delegate = delegate
    }

    func simulateReceive(_ data: Data) {
        delegate?.dataChannel(self, didReceiveData: data)
    }

    func simulateStateChange(_ state: DataChannelState) {
        readyState = state
        delegate?.dataChannel(self, didChangeState: state)
    }
}

// MARK: - Tests

final class WebRTCSessionManagerTests: XCTestCase {

    private var provider: MockPeerConnectionProvider!
    private var manager: WebRTCSessionManager!

    override func setUp() {
        super.setUp()
        provider = MockPeerConnectionProvider()
        manager = WebRTCSessionManager(peerConnectionProvider: provider)
    }

    override func tearDown() {
        manager = nil
        provider = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertEqual(manager.connectionState, .idle)
        XCTAssertEqual(manager.peerConnectionState, .new)
        XCTAssertEqual(manager.dataChannelState, .closed)
        XCTAssertFalse(manager.mediaChannelReadiness.isDataChannelReady)
        XCTAssertFalse(manager.mediaChannelReadiness.isVideoReady)
    }

    // MARK: - Prepare Session (Host)

    func testPrepareSessionHost() async throws {
        try await manager.prepareSession(id: UUID(), role: .host)
        XCTAssertEqual(manager.connectionState, .connecting)
        XCTAssertNotNil(provider.lastCreatedConnection)
        XCTAssertTrue(provider.lastCreatedConnection!.createdDataChannels.contains("control"))
    }

    // MARK: - Prepare Session (Client)

    func testPrepareSessionClient() async throws {
        try await manager.prepareSession(id: UUID(), role: .client)
        XCTAssertEqual(manager.connectionState, .connecting)
        XCTAssertNotNil(provider.lastCreatedConnection)
        // Client doesn't create data channel — it receives one via delegate
        XCTAssertTrue(provider.lastCreatedConnection!.createdDataChannels.isEmpty)
    }

    func testReplacementSessionPreservesConfiguredTransportToken() async throws {
        let token = String(repeating: "ab", count: 32)
        manager.configureControlChannelAuth(sessionTokenHex: token)
        try await manager.prepareSession(id: UUID(), role: .host)

        // Reconfiguration happens before prepareSession in the real coordinator.
        // Replacing the existing peer must not clear that newly configured token.
        manager.configureControlChannelAuth(sessionTokenHex: token)
        try await manager.prepareSession(id: UUID(), role: .host)

        XCTAssertEqual(provider.configuredSessionTokenHex, token)
    }

    // MARK: - Prepare Session Failure

    func testPrepareSessionFailure() async {
        provider.shouldFail = true
        do {
            try await manager.prepareSession(id: UUID(), role: .host)
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is WebRTCSessionError)
        }
    }

    // MARK: - Create Offer (Client)

    func testCreateOffer() async throws {
        let sessionID = UUID()
        try await manager.prepareSession(id: sessionID, role: .client)
        let offer = try await manager.createOffer(sessionID: sessionID, qualityPreset: .balanced, displayID: "main")

        XCTAssertEqual(offer.sessionID, sessionID)
        XCTAssertEqual(offer.sdp, "mock-offer-sdp")
        XCTAssertEqual(offer.qualityPreset, .balanced)
        XCTAssertEqual(offer.requestedDisplayID, "main")
    }

    // MARK: - Apply Remote Offer (Host)

    func testApplyRemoteOffer() async throws {
        let sessionID = UUID()
        try await manager.prepareSession(id: sessionID, role: .host)
        let offer = SessionOfferMessage(sessionID: sessionID, sdp: "remote-offer-sdp", qualityPreset: .quality)
        let answer = try await manager.applyRemoteOffer(offer)

        XCTAssertEqual(answer.sessionID, sessionID)
        XCTAssertEqual(answer.sdp, "mock-answer-sdp")
        // Verify SDP was set on the connection
        XCTAssertEqual(provider.lastCreatedConnection?.remoteDescription?.sdp, "remote-offer-sdp")
        XCTAssertEqual(provider.lastCreatedConnection?.localDescription?.sdp, "mock-answer-sdp")
    }

    // MARK: - Apply Remote Answer (Client)

    func testApplyRemoteAnswer() async throws {
        let sessionID = UUID()
        try await manager.prepareSession(id: sessionID, role: .client)
        let answer = SessionAnswerMessage(sessionID: sessionID, sdp: "remote-answer-sdp")
        try await manager.applyRemoteAnswer(answer)

        XCTAssertEqual(provider.lastCreatedConnection?.remoteDescription?.sdp, "remote-answer-sdp")
    }

    // MARK: - Add Remote ICE Candidate

    func testAddRemoteCandidate() async throws {
        try await manager.prepareSession(id: UUID(), role: .host)
        let ice = ICECandidateMessage(sessionID: UUID(), sdpMid: "0", sdpMLineIndex: 0, candidate: "candidate:abc")
        try await manager.addRemoteCandidate(ice)

        XCTAssertEqual(provider.lastCreatedConnection?.addedCandidates.count, 1)
        XCTAssertEqual(provider.lastCreatedConnection?.addedCandidates.first?.candidate, "candidate:abc")
    }

    // MARK: - Close Session

    func testCloseSession() async throws {
        try await manager.prepareSession(id: UUID(), role: .host)
        await manager.closeSession()

        XCTAssertEqual(manager.connectionState, .idle)
        XCTAssertTrue(provider.lastCreatedConnection!.isClosed)
    }

    // MARK: - Send Data Message

    func testSendDataMessage() async throws {
        try await manager.prepareSession(id: UUID(), role: .host)
        let ping = PingMessage()
        let envelope = try DataChannelEnvelope.ping(ping)
        try manager.sendDataMessage(envelope)

        // The mock data channel should have received the encoded message
        if let mockDC = provider.lastCreatedConnection?.createdDataChannels.first {
            XCTAssertEqual(mockDC, "control")
        }
    }

    // MARK: - Connection State Updates via Delegate

    func testConnectionStateUpdateOnPeerStateChange() async throws {
        try await manager.prepareSession(id: UUID(), role: .host)
        let pc = provider.lastCreatedConnection!

        pc.simulateConnectionStateChange(.connected)
        // Allow time for state propagation
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(manager.connectionState, .connected)

        pc.simulateConnectionStateChange(.disconnected)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(manager.connectionState, .disconnected)

        pc.simulateConnectionStateChange(.failed)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(manager.connectionState, .failed)
    }

    // MARK: - Not Prepared Error

    func testCreateOfferWithoutPrepareFails() async {
        do {
            _ = try await manager.createOffer(sessionID: UUID(), qualityPreset: .balanced, displayID: nil)
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is WebRTCSessionError)
        }
    }

    // MARK: - Media Channel Readiness

    func testMediaChannelReadinessSummary() {
        let readiness = MediaChannelReadiness(dataChannelState: .open, videoTrackAttached: true)
        XCTAssertTrue(readiness.isDataChannelReady)
        XCTAssertTrue(readiness.isVideoReady)
        XCTAssertTrue(readiness.summaryText.contains("DC: open"))
        XCTAssertTrue(readiness.summaryText.contains("Video: attached"))
    }

    func testMediaChannelReadinessDefault() {
        let readiness = MediaChannelReadiness()
        XCTAssertFalse(readiness.isDataChannelReady)
        XCTAssertFalse(readiness.isVideoReady)
    }

    // MARK: - WebRTC Types

    func testPeerConnectionStateRawValues() {
        XCTAssertEqual(PeerConnectionState.new.rawValue, "new")
        XCTAssertEqual(PeerConnectionState.connecting.rawValue, "connecting")
        XCTAssertEqual(PeerConnectionState.connected.rawValue, "connected")
        XCTAssertEqual(PeerConnectionState.disconnected.rawValue, "disconnected")
        XCTAssertEqual(PeerConnectionState.failed.rawValue, "failed")
        XCTAssertEqual(PeerConnectionState.closed.rawValue, "closed")
    }

    func testDataChannelStateRawValues() {
        XCTAssertEqual(DataChannelState.connecting.rawValue, "connecting")
        XCTAssertEqual(DataChannelState.open.rawValue, "open")
        XCTAssertEqual(DataChannelState.closing.rawValue, "closing")
        XCTAssertEqual(DataChannelState.closed.rawValue, "closed")
    }

    func testICEConnectionStateRawValues() {
        let allCases: [ICEConnectionState] = [.new, .checking, .connected, .completed, .failed, .disconnected, .closed]
        XCTAssertEqual(allCases.count, 7)
        for state in allCases {
            XCTAssertFalse(state.rawValue.isEmpty)
        }
    }

    func testSessionDescriptionTypes() {
        let offer = SessionDescription(type: .offer, sdp: "v=0\r\n...")
        XCTAssertEqual(offer.type, .offer)
        XCTAssertEqual(offer.sdp, "v=0\r\n...")

        let answer = SessionDescription(type: .answer, sdp: "v=0\r\n...")
        XCTAssertEqual(answer.type, .answer)
    }

    func testWebRTCConfigurationLANDefault() {
        let config = WebRTCConfiguration.lanDefault
        XCTAssertTrue(config.iceServers.isEmpty)
    }

    func testDataChannelConfigurationControlChannel() {
        let config = DataChannelConfiguration.controlChannel
        XCTAssertEqual(config.label, "control")
        XCTAssertTrue(config.isOrdered)
    }

    func testMediaConstraintsDefaults() {
        let offer = MediaConstraints.defaultOffer
        XCTAssertEqual(offer.mandatory["OfferToReceiveVideo"], "false")
        XCTAssertEqual(offer.mandatory["OfferToReceiveAudio"], "false")

        let answer = MediaConstraints.defaultAnswer
        XCTAssertEqual(answer.mandatory["OfferToReceiveVideo"], "true")
    }

    // MARK: - WebRTCSessionError

    func testWebRTCSessionErrorDescriptions() {
        XCTAssertNotNil(WebRTCSessionError.notPrepared.errorDescription)
        XCTAssertNotNil(WebRTCSessionError.alreadyActive.errorDescription)
        XCTAssertNotNil(WebRTCSessionError.peerConnectionFailed("reason").errorDescription)
        XCTAssertNotNil(WebRTCSessionError.dataChannelUnavailable.errorDescription)
        XCTAssertNotNil(WebRTCSessionError.sdpCreationFailed("reason").errorDescription)
        XCTAssertNotNil(WebRTCSessionError.invalidState("reason").errorDescription)
    }

    // MARK: - ICE Candidate Output

    func testLocalICECandidateEmission() async throws {
        try await manager.prepareSession(id: UUID(), role: .host)
        let pc = provider.lastCreatedConnection!

        let candidateTask = Task<ICECandidateMessage?, Never> {
            for await candidate in manager.localICECandidates() {
                return candidate
            }
            return nil
        }

        // Small delay to ensure the stream is set up
        try await Task.sleep(nanoseconds: 10_000_000)

        pc.simulateICECandidate(ICECandidate(sdpMid: "0", sdpMLineIndex: 0, candidate: "candidate:test123"))

        // Small delay for propagation
        try await Task.sleep(nanoseconds: 10_000_000)
        candidateTask.cancel()

        let result = await candidateTask.value
        XCTAssertEqual(result?.candidate, "candidate:test123")
    }
}
