import XCTest
@testable import Discovery
@testable import InputControl
@testable import SharedModels
@testable import SharedProtocol

// MARK: - Connection Security Tests

final class ConnectionSecurityTests: XCTestCase {

    // MARK: PIN Generation

    func testConnectionPINIs12Digits() {
        for _ in 0..<100 {
            let pin = ConnectionSecurity.generateConnectionPIN()
            XCTAssertEqual(pin.count, 12, "PIN should be exactly 12 characters")
            XCTAssertTrue(pin.allSatisfy(\.isNumber), "PIN should only contain digits")
        }
    }

    func testConnectionPINsAreRandom() {
        let pins = Set((0..<50).map { _ in ConnectionSecurity.generateConnectionPIN() })
        // 50 random 12-digit PINs should have very high entropy; at least 40 unique
        XCTAssertGreaterThan(pins.count, 40, "PINs should be random")
    }

    // MARK: Key Derivation

    func testDeriveKeyIsDeterministic() {
        let key1 = ConnectionSecurity.deriveKey(from: "123456")
        let key2 = ConnectionSecurity.deriveKey(from: "123456")
        XCTAssertEqual(
            key1.withUnsafeBytes { Data($0) },
            key2.withUnsafeBytes { Data($0) },
            "Same PIN should derive the same key"
        )
    }

    func testDeriveKeyDiffersForDifferentPINs() {
        let key1 = ConnectionSecurity.deriveKey(from: "123456")
        let key2 = ConnectionSecurity.deriveKey(from: "654321")
        XCTAssertNotEqual(
            key1.withUnsafeBytes { Data($0) },
            key2.withUnsafeBytes { Data($0) },
            "Different PINs should derive different keys"
        )
    }

    func testDeriveKeyProduces256BitKey() {
        let key = ConnectionSecurity.deriveKey(from: "000000")
        let keyData = key.withUnsafeBytes { Data($0) }
        XCTAssertEqual(keyData.count, 32, "Key should be 256 bits (32 bytes)")
    }

    // MARK: Session Token

    func testSessionTokenIs32Bytes() {
        let token = ConnectionSecurity.generateSessionToken()
        XCTAssertEqual(token.count, 32, "Session token should be 32 bytes")
    }

    func testSessionTokensAreUnique() {
        let tokens = Set((0..<50).map { _ in ConnectionSecurity.generateSessionToken() })
        XCTAssertEqual(tokens.count, 50, "Each session token should be unique")
    }

    // MARK: Token Hex Encoding

    func testTokenHexRoundTrip() {
        let token = ConnectionSecurity.generateSessionToken()
        let hex = ConnectionSecurity.tokenToHex(token)
        XCTAssertEqual(hex.count, 64, "Hex of 32 bytes should be 64 chars")
        let decoded = ConnectionSecurity.tokenFromHex(hex)
        XCTAssertEqual(decoded, token, "Hex round-trip should preserve token")
    }

    func testTokenFromHexRejectsInvalidInput() {
        XCTAssertNil(ConnectionSecurity.tokenFromHex("zz"))
        XCTAssertNil(ConnectionSecurity.tokenFromHex("0"))  // odd length
    }

    func testTokenFromHexAcceptsEmptyString() {
        let result = ConnectionSecurity.tokenFromHex("")
        XCTAssertEqual(result, Data())
    }
}

// MARK: - Rate Limiter Tests

final class RateLimiterTests: XCTestCase {

    func testAllowsUpToMaxAttempts() {
        let limiter = ConnectionSecurity.ConnectionRateLimiter(maxAttempts: 3, windowSeconds: 60)
        XCTAssertTrue(limiter.shouldAllow(ip: "10.0.0.1"))
        XCTAssertTrue(limiter.shouldAllow(ip: "10.0.0.1"))
        XCTAssertTrue(limiter.shouldAllow(ip: "10.0.0.1"))
        XCTAssertFalse(limiter.shouldAllow(ip: "10.0.0.1"), "4th attempt should be blocked")
    }

