import XCTest
@testable import ContinuityCore

final class TransitionPlanTests: XCTestCase {

    private let plan = TransitionPlan(curve: .equalPower, duration: 8)

    func testShouldStartAtTheRightMoment() {
        // 200s track, 8s blend → start at 192s.
        XCTAssertFalse(plan.shouldStart(position: 191, trackDuration: 200, hasNextTrack: true))
        XCTAssertTrue(plan.shouldStart(position: 192, trackDuration: 200, hasNextTrack: true))
        XCTAssertTrue(plan.shouldStart(position: 199, trackDuration: 200, hasNextTrack: true))
    }

    func testNoTransitionWithoutNextTrack() {
        XCTAssertFalse(plan.shouldStart(position: 199, trackDuration: 200, hasNextTrack: false))
    }

    func testNoTransitionWhenTrackShorterThanBlend() {
        // 5s track, 8s blend → never crossfade.
        XCTAssertFalse(plan.shouldStart(position: 4.9, trackDuration: 5, hasNextTrack: true))
        // Exact equality is also "not meaningfully longer" — hard-advance, don't blend.
        XCTAssertFalse(plan.shouldStart(position: 8, trackDuration: 8, hasNextTrack: true))
    }

    func testZeroDurationNeverCrossfades() {
        let hardCut = TransitionPlan(curve: .equalPower, duration: 0)
        XCTAssertFalse(hardCut.shouldStart(position: 199, trackDuration: 200, hasNextTrack: true))
        // Progress collapses to complete immediately.
        XCTAssertEqual(hardCut.progress(position: 100, startPosition: 100), 1, accuracy: 1e-9)
    }

    func testNegativeDurationClampsToHardCut() {
        let clamped = TransitionPlan(curve: .equalPower, duration: -4)
        XCTAssertEqual(clamped.duration, 0)
        XCTAssertFalse(clamped.shouldStart(position: 199, trackDuration: 200, hasNextTrack: true))
        XCTAssertEqual(clamped.progress(position: 10, startPosition: 0), 1, accuracy: 1e-9)
    }

    func testShouldStartRejectsNonFiniteClocks() {
        // Poisoned deck / duration clocks must not trigger a blend (NaN comparisons are false,
        // but pin the refusal explicitly so a future rewrite can't flip it).
        XCTAssertFalse(plan.shouldStart(position: .nan, trackDuration: 200, hasNextTrack: true))
        XCTAssertFalse(plan.shouldStart(position: .infinity, trackDuration: 200, hasNextTrack: true))
        XCTAssertFalse(plan.shouldStart(position: -.infinity, trackDuration: 200, hasNextTrack: true))
        XCTAssertFalse(plan.shouldStart(position: 199, trackDuration: .nan, hasNextTrack: true))
        XCTAssertFalse(plan.shouldStart(position: 199, trackDuration: .infinity, hasNextTrack: true))
        XCTAssertFalse(plan.shouldStart(position: 199, trackDuration: -.infinity, hasNextTrack: true))
        XCTAssertFalse(plan.shouldStart(position: 199, trackDuration: 0, hasNextTrack: true))
        XCTAssertFalse(plan.shouldStart(position: 199, trackDuration: -1, hasNextTrack: true))

        let infiniteBlend = TransitionPlan(curve: .equalPower, duration: .infinity)
        XCTAssertFalse(infiniteBlend.shouldStart(position: 199, trackDuration: 200, hasNextTrack: true))
        let nanBlend = TransitionPlan(curve: .equalPower, duration: .nan)
        XCTAssertFalse(nanBlend.shouldStart(position: 199, trackDuration: 200, hasNextTrack: true))
    }

    func testProgressIsClampedAndLinearInTime() {
        XCTAssertEqual(plan.progress(position: 192, startPosition: 192), 0, accuracy: 1e-9)
        XCTAssertEqual(plan.progress(position: 196, startPosition: 192), 0.5, accuracy: 1e-9)
        XCTAssertEqual(plan.progress(position: 200, startPosition: 192), 1, accuracy: 1e-9)
        XCTAssertEqual(plan.progress(position: 210, startPosition: 192), 1, accuracy: 1e-9) // clamped
        XCTAssertEqual(plan.progress(position: 190, startPosition: 192), 0, accuracy: 1e-9) // clamped
    }

