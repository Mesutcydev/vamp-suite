import CryptoKit
import XCTest
@testable import ClientiOS
@testable import Discovery
@testable import HostApp
@testable import Permissions
@testable import SharedModels
@testable import SharedProtocol
import SharedUtilities
@testable import TransportWebRTC

// MARK: - Signed host key bundle

final class SignedHostKeyBundleTests: XCTestCase {
    private let nonce = Data((0..<32).map { UInt8($0) })

    private func fingerprint(of key: P256.Signing.PrivateKey) -> String {
        CryptoIdentityService.fingerprint(of: Data(key.publicKey.x963Representation))
    }

    func testValidBundleVerifiesAndNamesItsSigner() throws {
        let host = P256.Signing.PrivateKey()
        let bundle = try XCTUnwrap(SessionTokenSealing.makeKeyBundle(signingKey: host, nonce: nonce))

        let verified = try XCTUnwrap(SessionTokenSealing.verifyKeyBundle(bundle, nonce: nonce))

        XCTAssertEqual(verified.fingerprint, fingerprint(of: host))
        XCTAssertEqual(
            verified.keyAgreementKey.x963Representation,
            SessionTokenSealing.deriveKeyAgreementKey(from: host).publicKey.x963Representation
        )
    }

    func testTokenSealedToVerifiedKeyOpensOnlyWithThatHostsIdentity() throws {
        let host = P256.Signing.PrivateKey()
        let bundle = try XCTUnwrap(SessionTokenSealing.makeKeyBundle(signingKey: host, nonce: nonce))
        let verified = try XCTUnwrap(SessionTokenSealing.verifyKeyBundle(bundle, nonce: nonce))
        let token = ConnectionSecurity.generateSessionToken()

        let sealed = try SessionTokenSealing.seal(token, to: verified.keyAgreementKey)

        XCTAssertEqual(SessionTokenSealing.open(sealed, with: SessionTokenSealing.deriveKeyAgreementKey(from: host)), token)
        XCTAssertNil(SessionTokenSealing.open(
            sealed,
            with: SessionTokenSealing.deriveKeyAgreementKey(from: P256.Signing.PrivateKey())
        ))
    }

