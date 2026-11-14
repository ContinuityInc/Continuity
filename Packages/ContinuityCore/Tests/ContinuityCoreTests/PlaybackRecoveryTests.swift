import XCTest
@testable import ContinuityCore

/// Pins the recovery scheduling policy: every request path around a route change (engine
/// notification, spurious-change recheck, interruption end, 20 Hz tick) must collapse into
/// one recovery, and attempts must be spaced so a flapping route cannot drive engine
/// start/stop cycles at tick rate.
final class PlaybackRecoveryTests: XCTestCase {
    // MARK: request / fire

    func testFirstRequestSchedulesImmediately() {
        var coalescer = PlaybackRecoveryCoalescer(minimumInterval: 0.25)
        XCTAssertEqual(coalescer.request(force: true, now: 10), 0)
        XCTAssertTrue(coalescer.isScheduled)
        XCTAssertTrue(coalescer.pendingForce)
    }

    func testRequestsWhileScheduledAreFoldedIntoThePendingOne() {
        var coalescer = PlaybackRecoveryCoalescer(minimumInterval: 0.25)
        XCTAssertNotNil(coalescer.request(force: false, now: 10))
        // Tick-rate repeats and the recheck path all land here while one is pending.
        for tick in 1...20 {
            XCTAssertNil(coalescer.request(force: false, now: 10 + Double(tick) * 0.05), "tick \(tick)")
        }
        XCTAssertTrue(coalescer.isScheduled)
    }

    func testForcedRequestUpgradesAPendingSoftOne() {
        var coalescer = PlaybackRecoveryCoalescer(minimumInterval: 0.25)
        _ = coalescer.request(force: false, now: 0)
        XCTAssertFalse(coalescer.pendingForce)
        XCTAssertNil(coalescer.request(force: true, now: 0.01))
        XCTAssertTrue(coalescer.pendingForce)
        XCTAssertTrue(coalescer.fire())
    }

    func testSoftRequestDoesNotDowngradeAPendingForcedOne() {
        var coalescer = PlaybackRecoveryCoalescer(minimumInterval: 0.25)
        _ = coalescer.request(force: true, now: 0)
        XCTAssertNil(coalescer.request(force: false, now: 0.01))
        XCTAssertTrue(coalescer.fire())
    }

    func testFireClearsPendingStateSoTheNextRequestStartsANewCycle() {
        var coalescer = PlaybackRecoveryCoalescer(minimumInterval: 0.25)
        _ = coalescer.request(force: true, now: 0)
        XCTAssertTrue(coalescer.fire())
        XCTAssertFalse(coalescer.isScheduled)
        XCTAssertFalse(coalescer.pendingForce)
        XCTAssertFalse(coalescer.fire(), "nothing pending after a fire")
        XCTAssertNotNil(coalescer.request(force: false, now: 1))
    }

    // MARK: spacing

    func testRequestsSoonAfterAnAttemptAreDelayedToTheMinimumInterval() {
        var coalescer = PlaybackRecoveryCoalescer(minimumInterval: 0.25)
        _ = coalescer.request(force: true, now: 0)
        _ = coalescer.fire()
        coalescer.recordAttempt(now: 0)
        let delay = coalescer.request(force: true, now: 0.1)
        XCTAssertEqual(delay ?? -1, 0.15, accuracy: 1e-9)
    }

    func testRequestsAfterTheIntervalAreImmediate() {
        var coalescer = PlaybackRecoveryCoalescer(minimumInterval: 0.25)
        coalescer.recordAttempt(now: 0)
        XCTAssertEqual(coalescer.request(force: true, now: 0.25), 0)
        _ = coalescer.fire()
        coalescer.recordAttempt(now: 0.25)
        XCTAssertEqual(coalescer.request(force: true, now: 5), 0)
    }

    func testFlappingRouteCannotExceedOneAttemptPerInterval() {
        // Simulate a route that stops the engine right after every recovery, with the tick
        // asking for recovery every 50 ms: the number of attempts must be bounded by the
        // interval, not by the tick rate.
        var coalescer = PlaybackRecoveryCoalescer(minimumInterval: 0.25)
        var now: TimeInterval = 0
        var attempts = 0
        var scheduledAt: TimeInterval?
        while now < 10 {
            if let delay = coalescer.request(force: true, now: now) {
                scheduledAt = now + delay
            }
            if let due = scheduledAt, now >= due {
                _ = coalescer.fire()
                coalescer.recordAttempt(now: now)
                attempts += 1
                scheduledAt = nil
            }
            now += 0.05
        }
        // 10 s / 0.25 s = 40 at the very most (the first attempt is immediate).
        XCTAssertLessThanOrEqual(attempts, 41)
        XCTAssertGreaterThanOrEqual(attempts, 35, "spacing must not starve recovery either")
    }

