import XCTest
@testable import ContinuityCore

final class IngestBackoffTests: XCTestCase {

    private let policy = IngestBackoff.Policy(base: 1, multiplier: 2, cap: 10, jitterFraction: 0.5)

    // MARK: Window growth

    func testWindowDoublesPerAttempt() {
        XCTAssertEqual(IngestBackoff.window(afterAttempt: 1, policy: policy), 1, accuracy: 1e-9)
        XCTAssertEqual(IngestBackoff.window(afterAttempt: 2, policy: policy), 2, accuracy: 1e-9)
        XCTAssertEqual(IngestBackoff.window(afterAttempt: 3, policy: policy), 4, accuracy: 1e-9)
        XCTAssertEqual(IngestBackoff.window(afterAttempt: 4, policy: policy), 8, accuracy: 1e-9)
    }

    func testWindowClampsToCap() {
        XCTAssertEqual(IngestBackoff.window(afterAttempt: 5, policy: policy), 10, accuracy: 1e-9)
        XCTAssertEqual(IngestBackoff.window(afterAttempt: 50, policy: policy), 10, accuracy: 1e-9)
    }

    /// A runaway attempt counter overflows `pow` to infinity; the cap must still hold.
    func testWindowSurvivesOverflowingExponent() {
        let window = IngestBackoff.window(afterAttempt: 5000, policy: policy)
        XCTAssertTrue(window.isFinite)
        XCTAssertEqual(window, 10, accuracy: 1e-9)
    }

    func testAttemptBelowOneTreatedAsFirst() {
        XCTAssertEqual(IngestBackoff.window(afterAttempt: 0, policy: policy), 1, accuracy: 1e-9)
        XCTAssertEqual(IngestBackoff.window(afterAttempt: -7, policy: policy), 1, accuracy: 1e-9)
    }

    // MARK: Jitter

    /// The point of equal jitter: never returns ~0, so a retry can't land inside the same
    /// throttle window it was throttled by.
    func testEqualJitterKeepsHalfTheWindowAsAFloor() {
        for attempt in 1...6 {
            let window = IngestBackoff.window(afterAttempt: attempt, policy: policy)
            let low = IngestBackoff.delay(afterAttempt: attempt, policy: policy, randomFraction: 0)
            let high = IngestBackoff.delay(afterAttempt: attempt, policy: policy, randomFraction: 1)
            XCTAssertEqual(low, window / 2, accuracy: 1e-9)
            XCTAssertEqual(high, window, accuracy: 1e-9)
        }
    }

    func testDelayIsMonotonicInRandomFraction() {
        let a = IngestBackoff.delay(afterAttempt: 3, policy: policy, randomFraction: 0.25)
        let b = IngestBackoff.delay(afterAttempt: 3, policy: policy, randomFraction: 0.75)
        XCTAssertLessThan(a, b)
    }

    func testRandomFractionIsClamped() {
        let window = IngestBackoff.window(afterAttempt: 2, policy: policy)
        XCTAssertEqual(IngestBackoff.delay(afterAttempt: 2, policy: policy, randomFraction: -5), window / 2, accuracy: 1e-9)
        XCTAssertEqual(IngestBackoff.delay(afterAttempt: 2, policy: policy, randomFraction: 5), window, accuracy: 1e-9)
    }

    func testZeroJitterFractionGivesFixedDelay() {
        let fixed = IngestBackoff.Policy(base: 2, multiplier: 2, cap: 100, jitterFraction: 0)
        XCTAssertEqual(IngestBackoff.delay(afterAttempt: 3, policy: fixed, randomFraction: 0), 8, accuracy: 1e-9)
        XCTAssertEqual(IngestBackoff.delay(afterAttempt: 3, policy: fixed, randomFraction: 1), 8, accuracy: 1e-9)
    }

    func testFullJitterFractionSpansWholeWindow() {
        let full = IngestBackoff.Policy(base: 2, multiplier: 2, cap: 100, jitterFraction: 1)
        XCTAssertEqual(IngestBackoff.delay(afterAttempt: 1, policy: full, randomFraction: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(IngestBackoff.delay(afterAttempt: 1, policy: full, randomFraction: 1), 2, accuracy: 1e-9)
    }

    // MARK: Policy invariants

    func testPolicyClampsDegenerateInputs() {
        let p = IngestBackoff.Policy(base: -1, multiplier: 0.2, cap: -3, jitterFraction: 4)
        XCTAssertEqual(p.base, 0)
        XCTAssertEqual(p.multiplier, 1)     // never shrink
        XCTAssertEqual(p.cap, 0)
        XCTAssertEqual(p.jitterFraction, 1)
    }

    /// Rate limits must start far enough out that the retry isn't inside the same window —
    /// the old code retried a 429 after 1.5s, which is what poisoned whole playlist imports.
    func testRateLimitPolicyStartsWellBeyondTheThrottleWindow() {
        let first = IngestBackoff.delay(afterAttempt: 1, policy: .rateLimited, randomFraction: 0)
        XCTAssertGreaterThanOrEqual(first, 3)
        XCTAssertGreaterThan(IngestBackoff.Policy.rateLimited.cap, IngestBackoff.Policy.request.cap)
    }

    func testTrackPolicyOutlastsABotDetectionWindow() {
        // Four whole-track attempts should span minutes, not seconds.
        let total = (1...4).reduce(0.0) {
            $0 + IngestBackoff.delay(afterAttempt: $1, policy: .track, randomFraction: 0)
        }
        XCTAssertGreaterThan(total, 120)
    }

    // MARK: Budget

    func testIsFinalAttempt() {
        XCTAssertFalse(IngestBackoff.isFinalAttempt(1, maxAttempts: 3))
        XCTAssertFalse(IngestBackoff.isFinalAttempt(2, maxAttempts: 3))
        XCTAssertTrue(IngestBackoff.isFinalAttempt(3, maxAttempts: 3))
        XCTAssertTrue(IngestBackoff.isFinalAttempt(9, maxAttempts: 3))
        XCTAssertTrue(IngestBackoff.isFinalAttempt(1, maxAttempts: 0))  // degenerate budget → one shot
    }
}