    func testDifferentIPsAreIndependent() {
        let limiter = ConnectionSecurity.ConnectionRateLimiter(maxAttempts: 1, windowSeconds: 60)
        XCTAssertTrue(limiter.shouldAllow(ip: "10.0.0.1"))
        XCTAssertFalse(limiter.shouldAllow(ip: "10.0.0.1"))
        XCTAssertTrue(limiter.shouldAllow(ip: "10.0.0.2"), "Different IP should be allowed")
    }

    func testDefaultLimiterAllows5() {
        let limiter = ConnectionSecurity.ConnectionRateLimiter()
        for _ in 0..<5 {
            XCTAssertTrue(limiter.shouldAllow(ip: "192.168.1.1"))
        }
        XCTAssertFalse(limiter.shouldAllow(ip: "192.168.1.1"))
    }

    func testResetAllowsAHealthyPeerToReconnect() {
        let limiter = ConnectionSecurity.ConnectionRateLimiter(maxAttempts: 2, windowSeconds: 60)
        XCTAssertTrue(limiter.shouldAllow(ip: "192.168.1.20"))
        XCTAssertTrue(limiter.shouldAllow(ip: "192.168.1.20"))
        XCTAssertFalse(limiter.shouldAllow(ip: "192.168.1.20"))

        // A valid signaling message authenticates the peer; the next reconnect
        // should start a fresh attempt window instead of inheriting stale sockets.
        limiter.reset(ip: "192.168.1.20")
        XCTAssertTrue(limiter.shouldAllow(ip: "192.168.1.20"))
    }

    /// A legitimate client reconnect sweep is: up to 3 `reconnectLast` attempts × several
    /// candidate endpoints (LAN + Tailscale) × possibly a TLS socket and a plaintext one.
    /// The signaling budget must survive that without refusing the peer at TCP accept — a
    /// refusal there is unrecoverable, because nothing the client sends afterwards can be
    /// read on a socket that was never accepted.
    func testSignalingBudgetSurvivesAClientReconnectSweep() {
        let service = BonjourSignalingService()
        let ip = "192.168.1.50"
        // Worst realistic case: 3 attempts × 3 candidates × 2 sockets.
        for _ in 0..<(3 * 3 * 2) {
            XCTAssertTrue(service.rateLimiter.shouldAllow(ip: ip),
                "reconnect sweep must not exhaust the connection budget")
        }
        // The limiter must still engage — it is a budget, not a removal.
        for _ in 0..<64 {
            if !service.rateLimiter.shouldAllow(ip: ip) { return }
        }
        XCTFail("Rate limiter never engaged for a flooding peer")
    }

    /// Clearing a peer's connection budget on signature verification alone would let anyone
    /// with a self-generated keypair erase its own flood budget forever. The budget may only
    /// be cleared for a fingerprint the host's trust gate has actually approved.
    func testOnlyApprovedPeersAreRecognizedAsTrusted() {
        let service = BonjourSignalingService()
        let approved = "9da6f17697544096c21c4b52047b69c2d64606e80ab910234f4be02f4a026372"

        XCTAssertFalse(service.isTrustedPeer(approved), "unknown peer is not trusted yet")
        XCTAssertFalse(service.isTrustedPeer(nil))
        XCTAssertFalse(service.isTrustedPeer(""), "empty fingerprint is never trusted")
        XCTAssertFalse(service.isTrustedPeer("not-a-fingerprint"))

        service.noteTrustedPeer(fingerprint: approved)
        XCTAssertTrue(service.isTrustedPeer(approved))
        // Normalization must be forgiving: the wire value's case/whitespace varies.
        XCTAssertTrue(service.isTrustedPeer(approved.uppercased()))
        XCTAssertTrue(service.isTrustedPeer("  \(approved)  "))

        service.noteTrustedPeer(fingerprint: "")
        service.noteTrustedPeer(fingerprint: "   ")
        XCTAssertTrue(service.isTrustedPeer(approved), "blank fingerprints must not evict trust")
    }
}

// MARK: - Input Validation Security Tests

final class InputValidationSecurityTests: XCTestCase {

    // MARK: Dangerous Key Combinations

    func testBlocksCmdQ() {
        let cmd = KeyCommand(keyCode: 12, action: .down, modifiers: .command)
        let rejection = InputCommandValidation.validateContent(.key(cmd))
        XCTAssertNotNil(rejection, "Cmd+Q should be blocked")
    }

