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
    }

    func testZeroDurationNeverCrossfades() {
        let hardCut = TransitionPlan(curve: .equalPower, duration: 0)
        XCTAssertFalse(hardCut.shouldStart(position: 199, trackDuration: 200, hasNextTrack: true))
        // Progress collapses to complete immediately.
        XCTAssertEqual(hardCut.progress(position: 100, startPosition: 100), 1, accuracy: 1e-9)
    }

    func testProgressIsClampedAndLinearInTime() {
        XCTAssertEqual(plan.progress(position: 192, startPosition: 192), 0, accuracy: 1e-9)
        XCTAssertEqual(plan.progress(position: 196, startPosition: 192), 0.5, accuracy: 1e-9)
        XCTAssertEqual(plan.progress(position: 200, startPosition: 192), 1, accuracy: 1e-9)
        XCTAssertEqual(plan.progress(position: 210, startPosition: 192), 1, accuracy: 1e-9) // clamped
        XCTAssertEqual(plan.progress(position: 190, startPosition: 192), 0, accuracy: 1e-9) // clamped
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