    func testEarlyBailoutsDoNotDelayTheNextRealRequest() {
        var coalescer = PlaybackRecoveryCoalescer(minimumInterval: 0.25)
        _ = coalescer.request(force: false, now: 0)
        _ = coalescer.fire()
        // The recovery found nothing to do and did not call recordAttempt.
        XCTAssertEqual(coalescer.request(force: true, now: 0.01), 0)
    }

    // MARK: degenerate inputs

    func testNonFiniteClockReadingsNeverProduceNonFiniteDelays() {
        var coalescer = PlaybackRecoveryCoalescer(minimumInterval: 0.25)
        coalescer.recordAttempt(now: .nan)   // ignored
        XCTAssertNil(coalescer.lastAttempt)
        coalescer.recordAttempt(now: 1)
        for now in [Double.nan, .infinity, -.infinity, 0.5 /* clock went backwards */] {
            var copy = coalescer
            let delay = copy.request(force: true, now: now)
            XCTAssertEqual(delay, 0, "now=\(now)")
        }
    }

    func testNonPositiveIntervalDisablesSpacing() {
        for interval in [0.0, -1, .nan, .infinity] {
            var coalescer = PlaybackRecoveryCoalescer(minimumInterval: interval)
            coalescer.recordAttempt(now: 0)
            XCTAssertEqual(coalescer.request(force: true, now: 0.001), 0, "interval=\(interval)")
        }
    }

    // MARK: redundancy

    func testRecoveryIsRedundantOnceTheEngineIsUpAndTheDeckIsRescheduledAndPlaying() {
        XCTAssertTrue(PlaybackRecoveryCoalescer.isRecoveryRedundant(
            engineIsRunning: true, deckNeedsReschedule: false, deckHasTrack: true, isPlaying: true
        ))
    }

    func testRecoveryStillRunsWhenAnythingIsLeftToDo() {
        // Engine still down: the whole point of recovery.
        XCTAssertFalse(PlaybackRecoveryCoalescer.isRecoveryRedundant(
            engineIsRunning: false, deckNeedsReschedule: false, deckHasTrack: true, isPlaying: true
        ))
        // Engine restarted by another path, deck schedule still invalid.
        XCTAssertFalse(PlaybackRecoveryCoalescer.isRecoveryRedundant(
            engineIsRunning: true, deckNeedsReschedule: true, deckHasTrack: true, isPlaying: true
        ))
        // Deck was unloaded by the failure funnel; it has to be reloaded.
        XCTAssertFalse(PlaybackRecoveryCoalescer.isRecoveryRedundant(
            engineIsRunning: true, deckNeedsReschedule: false, deckHasTrack: false, isPlaying: true
        ))
        // Interruption-resume: engine up, schedule valid, but the deck is paused and must start.
        XCTAssertFalse(PlaybackRecoveryCoalescer.isRecoveryRedundant(
            engineIsRunning: true, deckNeedsReschedule: false, deckHasTrack: true, isPlaying: false
        ))
    }

    // MARK: fire-time intent

    func testForcedRecoveryRunsOnlyWhileStillPlaying() {
        XCTAssertTrue(PlaybackRecoveryCoalescer.shouldRunRecovery(
            force: true, isPlaying: true, resumeAfterInterruption: false
        ))
        // User pause (or no-auto-resume unplug) between schedule and fire must win.
        XCTAssertFalse(PlaybackRecoveryCoalescer.shouldRunRecovery(
            force: true, isPlaying: false, resumeAfterInterruption: false
        ))
    }

    func testSoftResumeRunsWhilePaused() {
        XCTAssertTrue(PlaybackRecoveryCoalescer.shouldRunRecovery(
            force: false, isPlaying: false, resumeAfterInterruption: true
        ))
        XCTAssertFalse(PlaybackRecoveryCoalescer.shouldRunRecovery(
            force: false, isPlaying: false, resumeAfterInterruption: false
        ))
    }

    func testPendingSoftResumeKeepsAForcedRequestAliveAfterPause() {
        // Deck-start failure / interruption staged a resume; a forced request that fires after
        // isPlaying flipped false must still run so the deferred resume isn't dropped.
        XCTAssertTrue(PlaybackRecoveryCoalescer.shouldRunRecovery(
            force: true, isPlaying: false, resumeAfterInterruption: true
        ))
    }
}
