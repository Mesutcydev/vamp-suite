import XCTest
@testable import SharedModels
@testable import SharedUtilities

final class ProductCompatibilityTests: XCTestCase {
    func testFingerprintValidationMatchesTheAdvertisedTLSContract() {
        XCTAssertTrue(RemoteDesktopConstants.isValidPublicKeyFingerprint(String(repeating: "a", count: 64)))
        XCTAssertFalse(RemoteDesktopConstants.isValidPublicKeyFingerprint(String(repeating: "A", count: 64)))
        XCTAssertFalse(RemoteDesktopConstants.isValidPublicKeyFingerprint(String(repeating: "a", count: 63)))
        XCTAssertFalse(RemoteDesktopConstants.isValidPublicKeyFingerprint(String(repeating: "g", count: 64)))
    }

    func testTerminalOnlyCapabilitiesAreNotRemoteControlCapabilities() {
        let terminalOnly: HostCapabilityFlags = [.supportsH264, .supportsTerminal, .supportsMultipleTerminals]
        let fullHost: HostCapabilityFlags = terminalOnly.union(.supportsMultiDisplay)

        XCTAssertTrue(terminalOnly.isTerminalOnlyHost)
        XCTAssertFalse(fullHost.isTerminalOnlyHost)
    }
}