    func testTamperedBundleIsRejected() throws {
        let host = P256.Signing.PrivateKey()
        let bundle = try XCTUnwrap(SessionTokenSealing.makeKeyBundle(signingKey: host, nonce: nonce))

        // The attack the bundle exists to stop: swap in a sealing key the attacker can open.
        var swappedSealingKey = bundle
        swappedSealingKey.keyAgreementPublicKey = Data(P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
        XCTAssertNil(SessionTokenSealing.verifyKeyBundle(swappedSealingKey, nonce: nonce))

        var flippedSignature = bundle
        flippedSignature.signature[flippedSignature.signature.count - 1] ^= 0x01
        XCTAssertNil(SessionTokenSealing.verifyKeyBundle(flippedSignature, nonce: nonce))

        var swappedSigner = bundle
        swappedSigner.signingPublicKey = Data(P256.Signing.PrivateKey().publicKey.x963Representation)
        XCTAssertNil(SessionTokenSealing.verifyKeyBundle(swappedSigner, nonce: nonce))

        var garbageKey = bundle
        garbageKey.keyAgreementPublicKey = Data([0x04, 0x01, 0x02])
        XCTAssertNil(SessionTokenSealing.verifyKeyBundle(garbageKey, nonce: nonce))
    }

    func testBundleSignedBySomeoneElseCannotClaimTheHostsKey() throws {
        let host = P256.Signing.PrivateKey()
        let attacker = P256.Signing.PrivateKey()
        let attackerBundle = try XCTUnwrap(SessionTokenSealing.makeKeyBundle(signingKey: attacker, nonce: nonce))

        // Attacker's signature, host's public key in the signer field.
        var forged = attackerBundle
        forged.signingPublicKey = Data(host.publicKey.x963Representation)
        XCTAssertNil(SessionTokenSealing.verifyKeyBundle(forged, nonce: nonce))

        // The attacker's own bundle is internally valid, but it names the attacker: the pin rejects it.
        let attackerVerified = try XCTUnwrap(SessionTokenSealing.verifyKeyBundle(attackerBundle, nonce: nonce))
        XCTAssertNotEqual(attackerVerified.fingerprint, fingerprint(of: host))
        XCTAssertEqual(
            HostKeyExchangePolicy.evaluate(
                reply: .verified(fingerprint: attackerVerified.fingerprint),
                trusted: TrustedHostIdentity(fingerprint: fingerprint(of: host))
            ),
            .rejected(.identityChanged)
        )
    }

    func testBundleAnswersOnlyTheNonceItWasMadeFor() throws {
        let host = P256.Signing.PrivateKey()
        let bundle = try XCTUnwrap(SessionTokenSealing.makeKeyBundle(signingKey: host, nonce: nonce))
        let otherNonce = Data(repeating: 0xAB, count: 32)

        XCTAssertNil(SessionTokenSealing.verifyKeyBundle(bundle, nonce: otherNonce))

        // Relabelling a captured bundle with the new nonce does not help: the nonce is signed.
        var relabelled = bundle
        relabelled.nonce = otherNonce
        XCTAssertNil(SessionTokenSealing.verifyKeyBundle(relabelled, nonce: otherNonce))
    }

    func testHostRefusesToSignNoncesOutsideTheAllowedLength() {
        let host = P256.Signing.PrivateKey()
        XCTAssertNil(SessionTokenSealing.makeKeyBundle(signingKey: host, nonce: Data(repeating: 1, count: 15)))
        XCTAssertNil(SessionTokenSealing.makeKeyBundle(signingKey: host, nonce: Data(repeating: 1, count: 65)))
        XCTAssertNil(SessionTokenSealing.makeKeyBundle(signingKey: host, nonce: Data()))
        XCTAssertNotNil(SessionTokenSealing.makeKeyBundle(signingKey: host, nonce: Data(repeating: 1, count: 16)))
    }

    func testSignalingServiceHandsOutABundleForItsOwnIdentity() throws {
        let identity = CryptoIdentityService(tag: "com.remotedesktop.tests.keybundle.\(UUID().uuidString)")
        defer { identity.deleteKeyPair() }
        let service = BonjourSignalingService()
        XCTAssertNil(service.makeHostKeyBundle(nonce: nonce), "No identity, no bundle")

        service.identityService = identity
        let bundle = try XCTUnwrap(service.makeHostKeyBundle(nonce: nonce))

        XCTAssertEqual(SessionTokenSealing.verifyKeyBundle(bundle, nonce: nonce)?.fingerprint, identity.fingerprint)
    }

    func testKeyExchangeEventsRoundTripAndUnknownEventsFailToDecode() throws {
        let host = P256.Signing.PrivateKey()
        let bundle = try XCTUnwrap(SessionTokenSealing.makeKeyBundle(signingKey: host, nonce: nonce))
        let coder = JSONSignalingMessageCoder()
        let sender = SignalingPeer(id: UUID(), role: .client)

        for event in [SignalingEvent.hostKeyRequest(HostKeyRequestMessage(nonce: nonce)), .hostKeyBundle(bundle)] {
            let message = VersionedSignalingMessage(envelope: SignalingEnvelope(
                protocolVersion: 1, sessionID: UUID(), sender: sender, event: event
            ))
            XCTAssertEqual(try coder.decode(try coder.encode(message)).envelope.event, event)
        }

        // What an older peer sees for these two events: an event case it has no name for. The
        // signaling loop logs the decode failure and keeps reading, which is how an updated
        // client tells an older host apart (no reply) without breaking the connection.
        let encoded = try coder.encode(VersionedSignalingMessage(envelope: SignalingEnvelope(
            protocolVersion: 1, sessionID: UUID(), sender: sender,
            event: .hostKeyRequest(HostKeyRequestMessage(nonce: nonce))
        )))
        let renamed = try XCTUnwrap(String(data: encoded, encoding: .utf8))
            .replacingOccurrences(of: "\"hostKeyRequest\"", with: "\"eventFromTheFuture\"")
        XCTAssertThrowsError(try coder.decode(Data(renamed.utf8)))
    }
}

// MARK: - Key exchange over a real signaling connection

final class SignalingKeyExchangeLoopbackTests: XCTestCase {
    /// Host and client signaling services talking over loopback TCP: the host answers a key
    /// request itself, on the connection that asked, with a bundle for its own identity, and
    /// does not pass the request on to the session coordinator's queue.
    func testHostAnswersKeyRequestOnTheSameConnection() async throws {
        let hostIdentity = CryptoIdentityService(tag: "com.remotedesktop.tests.kx.host.\(UUID().uuidString)")
        let clientIdentity = CryptoIdentityService(tag: "com.remotedesktop.tests.kx.client.\(UUID().uuidString)")
        defer { hostIdentity.deleteKeyPair(); clientIdentity.deleteKeyPair() }

        let host = BonjourSignalingService()
        host.identityService = hostIdentity
        let hostMessages = host.receiveMessages()
        let port = try host.startListening(port: 0)
        defer { host.stopListening() }

        let client = BonjourSignalingService()
        client.identityService = clientIdentity
        let clientMessages = client.receiveMessages()
        try await client.connect(host: "127.0.0.1", port: port)
        defer { client.disconnect() }

        let nonce = ConnectionSecurity.generateSessionToken()
        let sessionID = UUID()
        try await client.send(VersionedSignalingMessage(envelope: SignalingEnvelope(
            protocolVersion: 1, sessionID: sessionID,
            sender: SignalingPeer(id: UUID(), role: .client, displayName: "Test Client"),
            event: .hostKeyRequest(HostKeyRequestMessage(nonce: nonce))
        )))

        let reply = try await withTimeout(seconds: 5) { () -> VersionedSignalingMessage? in
            for try await message in clientMessages { return message }
            return nil
        }
        let message = try XCTUnwrap(reply)
        guard case .hostKeyBundle(let bundle) = message.envelope.event else {
            return XCTFail("Expected a host key bundle, got \(message.envelope.kind)")
        }
        XCTAssertEqual(message.envelope.sessionID, sessionID)
        // The envelope and the bundle are signed by the same host identity.
        XCTAssertEqual(message.envelope.sender.publicKeyFingerprint, hostIdentity.fingerprint)
        XCTAssertEqual(SessionTokenSealing.verifyKeyBundle(bundle, nonce: nonce)?.fingerprint, hostIdentity.fingerprint)

        // The request never reaches the host's coordinator queue. Send an ordinary event after
        // it: that one must be the first thing the host's consumer sees.
        try await client.send(VersionedSignalingMessage(envelope: SignalingEnvelope(
            protocolVersion: 1, sessionID: sessionID,
            sender: SignalingPeer(id: UUID(), role: .client, displayName: "Test Client"),
            event: .hostBusy(HostBusyMessage(hostID: UUID()))
        )))
        let firstForCoordinator = try await withTimeout(seconds: 5) { () -> VersionedSignalingMessage? in
            for try await message in hostMessages { return message }
            return nil
        }
        XCTAssertEqual(firstForCoordinator?.envelope.kind, .hostBusy)
    }
}

// MARK: - Key exchange on a parked connection

/// The host keeps its live signaling connection and parks a newcomer until that newcomer sends
/// a verified message. A device doing a first-contact key exchange sits parked while its user
/// compares fingerprints, so the exchange has to work there without costing it the connection.
final class ParkedConnectionKeyExchangeTests: XCTestCase {
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [VersionedSignalingMessage] = []
        func append(_ message: VersionedSignalingMessage) { lock.lock(); messages.append(message); lock.unlock() }
        var senders: [UUID] { lock.lock(); defer { lock.unlock() }; return messages.map(\.envelope.sender.id) }
    }