    func testBlocksCmdDelete() {
        let cmd = KeyCommand(keyCode: 51, action: .down, modifiers: .command)
        let rejection = InputCommandValidation.validateContent(.key(cmd))
        XCTAssertNotNil(rejection, "Cmd+Delete should be blocked")
    }

    func testBlocksCmdShiftDelete() {
        let cmd = KeyCommand(keyCode: 51, action: .down, modifiers: [.command, .shift])
        let rejection = InputCommandValidation.validateContent(.key(cmd))
        XCTAssertNotNil(rejection, "Cmd+Shift+Delete should be blocked")
    }

    func testBlocksCmdOptionEsc() {
        let cmd = KeyCommand(keyCode: 53, action: .down, modifiers: [.command, .option])
        let rejection = InputCommandValidation.validateContent(.key(cmd))
        XCTAssertNotNil(rejection, "Cmd+Option+Esc should be blocked")
    }

    func testBlocksCtrlCmdQ() {
        let cmd = KeyCommand(keyCode: 12, action: .down, modifiers: [.command, .control])
        let rejection = InputCommandValidation.validateContent(.key(cmd))
        XCTAssertNotNil(rejection, "Ctrl+Cmd+Q should be blocked")
    }

    func testAllowsSafeKeyCombinations() {
        // Cmd+C (copy) - keyCode 8
        let cmdC = KeyCommand(keyCode: 8, action: .down, modifiers: .command)
        XCTAssertNil(InputCommandValidation.validateContent(.key(cmdC)), "Cmd+C should be allowed")

        // Cmd+V (paste) - keyCode 9
        let cmdV = KeyCommand(keyCode: 9, action: .down, modifiers: .command)
        XCTAssertNil(InputCommandValidation.validateContent(.key(cmdV)), "Cmd+V should be allowed")

        // Plain 'a' key
        let plainA = KeyCommand(keyCode: 0, action: .down, modifiers: [])
        XCTAssertNil(InputCommandValidation.validateContent(.key(plainA)), "Plain key should be allowed")
    }

    // MARK: Control Character Blocking

    func testBlocksNullByteInText() {
        let text = TextInputCommand(text: "hello\0world")
        let rejection = InputCommandValidation.validateContent(.text(text))
        XCTAssertNotNil(rejection, "Null byte should be blocked")
    }

    func testBlocksBellCharacterInText() {
        let text = TextInputCommand(text: "hello\u{07}world")
        let rejection = InputCommandValidation.validateContent(.text(text))
        XCTAssertNotNil(rejection, "Bell character should be blocked")
    }

    func testAllowsNewlineAndTab() {
        // newline (\n = U+000A) and tab (\t = U+0009) should pass — they're
        // outside the blocked ranges (0-8 and 14-31)
        let text = TextInputCommand(text: "hello\nworld\ttab")
        XCTAssertNil(InputCommandValidation.validateContent(.text(text)), "Newline and tab should be allowed")
    }

    // MARK: Coordinate Bounds

    func testRejectsNaNCoordinates() {
        let move = PointerMoveCommand(location: DesktopPoint(x: .nan, y: 100), displayID: "main")
        let rejection = InputCommandValidation.validateContent(.pointerMove(move))
        XCTAssertNotNil(rejection, "NaN coordinates should be rejected")
    }

    func testRejectsInfiniteCoordinates() {
        let move = PointerMoveCommand(location: DesktopPoint(x: .infinity, y: 100), displayID: "main")
        let rejection = InputCommandValidation.validateContent(.pointerMove(move))
        XCTAssertNotNil(rejection, "Infinite coordinates should be rejected")
    }

    func testRejectsExcessiveCoordinates() {
        let move = PointerMoveCommand(location: DesktopPoint(x: 200_000, y: 100), displayID: "main")
        let rejection = InputCommandValidation.validateContent(.pointerMove(move))
        XCTAssertNotNil(rejection, "Coordinates beyond 100k should be rejected")
    }