    func testProgressRejectsNonFiniteInputs() {
        // A poisoned deck clock must not produce NaN progress (min/max do not clear NaN).
        XCTAssertEqual(plan.progress(position: .nan, startPosition: 192), 0, accuracy: 1e-9)
        XCTAssertEqual(plan.progress(position: .infinity, startPosition: 192), 0, accuracy: 1e-9)
        XCTAssertEqual(plan.progress(position: -.infinity, startPosition: 192), 0, accuracy: 1e-9)
        XCTAssertEqual(plan.progress(position: 196, startPosition: .nan), 0, accuracy: 1e-9)
        XCTAssertEqual(plan.progress(position: 196, startPosition: .infinity), 0, accuracy: 1e-9)
        XCTAssertEqual(plan.progress(position: 196, startPosition: -.infinity), 0, accuracy: 1e-9)
        let badDuration = TransitionPlan(curve: .equalPower, duration: .nan)
        XCTAssertEqual(badDuration.progress(position: 10, startPosition: 0), 1, accuracy: 1e-9)
        let infDuration = TransitionPlan(curve: .equalPower, duration: .infinity)
        XCTAssertEqual(infDuration.progress(position: 10, startPosition: 0), 1, accuracy: 1e-9)
        let negInfDuration = TransitionPlan(curve: .equalPower, duration: -.infinity)
        // init clamps negative to 0 → hard-cut progress of 1.
        XCTAssertEqual(negInfDuration.duration, 0)
        XCTAssertEqual(negInfDuration.progress(position: 10, startPosition: 0), 1, accuracy: 1e-9)
    }

    func testGainsAndCompletionStayFiniteUnderPoisonedClocks() {
        let poisons: [TimeInterval] = [.nan, .infinity, -.infinity]
        for position in poisons {
            for start in poisons + [192] {
                let t = plan.progress(position: position, startPosition: start)
                XCTAssertTrue(t.isFinite, "progress \(position)/\(start)")
                XCTAssertGreaterThanOrEqual(t, 0)
                XCTAssertLessThanOrEqual(t, 1)
                let g = plan.gains(position: position, startPosition: start)
                XCTAssertTrue(g.outgoing.isFinite && g.incoming.isFinite, "gains \(position)/\(start)")
                // Non-finite clocks collapse progress to 0 → hold on outgoing, don't claim done.
                if !position.isFinite || !start.isFinite {
                    XCTAssertEqual(t, 0, accuracy: 1e-9)
                    XCTAssertFalse(plan.isComplete(position: position, startPosition: start))
                    XCTAssertEqual(g.outgoing, 1, accuracy: 1e-9)
                    XCTAssertEqual(g.incoming, 0, accuracy: 1e-9)
                }
            }
        }
    }

    func testGainsAreEqualPowerAtMidpoint() {
        let g = plan.gains(position: 196, startPosition: 192) // t = 0.5
        XCTAssertEqual(g.outgoing, cos(.pi / 4), accuracy: 1e-9)
        XCTAssertEqual(g.incoming, sin(.pi / 4), accuracy: 1e-9)
        XCTAssertEqual(g.outgoing * g.outgoing + g.incoming * g.incoming, 1, accuracy: 1e-9)
    }

    func testEndpointsHandOff() {
        let start = plan.gains(position: 192, startPosition: 192)
        XCTAssertEqual(start.outgoing, 1, accuracy: 1e-9)
        XCTAssertEqual(start.incoming, 0, accuracy: 1e-9)
        let end = plan.gains(position: 200, startPosition: 192)
        XCTAssertEqual(end.outgoing, 0, accuracy: 1e-9)
        XCTAssertEqual(end.incoming, 1, accuracy: 1e-9)
        XCTAssertTrue(plan.isComplete(position: 200, startPosition: 192))
        XCTAssertFalse(plan.isComplete(position: 199, startPosition: 192))
    }
}