    private var identities: [CryptoIdentityService] = []

    override func tearDown() {
        identities.forEach { $0.deleteKeyPair() }
        identities = []
        super.tearDown()
    }

    private func makeService() -> BonjourSignalingService {
        let identity = CryptoIdentityService(tag: "com.remotedesktop.tests.parked.\(UUID().uuidString)")
        identities.append(identity)
        let service = BonjourSignalingService()
        service.identityService = identity
        return service
    }

    private func send(_ event: SignalingEvent, from service: BonjourSignalingService, as peerID: UUID) async throws {
        try await service.send(VersionedSignalingMessage(envelope: SignalingEnvelope(
            protocolVersion: 1, sessionID: nil,
            sender: SignalingPeer(id: peerID, role: .client),
            event: event
        )))
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        try await withTimeout(seconds: 5) {
            while !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
        }
    }

    /// Host with one live connection from an approved device (A) and a short parking timeout.
    private func makeHostWithLiveDevice() async throws -> (
        host: BonjourSignalingService, port: UInt16, inbox: Inbox, live: BonjourSignalingService, liveID: UUID
    ) {
        let host = makeService()
        host.parkedConnectionTimeout = 0.3
        let inbox = Inbox()
        let hostMessages = host.receiveMessages()
        Task { do { for try await message in hostMessages { inbox.append(message) } } catch {} }
        let port = try host.startListening(port: 0)

        let live = makeService()
        let liveID = UUID()
        _ = live.receiveMessages()
        try await live.connect(host: "127.0.0.1", port: port)
        try await send(.hostBusy(HostBusyMessage(hostID: UUID())), from: live, as: liveID)
        try await waitUntil { inbox.senders == [liveID] }
        // What the session coordinator does once the trust gate approves the device.
        host.noteTrustedPeer(fingerprint: try XCTUnwrap(live.identityService?.fingerprint))
        return (host, port, inbox, live, liveID)
    }

    func testParkedDeviceCompletesKeyExchangeAndSurvivesTheFingerprintPrompt() async throws {
        let setup = try await makeHostWithLiveDevice()
        defer { setup.host.stopListening(); setup.live.disconnect() }
        let hostFingerprint = try XCTUnwrap(setup.host.identityService?.fingerprint)

        let newcomer = makeService()
        let newcomerID = UUID()
        let newcomerMessages = newcomer.receiveMessages()
        try await newcomer.connect(host: "127.0.0.1", port: setup.port)
        defer { newcomer.disconnect() }

        // Parked, yet its key request is answered on its own connection.
        let nonce = ConnectionSecurity.generateSessionToken()
        try await send(.hostKeyRequest(HostKeyRequestMessage(nonce: nonce)), from: newcomer, as: newcomerID)
        let reply = try await withTimeout(seconds: 5) { () -> VersionedSignalingMessage? in
            for try await message in newcomerMessages { return message }
            return nil
        }
        guard case .hostKeyBundle(let bundle)? = reply?.envelope.event else {
            return XCTFail("The parked device did not get a key bundle")
        }
        XCTAssertEqual(SessionTokenSealing.verifyKeyBundle(bundle, nonce: nonce)?.fingerprint, hostFingerprint)

        // Asking for keys took nothing over: the live device still reaches the host.
        try await send(.hostBusy(HostBusyMessage(hostID: UUID())), from: setup.live, as: setup.liveID)
        try await waitUntil { setup.inbox.senders == [setup.liveID, setup.liveID] }

        // The user compares fingerprints for longer than the parking timeout...
        try await Task.sleep(nanoseconds: 700_000_000)

        // ...and the device is still connected when it finally sends its first real message.
        try await send(.hostBusy(HostBusyMessage(hostID: UUID())), from: newcomer, as: newcomerID)
        try await waitUntil { setup.inbox.senders.last == newcomerID }
    }

