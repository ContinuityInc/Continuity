import XCTest
import Domain
@testable import Playback

@MainActor
final class PlayerPreviousSkipTests: XCTestCase {
    private func makeTrack(title: String, sortIndex: Int) -> Track {
        Track(
            title: title,
            artist: "Test",
            durationSeconds: 180,
            gradientSeed: sortIndex,
            sortIndex: sortIndex
        )
    }

    /// A second previous() press while a user skip blend is still in flight must be a no-op: acting
    /// on it would cancel the blend, walk the history a second time (dropping the entry the first
    /// press already consumed), and double-refund the forward skip. It must also not materialize the
    /// audio stack — the guard returns before any deck work, mirroring next().
    func testPreviousDuringUserSkipIsIgnored() {
        let player = Player()
        let a = makeTrack(title: "A", sortIndex: 0)
        let b = makeTrack(title: "B", sortIndex: 1)
        player.queue = [a, b]
        player.currentIndex = 1
        player.historyIDs = [a.id]
        player.skipsRemaining = 1
        player.transitionTargetIndex = 0
        player.isUserInitiatedSkipTransition = true
        player.isTransitioning = true

        player.previous()

        // Nothing consumed, nothing refunded, no engine built, blend left intact.
        XCTAssertEqual(player.historyIDs, [a.id])
        XCTAssertEqual(player.skipsRemaining, 1)
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertTrue(player.isTransitioning)
        XCTAssertTrue(player.isUserInitiatedSkipTransition)
        XCTAssertNil(player.audio)
    }
}
