import XCTest
@testable import ContinuityCore

final class TransitionFeedbackTests: XCTestCase {

    func testNoVotesMeansNoSimplification() {
        XCTAssertEqual(TransitionFeedback.simplificationLevel(votes: []), 0)
    }

    func testUpvotesNeverSimplify() {
        XCTAssertEqual(TransitionFeedback.simplificationLevel(votes: [true]), 0)
        XCTAssertEqual(TransitionFeedback.simplificationLevel(votes: [true, true, true]), 0)
    }

    func testEachDownvoteAddsALevel() {
        XCTAssertEqual(TransitionFeedback.simplificationLevel(votes: [false]), 1)
        XCTAssertEqual(TransitionFeedback.simplificationLevel(votes: [false, false]), 2)
        XCTAssertEqual(TransitionFeedback.simplificationLevel(votes: [false, false, false]), 3)
    }

    func testLevelClampsAtMax() {
        let votes = Array(repeating: false, count: 6)
        XCTAssertEqual(
            TransitionFeedback.simplificationLevel(votes: votes),
            TransitionFeedback.maxSimplificationLevel
        )
    }

    func testUpvotesCancelDownvotes() {
        XCTAssertEqual(TransitionFeedback.simplificationLevel(votes: [false, true]), 0)
        XCTAssertEqual(TransitionFeedback.simplificationLevel(votes: [false, false, true]), 1)
        // Net can't go below zero: extra upvotes don't bank credit against future downvotes
        // beyond the window's contents.
        XCTAssertEqual(TransitionFeedback.simplificationLevel(votes: [true, true, false]), 0)
    }

    func testOldVotesFallOutOfTheWindow() {
        // 8 old downvotes followed by `voteWindow` upvotes: the window sees only upvotes.
        let votes = Array(repeating: false, count: 8) + Array(repeating: true, count: TransitionFeedback.voteWindow)
        XCTAssertEqual(TransitionFeedback.simplificationLevel(votes: votes), 0)
    }

    func testRecoveryOneNotchAtATime() {
        // A hated pair (3 downs) improves with each upvote.
        var votes: [Bool] = [false, false, false]
        XCTAssertEqual(TransitionFeedback.simplificationLevel(votes: votes), 3)
        votes.append(true)
        XCTAssertEqual(TransitionFeedback.simplificationLevel(votes: votes), 2)
        votes.append(true)
        XCTAssertEqual(TransitionFeedback.simplificationLevel(votes: votes), 1)
        votes.append(true)
        XCTAssertEqual(TransitionFeedback.simplificationLevel(votes: votes), 0)
    }
}
