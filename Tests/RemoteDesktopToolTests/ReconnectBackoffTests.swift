import XCTest
@testable import SharedUtilities

final class ReconnectBackoffTests: XCTestCase {

    // MARK: - Delay Calculation

    func testBaseDelayForFirstAttempt() {
        let backoff = ReconnectBackoff()
        XCTAssertEqual(backoff.delay(for: 0), 1.0, accuracy: 0.001)
    }

    func testExponentialGrowth() {
        let config = ReconnectBackoff.Configuration(
            baseDelay: 1.0,
            maxDelay: 60.0,
            multiplier: 2.0,
            jitterFraction: 0,
            maxAttempts: 10
        )
        let backoff = ReconnectBackoff(configuration: config)

        XCTAssertEqual(backoff.delay(for: 0), 1.0, accuracy: 0.001)
        XCTAssertEqual(backoff.delay(for: 1), 2.0, accuracy: 0.001)
        XCTAssertEqual(backoff.delay(for: 2), 4.0, accuracy: 0.001)
        XCTAssertEqual(backoff.delay(for: 3), 8.0, accuracy: 0.001)
        XCTAssertEqual(backoff.delay(for: 4), 16.0, accuracy: 0.001)
        XCTAssertEqual(backoff.delay(for: 5), 32.0, accuracy: 0.001)
    }

    func testMaxDelayCap() {
        let config = ReconnectBackoff.Configuration(
            baseDelay: 1.0,
            maxDelay: 10.0,
            multiplier: 2.0,
            jitterFraction: 0,
            maxAttempts: 20
        )
        let backoff = ReconnectBackoff(configuration: config)

        // 2^4 = 16, which exceeds maxDelay of 10
        XCTAssertEqual(backoff.delay(for: 4), 10.0, accuracy: 0.001)
        XCTAssertEqual(backoff.delay(for: 10), 10.0, accuracy: 0.001)
    }

    func testNegativeAttemptReturnsBaseDelay() {
        let backoff = ReconnectBackoff()
        XCTAssertEqual(backoff.delay(for: -1), 1.0, accuracy: 0.001)
    }

    // MARK: - Jitter

    func testJitterWithMidpointSeedReturnsSameDelay() {
        let config = ReconnectBackoff.Configuration(
            baseDelay: 2.0,
            maxDelay: 60.0,
            multiplier: 2.0,
            jitterFraction: 0.15,
            maxAttempts: 10
        )
        let backoff = ReconnectBackoff(configuration: config)

        // randomSeed = 0.5 → offset = 0
        let result = backoff.delayWithJitter(for: 0, randomSeed: 0.5)
        XCTAssertEqual(result, 2.0, accuracy: 0.001)
    }

    func testJitterLowSeedReducesDelay() {
        let config = ReconnectBackoff.Configuration(
            baseDelay: 10.0,
            maxDelay: 60.0,
            multiplier: 2.0,
            jitterFraction: 0.2,
            maxAttempts: 10
        )
        let backoff = ReconnectBackoff(configuration: config)

        // randomSeed = 0 → offset = -jitter = -2.0
        let result = backoff.delayWithJitter(for: 0, randomSeed: 0.0)
        XCTAssertEqual(result, 8.0, accuracy: 0.001)
    }

    func testJitterHighSeedIncreasesDelay() {
        let config = ReconnectBackoff.Configuration(
            baseDelay: 10.0,
            maxDelay: 60.0,
            multiplier: 2.0,
            jitterFraction: 0.2,
            maxAttempts: 10
        )
        let backoff = ReconnectBackoff(configuration: config)

        // randomSeed = 1.0 → offset = +jitter = +2.0
        let result = backoff.delayWithJitter(for: 0, randomSeed: 1.0)
        XCTAssertEqual(result, 12.0, accuracy: 0.001)
    }

    func testZeroJitterFractionReturnsExactDelay() {
        let config = ReconnectBackoff.Configuration(
            baseDelay: 5.0,
            maxDelay: 60.0,
            multiplier: 2.0,
            jitterFraction: 0,
            maxAttempts: 10
        )
        let backoff = ReconnectBackoff(configuration: config)

        let result = backoff.delayWithJitter(for: 2, randomSeed: 0.0)
        XCTAssertEqual(result, 20.0, accuracy: 0.001) // 5 * 2^2 = 20
    }