    func testAcceptsNormalCoordinates() {
        let move = PointerMoveCommand(location: DesktopPoint(x: 1920, y: 1080), displayID: "main")
        XCTAssertNil(InputCommandValidation.validateContent(.pointerMove(move)))
    }

    // MARK: Text Length

    func testRejectsEmptyText() {
        let text = TextInputCommand(text: "")
        let rejection = InputCommandValidation.validateContent(.text(text))
        XCTAssertNotNil(rejection, "Empty text should be rejected")
    }

    func testRejectsOversizedText() {
        let text = TextInputCommand(text: String(repeating: "A", count: 2_001))
        let rejection = InputCommandValidation.validateContent(.text(text))
        XCTAssertNotNil(rejection, "Text over 2000 chars should be rejected")
    }

    func testAcceptsReasonableText() {
        let text = TextInputCommand(text: "Hello, world!")
        XCTAssertNil(InputCommandValidation.validateContent(.text(text)))
    }

    // MARK: Session Routing Validation

    func testRejectsDisabledRouter() {
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: UUID(),
            activeSessionID: UUID(),
            isRouterEnabled: false,
            connectionState: .connected
        )
        XCTAssertEqual(rejection, .routerDisabled)
    }

    func testRejectsNoActiveSession() {
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: UUID(),
            activeSessionID: nil,
            isRouterEnabled: true,
            connectionState: .connected
        )
        XCTAssertEqual(rejection, .noActiveSession)
    }

    func testRejectsMismatchedSession() {
        let expected = UUID()
        let received = UUID()
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: received,
            activeSessionID: expected,
            isRouterEnabled: true,
            connectionState: .connected
        )
        XCTAssertEqual(rejection, .sessionMismatch(expected: expected, received: received))
    }

    func testRejectsDisconnectedState() {
        let id = UUID()
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: id,
            activeSessionID: id,
            isRouterEnabled: true,
            connectionState: .disconnected
        )
        XCTAssertEqual(rejection, .notConnected(.disconnected))
    }

    func testAcceptsValidRouting() {
        let id = UUID()
        let rejection = InputCommandValidation.validateRouting(
            commandSessionID: id,
            activeSessionID: id,
            isRouterEnabled: true,
            connectionState: .connected
        )
        XCTAssertNil(rejection)
    }
}

// MARK: - Signaling Model Security Tests

final class SignalingModelSecurityTests: XCTestCase {

    func testSignalingPeerPreservesFingerprint() {
        let peer = SignalingPeer(
            id: UUID(),
            role: .host,
            displayName: "Test",
            publicKeyFingerprint: "abc123def456"
        )
        XCTAssertEqual(peer.publicKeyFingerprint, "abc123def456")
    }

    func testSignalingPeerFingerprintOptional() {
        let peer = SignalingPeer(id: UUID(), role: .client, displayName: "Test")
        XCTAssertNil(peer.publicKeyFingerprint)
    }

    func testSessionOfferIncludesToken() throws {
        let offer = SessionOfferMessage(
            sessionID: UUID(),
            sdp: "v=0\r\n...",
            qualityPreset: .balanced,
            sessionToken: "abcdef0123456789"
        )
        let data = try JSONEncoder().encode(offer)
        let decoded = try JSONDecoder().decode(SessionOfferMessage.self, from: data)
        XCTAssertEqual(decoded.sessionToken, "abcdef0123456789")
    }

    func testSessionOfferTokenOptional() throws {
        let offer = SessionOfferMessage(
            sessionID: UUID(),
            sdp: "v=0\r\n...",
            qualityPreset: .balanced
        )
        let data = try JSONEncoder().encode(offer)
        let decoded = try JSONDecoder().decode(SessionOfferMessage.self, from: data)
        XCTAssertNil(decoded.sessionToken)
    }

    func testSessionAnswerIncludesToken() throws {
        let answer = SessionAnswerMessage(
            sessionID: UUID(),
            sdp: "v=0\r\n...",
            sessionToken: "token123"
        )
        let data = try JSONEncoder().encode(answer)
        let decoded = try JSONDecoder().decode(SessionAnswerMessage.self, from: data)
        XCTAssertEqual(decoded.sessionToken, "token123")
    }
}