    /// Two sockets from a peer nobody has approved: one sits in the live slot (it even sends a
    /// validly signed message from its own throwaway key), the other asks for the key bundle
    /// and then idles. Neither may keep a real device from connecting.
    func testUnapprovedPeerCannotLockOutNewDevicesWithIdleSockets() async throws {
        let host = makeService()
        host.parkedConnectionTimeout = 0.3
        let inbox = Inbox()
        let hostMessages = host.receiveMessages()
        Task { do { for try await message in hostMessages { inbox.append(message) } } catch {} }
        let port = try host.startListening(port: 0)
        defer { host.stopListening() }

        let squatterID = UUID()
        let liveSquatter = makeService()
        _ = liveSquatter.receiveMessages()
        try await liveSquatter.connect(host: "127.0.0.1", port: port)
        defer { liveSquatter.disconnect() }
        try await send(.hostBusy(HostBusyMessage(hostID: UUID())), from: liveSquatter, as: squatterID)
        try await waitUntil { inbox.senders == [squatterID] }

        let parkedSquatter = makeService()
        let parkedSquatterMessages = parkedSquatter.receiveMessages()
        try await parkedSquatter.connect(host: "127.0.0.1", port: port)
        defer { parkedSquatter.disconnect() }
        try await send(
            .hostKeyRequest(HostKeyRequestMessage(nonce: ConnectionSecurity.generateSessionToken())),
            from: parkedSquatter, as: squatterID
        )
        _ = try await withTimeout(seconds: 5) { () -> VersionedSignalingMessage? in
            for try await message in parkedSquatterMessages { return message }
            return nil
        }

        // A real device now connects, does its key exchange and sends its first message.
        let device = makeService()
        let deviceID = UUID()
        let deviceMessages = device.receiveMessages()
        try await device.connect(host: "127.0.0.1", port: port)
        defer { device.disconnect() }
        let nonce = ConnectionSecurity.generateSessionToken()
        try await send(.hostKeyRequest(HostKeyRequestMessage(nonce: nonce)), from: device, as: deviceID)
        let reply = try await withTimeout(seconds: 5) { () -> VersionedSignalingMessage? in
            for try await message in deviceMessages { return message }
            return nil
        }
        guard case .hostKeyBundle? = reply?.envelope.event else {
            return XCTFail("The device was shut out by idle sockets from an unapproved peer")
        }
        try await send(.hostBusy(HostBusyMessage(hostID: UUID())), from: device, as: deviceID)
        try await waitUntil { inbox.senders.last == deviceID }
    }

    func testParkedConnectionThatNeverSpeaksIsStillDropped() async throws {
        let setup = try await makeHostWithLiveDevice()
        defer { setup.host.stopListening(); setup.live.disconnect() }

        let silent = makeService()
        let silentMessages = silent.receiveMessages()
        try await silent.connect(host: "127.0.0.1", port: setup.port)
        defer { silent.disconnect() }

        // The host closes it once the timeout passes, which ends the client's stream.
        try await withTimeout(seconds: 5) {
            do { for try await _ in silentMessages {} } catch {}
        }

        try await send(.hostBusy(HostBusyMessage(hostID: UUID())), from: setup.live, as: setup.liveID)
        try await waitUntil { setup.inbox.senders == [setup.liveID, setup.liveID] }
    }
}

// MARK: - Host: sealed-only acceptance and the transition rule

final class HostSessionTokenPolicyTests: XCTestCase {
    private let plainToken = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
    private let sealed = Data(repeating: 0x5A, count: 120)
    private let updatedClient = HostCapabilityFlags.currentClient(isMacClient: false)
    private var olderClient: HostCapabilityFlags { updatedClient.subtracting(.supportsSignedKeyExchange) }

    private func offer(
        plain: String? = nil,
        sealed: Data? = nil,
        capabilities: HostCapabilityFlags?
    ) -> SessionOfferMessage {
        SessionOfferMessage(
            sessionID: UUID(), sdp: "offer", qualityPreset: .balanced,
            sessionToken: plain, sealedSessionToken: sealed, clientCapabilities: capabilities
        )
    }

    func testEveryUpdatedClientAdvertisesTheSignedKeyExchange() {
        XCTAssertTrue(HostCapabilityFlags.currentClient(isMacClient: false).contains(.supportsSignedKeyExchange))
        XCTAssertTrue(HostCapabilityFlags.currentClient(isMacClient: true).contains(.supportsSignedKeyExchange))
        XCTAssertEqual(
            HostCapabilityFlags(stableNames: ["supportsSignedKeyExchange"]),
            .supportsSignedKeyExchange
        )
    }

    func testUpdatedClientIsAcceptedOnlyWithASealedToken() {
        XCTAssertEqual(
            HostSessionTokenPolicy.form(of: offer(sealed: sealed, capabilities: updatedClient)),
            .sealed(sealed)
        )
    }

    func testUpdatedClientSendingPlaintextIsRejectedAsADowngrade() {
        guard case .rejected = HostSessionTokenPolicy.form(of: offer(plain: plainToken, capabilities: updatedClient)) else {
            return XCTFail("A plaintext token from a client that can seal must be rejected")
        }
    }

    func testUpdatedClientSendingPlaintextBesideTheSealIsRejected() {
        guard case .rejected = HostSessionTokenPolicy.form(
            of: offer(plain: plainToken, sealed: sealed, capabilities: updatedClient)
        ) else {
            return XCTFail("A plaintext copy next to the seal defeats the seal")
        }
    }

    func testUpdatedClientWithNoTokenIsRejected() {
        guard case .rejected = HostSessionTokenPolicy.form(of: offer(capabilities: updatedClient)) else {
            return XCTFail("An offer without a token must be rejected")
        }
    }

