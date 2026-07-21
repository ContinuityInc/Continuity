import XCTest
@testable import Playback

@MainActor
final class PlayerTransitionRecoveryTests: XCTestCase {
    func testClearingTransitionStateDoesNotMaterializeAudioStack() {
        let player = Player()
        player.currentIndex = 2
        player.transitionTargetIndex = 3
        player.activeTransitionDurationSeconds = 5
        player.isUserInitiatedSkipTransition = true
        player.incomingStartOffset = 1.5
        player.incomingPitchShiftSemitones = 1
        player.incomingRate = 1.05
        player.transitionProgress = 0.4
        player.isTransitioning = true

        player.clearTransitionState()

        XCTAssertFalse(player.isTransitioning)
        XCTAssertEqual(player.transitionTargetIndex, player.currentIndex)
        XCTAssertEqual(player.activeTransitionDurationSeconds, 0)
        XCTAssertFalse(player.isUserInitiatedSkipTransition)
        XCTAssertEqual(player.incomingStartOffset, 0)
        XCTAssertEqual(player.incomingPitchShiftSemitones, 0)
        XCTAssertEqual(player.incomingRate, 1)
        XCTAssertEqual(player.transitionProgress, 0)
        XCTAssertNil(player.audio)
    }
}