    // MARK: - Attempt Tracking

    func testInitialState() {
        let backoff = ReconnectBackoff()
        XCTAssertEqual(backoff.attempt, 0)
        XCTAssertFalse(backoff.isExhausted)
        XCTAssertFalse(backoff.hasAttempted)
    }

    func testRecordFailureAdvancesAttempt() {
        var backoff = ReconnectBackoff()
        backoff.recordFailure()
        XCTAssertEqual(backoff.attempt, 1)
        XCTAssertTrue(backoff.hasAttempted)
    }

    func testExhaustedAfterMaxAttempts() {
        let config = ReconnectBackoff.Configuration(maxAttempts: 3)
        var backoff = ReconnectBackoff(configuration: config)

        XCTAssertFalse(backoff.isExhausted)
        backoff.recordFailure() // 1
        XCTAssertFalse(backoff.isExhausted)
        backoff.recordFailure() // 2
        XCTAssertFalse(backoff.isExhausted)
        backoff.recordFailure() // 3
        XCTAssertTrue(backoff.isExhausted)
    }

    func testResetClearsAttempts() {
        var backoff = ReconnectBackoff()
        backoff.recordFailure()
        backoff.recordFailure()
        XCTAssertEqual(backoff.attempt, 2)

        backoff.reset()
        XCTAssertEqual(backoff.attempt, 0)
        XCTAssertFalse(backoff.isExhausted)
        XCTAssertFalse(backoff.hasAttempted)
    }

    // MARK: - Current Delay

    func testCurrentDelayMatchesAttempt() {
        var backoff = ReconnectBackoff(configuration: .init(
            baseDelay: 1.0,
            maxDelay: 60.0,
            multiplier: 2.0,
            jitterFraction: 0,
            maxAttempts: 10
        ))

        XCTAssertEqual(backoff.currentDelay, 1.0, accuracy: 0.001) // attempt 0
        backoff.recordFailure()
        XCTAssertEqual(backoff.currentDelay, 2.0, accuracy: 0.001) // attempt 1
        backoff.recordFailure()
        XCTAssertEqual(backoff.currentDelay, 4.0, accuracy: 0.001) // attempt 2
    }

    // MARK: - All Delays

    func testAllDelaysSequence() {
        let config = ReconnectBackoff.Configuration(
            baseDelay: 1.0,
            maxDelay: 10.0,
            multiplier: 2.0,
            jitterFraction: 0,
            maxAttempts: 5
        )
        let backoff = ReconnectBackoff(configuration: config)
        let delays = backoff.allDelays

        XCTAssertEqual(delays.count, 5)
        XCTAssertEqual(delays[0], 1.0, accuracy: 0.001)
        XCTAssertEqual(delays[1], 2.0, accuracy: 0.001)
        XCTAssertEqual(delays[2], 4.0, accuracy: 0.001)
        XCTAssertEqual(delays[3], 8.0, accuracy: 0.001)
        XCTAssertEqual(delays[4], 10.0, accuracy: 0.001) // Capped
    }

    // MARK: - Custom Multiplier

    func testTripleMultiplier() {
        let config = ReconnectBackoff.Configuration(
            baseDelay: 1.0,
            maxDelay: 100.0,
            multiplier: 3.0,
            jitterFraction: 0,
            maxAttempts: 5
        )
        let backoff = ReconnectBackoff(configuration: config)

        XCTAssertEqual(backoff.delay(for: 0), 1.0, accuracy: 0.001)
        XCTAssertEqual(backoff.delay(for: 1), 3.0, accuracy: 0.001)
        XCTAssertEqual(backoff.delay(for: 2), 9.0, accuracy: 0.001)
        XCTAssertEqual(backoff.delay(for: 3), 27.0, accuracy: 0.001)
        XCTAssertEqual(backoff.delay(for: 4), 81.0, accuracy: 0.001)
    }

    // MARK: - Hashable / Equatable

    func testEquality() {
        let a = ReconnectBackoff()
        var b = ReconnectBackoff()
        XCTAssertEqual(a, b)

        b.recordFailure()
        XCTAssertNotEqual(a, b)
    }
}