    func testOlderClientKeepsItsPlaintextTokenDuringTheTransition() {
        XCTAssertTrue(HostSessionTokenPolicy.acceptsLegacyPlaintextToken, "Transition is still open")
        XCTAssertEqual(
            HostSessionTokenPolicy.form(of: offer(plain: plainToken, capabilities: olderClient)),
            .legacyPlaintext(plainToken)
        )
        // Clients old enough to send no capabilities at all.
        XCTAssertEqual(
            HostSessionTokenPolicy.form(of: offer(plain: plainToken, capabilities: nil)),
            .legacyPlaintext(plainToken)
        )
    }

    func testOlderClientThatSealsToTheAdvertisedKeyIsStillSealed() {
        XCTAssertEqual(
            HostSessionTokenPolicy.form(of: offer(sealed: sealed, capabilities: olderClient)),
            .sealed(sealed)
        )
    }

    func testOlderClientIsRejectedOnceTheTransitionEnds() {
        guard case .rejected = HostSessionTokenPolicy.form(
            of: offer(plain: plainToken, capabilities: olderClient),
            acceptsLegacyPlaintextToken: false
        ) else {
            return XCTFail("With the transition closed, plaintext tokens are refused")
        }
        // Sealing clients are unaffected by the switch.
        XCTAssertEqual(
            HostSessionTokenPolicy.form(
                of: offer(sealed: sealed, capabilities: updatedClient),
                acceptsLegacyPlaintextToken: false
            ),
            .sealed(sealed)
        )
    }

    func testMalformedLegacyTokenIsRejected() {
        for bad in ["", "abcd", String(repeating: "z", count: 64), String(repeating: "a", count: 62)] {
            guard case .rejected = HostSessionTokenPolicy.form(of: offer(plain: bad, capabilities: olderClient)) else {
                return XCTFail("Token \(bad.count) characters long must be rejected")
            }
        }
    }
}

// MARK: - Client: downgrade / transition rule and first contact

final class HostKeyExchangePolicyTests: XCTestCase {
    private let macFingerprint = String(repeating: "a", count: 64)
    private let otherFingerprint = String(repeating: "b", count: 64)

    func testFirstContactWithAnUpdatedMacNeedsTheUserToCompareItsFingerprint() {
        XCTAssertEqual(
            HostKeyExchangePolicy.evaluate(reply: .verified(fingerprint: macFingerprint), trusted: nil),
            .verified(fingerprint: macFingerprint, needsConfirmation: true)
        )
    }

    func testSavedOrScannedFingerprintThatMatchesSkipsThePrompt() {
        XCTAssertEqual(
            HostKeyExchangePolicy.evaluate(
                reply: .verified(fingerprint: macFingerprint),
                trusted: TrustedHostIdentity(fingerprint: macFingerprint)
            ),
            .verified(fingerprint: macFingerprint, needsConfirmation: false)
        )
    }

    func testAMacAnsweringWithADifferentKeyThanThePinnedOneIsRejected() {
        for requires in [false, true] {
            XCTAssertEqual(
                HostKeyExchangePolicy.evaluate(
                    reply: .verified(fingerprint: otherFingerprint),
                    trusted: TrustedHostIdentity(fingerprint: macFingerprint, requiresSignedKeyExchange: requires)
                ),
                .rejected(.identityChanged)
            )
        }
    }

    func testInvalidBundleIsAlwaysRejectedNeverTreatedAsAnOlderHost() {
        let known = TrustedHostIdentity(fingerprint: macFingerprint, requiresSignedKeyExchange: true)
        for trusted in [nil, TrustedHostIdentity(fingerprint: macFingerprint), known] {
            XCTAssertEqual(
                HostKeyExchangePolicy.evaluate(reply: .invalid, trusted: trusted),
                .rejected(.invalidBundle)
            )
        }
    }

    func testAMacThatDidTheKeyExchangeBeforeCannotBeDowngraded() {
        XCTAssertEqual(
            HostKeyExchangePolicy.evaluate(
                reply: .none,
                trusted: TrustedHostIdentity(fingerprint: macFingerprint, requiresSignedKeyExchange: true)
            ),
            .rejected(.downgradeRefused)
        )
    }

    func testSavedMacOnAnOlderSyncKeepsTheOldHandshakeWithoutAPrompt() {
        XCTAssertEqual(
            HostKeyExchangePolicy.evaluate(reply: .none, trusted: TrustedHostIdentity(fingerprint: macFingerprint)),
            .legacy(needsConfirmation: false)
        )
    }

    func testFirstContactWithAnOlderSyncNeedsExplicitConsent() {
        XCTAssertEqual(
            HostKeyExchangePolicy.evaluate(reply: .none, trusted: nil),
            .legacy(needsConfirmation: true)
        )
    }

    func testNothingButTheKeyBundleIsAcceptedFromAHostBeforeTheOffer() {
        XCTAssertTrue(HostKeyExchangePolicy.acceptsBeforeOffer(.hostKeyBundle))
        // An unsolicited answer here would otherwise be pinned as the Mac's identity while
        // the user is still looking at the fingerprint prompt.
        for kind: SignalingMessageKind in [
            .answer, .sessionReady, .iceCandidate, .offer, .permissionBlocked, .hostBusy,
            .reconnecting, .displayLayoutChanged, .streamRestartRequired, .hostKeyRequest
        ] {
            XCTAssertFalse(HostKeyExchangePolicy.acceptsBeforeOffer(kind), kind.rawValue)
        }
    }

    func testKnownMacsGetLongerToAnswerThanUnknownOnes() {
        XCTAssertEqual(HostKeyExchangePolicy.timeout(for: nil), HostKeyExchangePolicy.unknownHostReplyTimeout)
        XCTAssertEqual(
            HostKeyExchangePolicy.timeout(for: TrustedHostIdentity(fingerprint: macFingerprint)),
            HostKeyExchangePolicy.unknownHostReplyTimeout
        )
        XCTAssertEqual(
            HostKeyExchangePolicy.timeout(
                for: TrustedHostIdentity(fingerprint: macFingerprint, requiresSignedKeyExchange: true)
            ),
            HostKeyExchangePolicy.knownHostReplyTimeout
        )
        XCTAssertGreaterThan(HostKeyExchangePolicy.knownHostReplyTimeout, HostKeyExchangePolicy.unknownHostReplyTimeout)
    }
}

// MARK: - Client: which fingerprints count as already trusted

@MainActor
final class FirstContactFingerprintTests: XCTestCase {
    private let savedHostsKey = "com.remotedesktop.savedHosts"
    private let macFingerprint = String(repeating: "c", count: 64)

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: savedHostsKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: savedHostsKey)
    }

    private func makeViewModel() -> HostsListViewModel {
        HostsListViewModel(browser: EmptyBrowser())
    }

    func testTypedAddressHasNoTrustedFingerprintSoFirstContactPrompts() throws {
        let viewModel = makeViewModel()
        let row = try XCTUnwrap(viewModel.addManualHost(address: "192.168.1.20:9471"))

        XCTAssertNil(viewModel.trustedIdentity(matching: row.endpoint))
    }

    func testAdvertisedFingerprintAloneIsNotTrusted() {
        let viewModel = makeViewModel()
        let advertised = ResolvedHostEndpoint(
            hostname: "studio.local",
            port: 9471,
            metadata: HostAdvertisementMetadata(
                protocolVersion: 1, hostID: UUID(), displayName: "Studio Mac", appVersion: "4.0",
                signalingPort: 9471, capabilities: [], publicKeyFingerprint: macFingerprint
            )
        )

        XCTAssertNil(viewModel.trustedIdentity(matching: advertised), "Bonjour can be spoofed; it must not skip the prompt")
    }

    func testScannedFingerprintIsTrustedForThatAddressWithoutChangingHowItConnects() throws {
        let viewModel = makeViewModel()
        let row = try XCTUnwrap(viewModel.addManualHost(address: "192.168.1.20:9471", scannedFingerprint: macFingerprint))

        XCTAssertEqual(viewModel.trustedIdentity(matching: row.endpoint), TrustedHostIdentity(fingerprint: macFingerprint))
        XCTAssertNil(row.endpoint.metadata.publicKeyFingerprint, "A scan must not move the Mac onto the TLS port")
        XCTAssertEqual(row.endpoint.port, 9471)

        let elsewhere = try XCTUnwrap(viewModel.addManualHost(address: "192.168.1.99:9471"))
        XCTAssertNil(viewModel.trustedIdentity(matching: elsewhere.endpoint), "A scan vouches for one address only")
    }

    func testTypingAnAddressAfterAScanDropsTheScannedFingerprint() throws {
        let viewModel = makeViewModel()
        _ = viewModel.addManualHost(address: "192.168.1.20:9471", scannedFingerprint: macFingerprint)

        let typed = try XCTUnwrap(viewModel.addManualHost(address: "192.168.1.20:9471"))

        XCTAssertNil(viewModel.trustedIdentity(matching: typed.endpoint))
    }

    func testMalformedScannedFingerprintIsIgnored() throws {
        let viewModel = makeViewModel()
        let row = try XCTUnwrap(viewModel.addManualHost(address: "192.168.1.20:9471", scannedFingerprint: "not-a-fingerprint"))

        XCTAssertNil(viewModel.trustedIdentity(matching: row.endpoint))
    }

    func testVerifiedMacIsPinnedAndTheKeyExchangeRequirementIsSticky() throws {
        let viewModel = makeViewModel()
        let row = try XCTUnwrap(viewModel.addManualHost(address: "192.168.1.20:9471"))
        let hostID = UUID()

        // First verified connection on the older handshake: pinned, exchange not yet required.
        let legacy = try XCTUnwrap(viewModel.recordVerifiedHostIdentity(
            endpoint: row.endpoint, hostID: hostID, publicKeyFingerprint: macFingerprint
        ))
        XCTAssertEqual(viewModel.trustedIdentity(matching: legacy), TrustedHostIdentity(fingerprint: macFingerprint))

        // The Mac is updated and completes the signed key exchange.
        let upgraded = try XCTUnwrap(viewModel.recordVerifiedHostIdentity(
            endpoint: legacy, hostID: hostID, publicKeyFingerprint: macFingerprint, signedKeyExchange: true
        ))
        let required = TrustedHostIdentity(fingerprint: macFingerprint, requiresSignedKeyExchange: true)
        XCTAssertEqual(viewModel.trustedIdentity(matching: upgraded), required)

        // Nothing later lowers it: not a record written without the flag, not a re-save,
        // not a fresh view model loading from disk.
        let again = try XCTUnwrap(viewModel.recordVerifiedHostIdentity(
            endpoint: upgraded, hostID: hostID, publicKeyFingerprint: macFingerprint
        ))
        XCTAssertEqual(viewModel.trustedIdentity(matching: again), required)
        viewModel.saveHost(hostID)
        XCTAssertEqual(viewModel.trustedIdentity(matching: again), required)
        XCTAssertEqual(makeViewModel().trustedIdentity(matching: again), required)
    }

    private func advertised(
        hostID: UUID, host: String, fingerprint: String?, mac: String?
    ) -> ResolvedHostEndpoint {
        ResolvedHostEndpoint(
            hostname: host,
            port: 9471,
            metadata: HostAdvertisementMetadata(
                protocolVersion: 1, hostID: hostID, displayName: "Studio Mac", appVersion: "4.0",
                signalingPort: 9471, capabilities: [], publicKeyFingerprint: fingerprint, macAddress: mac
            )
        )
    }

    func testBonjourCannotMoveAPinnedKeyOrClearTheDowngradeProtection() async throws {
        let browser = StubBrowser()
        let viewModel = HostsListViewModel(browser: browser)
        let mac = "aa:bb:cc:dd:ee:ff"
        let real = advertised(hostID: UUID(), host: "studio.local", fingerprint: macFingerprint, mac: mac)
        let verified = try XCTUnwrap(viewModel.recordVerifiedHostIdentity(
            endpoint: real, hostID: real.metadata.hostID, publicKeyFingerprint: macFingerprint, signedKeyExchange: true
        ))
        let required = TrustedHostIdentity(fingerprint: macFingerprint, requiresSignedKeyExchange: true)
        XCTAssertEqual(viewModel.trustedIdentity(matching: verified), required)

        // A LAN impostor copies the Mac's public MAC and advertises its own key, or none.
        let impostorWithKey = advertised(hostID: UUID(), host: "evil.local", fingerprint: String(repeating: "e", count: 64), mac: mac)
        let impostorWithoutKey = advertised(hostID: UUID(), host: "evil2.local", fingerprint: nil, mac: mac)
        browser.hosts = [impostorWithKey, impostorWithoutKey]
        await viewModel.refresh()

        XCTAssertEqual(viewModel.trustedIdentity(matching: verified), required, "the pin and its flag must survive")
        XCTAssertEqual(viewModel.trustedIdentity(matching: impostorWithKey), required, "an impostor is judged against the pin")
        XCTAssertEqual(viewModel.trustedIdentity(matching: impostorWithoutKey), required)
        XCTAssertEqual(makeViewModel().trustedIdentity(matching: impostorWithKey), required, "and so is a cold start")
        XCTAssertFalse(viewModel.hosts.contains { $0.endpoint.hostname.hasPrefix("evil") && $0.isSaved },
                       "an unverified advertisement must not inherit the saved record")
        XCTAssertTrue(viewModel.hosts.contains { $0.endpoint.hostname == "studio.local" && $0.isSaved },
                      "the verified Mac keeps its own saved tile")
    }

    func testSettingsListsAndForgetsPinnedMacs() async throws {
        let browser = StubBrowser()
        let viewModel = HostsListViewModel(browser: browser)
        let real = advertised(hostID: UUID(), host: "studio.local", fingerprint: macFingerprint, mac: "aa:bb:cc:dd:ee:ff")
        _ = viewModel.recordVerifiedHostIdentity(
            endpoint: real, hostID: real.metadata.hostID, publicKeyFingerprint: macFingerprint, signedKeyExchange: true
        )
        XCTAssertEqual(HostsListViewModel.pinnedMacs().map(\.fingerprint), [macFingerprint])
        XCTAssertNotNil(viewModel.trustedIdentity(matching: real))

        HostsListViewModel.forgetSavedMac(real.metadata.hostID)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(HostsListViewModel.pinnedMacs().isEmpty)
        XCTAssertNil(viewModel.trustedIdentity(matching: real), "forgetting must clear the pin")
        XCTAssertFalse(viewModel.hosts.contains { $0.id == real.metadata.hostID && $0.isSaved })
    }

    func testSavingADiscoveredMacDoesNotPinItsAdvertisedKey() async throws {
        let browser = StubBrowser()
        let viewModel = HostsListViewModel(browser: browser)
        let advert = advertised(hostID: UUID(), host: "studio.local", fingerprint: macFingerprint, mac: "aa:bb:cc:dd:ee:ff")
        browser.hosts = [advert]
        await viewModel.refresh()

        viewModel.saveHost(advert.metadata.hostID)

        XCTAssertNil(viewModel.trustedIdentity(matching: advert),
                     "Bonjour can be spoofed; tapping Save must not make its key trusted without a prompt")
    }

    func testOnlyTailnetNamesAndAddressesAreTakenFromAnAdvertisement() {
        XCTAssertEqual(HostsListViewModel.validTailnetHost("studio.tail1234.ts.net."), "studio.tail1234.ts.net")
        XCTAssertEqual(HostsListViewModel.validTailnetHost("100.101.102.103"), "100.101.102.103")
        XCTAssertEqual(HostsListViewModel.validTailnetHost("fd7a:115c:a1e0::1"), "fd7a:115c:a1e0::1")
        XCTAssertNil(HostsListViewModel.validTailnetHost("evil.example.com"))
        XCTAssertNil(HostsListViewModel.validTailnetHost("203.0.113.9"), "a public address is not a tailnet address")
        XCTAssertNil(HostsListViewModel.validTailnetHost("192.168.1.9"))
        XCTAssertNil(HostsListViewModel.validTailnetHost("ts.net.evil.example"))
        XCTAssertNil(HostsListViewModel.validTailnetHost(""))
        XCTAssertNil(HostsListViewModel.validTailnetHost(nil))
    }

    func testSameMacUnderANewHostIDKeepsItsPinAndTheDowngradeProtection() async throws {
        let browser = StubBrowser()
        let viewModel = HostsListViewModel(browser: browser)
        let mac = "aa:bb:cc:dd:ee:ff"
        let real = advertised(hostID: UUID(), host: "studio.local", fingerprint: macFingerprint, mac: mac)
        _ = viewModel.recordVerifiedHostIdentity(
            endpoint: real, hostID: real.metadata.hostID, publicKeyFingerprint: macFingerprint, signedKeyExchange: true
        )

        // Older builds advertised a new host ID on every launch. Same key, so it is the same Mac.
        let relaunched = advertised(hostID: UUID(), host: "studio.local", fingerprint: macFingerprint, mac: mac)
        browser.hosts = [relaunched]
        await viewModel.refresh()

        let required = TrustedHostIdentity(fingerprint: macFingerprint, requiresSignedKeyExchange: true)
        XCTAssertEqual(viewModel.trustedIdentity(matching: relaunched), required)
        XCTAssertEqual(viewModel.hosts.filter { $0.isSaved }.count, 1, "the relaunched Mac replaces the old tile")
    }

    func testSavedFingerprintWinsOverALaterScanOfADifferentOne() throws {
        let viewModel = makeViewModel()
        let row = try XCTUnwrap(viewModel.addManualHost(address: "192.168.1.20:9471"))
        _ = viewModel.recordVerifiedHostIdentity(endpoint: row.endpoint, hostID: UUID(), publicKeyFingerprint: macFingerprint)

        let rescanned = try XCTUnwrap(viewModel.addManualHost(
            address: "192.168.1.20:9471",
            scannedFingerprint: String(repeating: "d", count: 64)
        ))

        XCTAssertEqual(viewModel.trustedIdentity(matching: rescanned.endpoint)?.fingerprint, macFingerprint)
    }
}

private final class StubBrowser: BonjourDiscoveryBrowsing {
    var hosts: [ResolvedHostEndpoint] = []
    func startBrowsing(serviceType: String, domain: String) async throws {}
    func stopBrowsing() async {}
    func resolvedHosts() async -> [ResolvedHostEndpoint] { hosts }
    func events() -> AsyncStream<BonjourDiscoveryEvent> {
        AsyncStream { $0.finish() }
    }
}

private final class EmptyBrowser: BonjourDiscoveryBrowsing {
    func startBrowsing(serviceType: String, domain: String) async throws {}
    func stopBrowsing() async {}
    func resolvedHosts() async -> [ResolvedHostEndpoint] { [] }
    func events() -> AsyncStream<BonjourDiscoveryEvent> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - Pairing link

final class PairingLinkFingerprintTests: XCTestCase {
    private let fingerprint = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    func testLinkCarriesTheHostFingerprint() throws {
        let link = try XCTUnwrap(VampHostPairingLink.make(
            address: "192.168.1.20:9471", displayName: "Studio Mac", fingerprint: fingerprint
        ))
        let parsed = try XCTUnwrap(VampHostPairingLink.parse(link))

        XCTAssertEqual(parsed.address, "192.168.1.20:9471")
        XCTAssertEqual(parsed.displayName, "Studio Mac")
        XCTAssertEqual(parsed.fingerprint, fingerprint)
    }

    func testLinkFromAnOlderSyncStillParsesWithoutAFingerprint() throws {
        let parsed = try XCTUnwrap(VampHostPairingLink.parse("vampstream://pair?address=192.168.1.20:9471&name=Studio"))

        XCTAssertEqual(parsed.address, "192.168.1.20:9471")
        XCTAssertNil(parsed.fingerprint)
    }

    func testLinkWithAMalformedFingerprintIsRejectedRatherThanDegraded() {
        for bad in ["abc", String(repeating: "g", count: 64), String(repeating: "a", count: 63), ""] {
            XCTAssertNil(VampHostPairingLink.parse("vampstream://pair?address=192.168.1.20:9471&fp=\(bad)"), bad)
        }
    }

    func testFingerprintCaseIsNormalised() throws {
        let parsed = try XCTUnwrap(VampHostPairingLink.parse(
            "vampstream://pair?address=192.168.1.20:9471&fp=\(fingerprint.uppercased())"
        ))
        XCTAssertEqual(parsed.fingerprint, fingerprint)
    }

    func testMakeLeavesOutAnInvalidFingerprint() throws {
        let link = try XCTUnwrap(VampHostPairingLink.make(address: "192.168.1.20:9471", fingerprint: "nope"))
        XCTAssertFalse(link.contains("fp="))
    }

    func testGroupedFingerprintMatchesSyncsLayout() {
        XCTAssertEqual(
            PublicKeyFingerprint.grouped(fingerprint),
            "00112233 44556677 8899aabb ccddeeff\n00112233 44556677 8899aabb ccddeeff"
        )
    }
}
