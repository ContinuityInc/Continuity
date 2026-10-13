import XCTest
import Domain
@testable import Playback

/// Pins the "no non-finite number ever leaves the player" invariant.
///
/// Around a route or audio-configuration change — AirPods connecting, a car stereo, a jostled
/// cable, all of which correlate with the phone moving — the render clock can report an unset
/// sample rate, and `sampleTime / 0` is `.infinity` in Swift rather than an error. Everything
/// downstream traps on that rather than degrading: `Double` → `AVAudioFramePosition` traps on a
/// non-finite value, and so do SwiftUI's layout and `Shape.trim`. `min`/`max` are no defence,
/// because `min(NaN, 1)` is NaN.
///
/// These tests poison the clock directly and assert the published values stay usable. None of
/// them materializes the audio stack.
@MainActor
final class PlayerClockSafetyTests: XCTestCase {

    private func makeTrack(sortIndex: Int = 0) -> Track {
        Track(title: "T\(sortIndex)", artist: "Test", durationSeconds: 180,
              gradientSeed: sortIndex, sortIndex: sortIndex)
    }

    private func stagedPlayer(trackCount: Int = 2) -> Player {
        let player = Player()
        player.queue = (0..<trackCount).map { makeTrack(sortIndex: $0) }
        player.currentIndex = 0
        return player
    }

    func testFractionClampsAndRejectsNonFinite() {
        XCTAssertEqual(Player.fraction(0.25), 0.25)
        XCTAssertEqual(Player.fraction(-3), 0)
        XCTAssertEqual(Player.fraction(4), 1)
        XCTAssertEqual(Player.fraction(.nan), 0)
        XCTAssertEqual(Player.fraction(.infinity), 0)
        XCTAssertEqual(Player.fraction(-.infinity), 0)
    }

    func testFiniteAndClampedSecondsRejectNonFinite() {
        XCTAssertEqual(Player.finite(12), 12)
        XCTAssertEqual(Player.finite(.nan), 0)
        XCTAssertEqual(Player.finite(.infinity, fallback: -1), -1)
        XCTAssertEqual(Player.clampedSeconds(30, upperBound: 100), 30)
        XCTAssertEqual(Player.clampedSeconds(-5, upperBound: 100), 0)
        XCTAssertEqual(Player.clampedSeconds(200, upperBound: 100), 100)
        XCTAssertEqual(Player.clampedSeconds(.nan, upperBound: 100), 0)
        XCTAssertEqual(Player.clampedSeconds(50, upperBound: .nan), 50)
    }

    func testDisplayProgressStaysFiniteForAPoisonedPosition() {
        let player = stagedPlayer()
        for poison in [Double.nan, .infinity, -.infinity, -5] {
            player.position = poison
            let progress = player.displayProgress
            XCTAssertTrue(progress.isFinite, "displayProgress went non-finite for \(poison)")
            XCTAssertGreaterThanOrEqual(progress, 0)
            XCTAssertLessThanOrEqual(progress, 1)
        }
    }

    func testDurationIsAlwaysFinite() {
        let player = stagedPlayer()
        XCTAssertTrue(player.duration.isFinite)
        player.queue[0].durationSeconds = .infinity
        XCTAssertTrue(player.duration.isFinite, "an unusable track length must read as zero, not infinity")
        player.queue[0].durationSeconds = .nan
        XCTAssertTrue(player.duration.isFinite)
    }

    /// `Int(_: Double)` traps on infinity and NaN, so the 1 Hz countdown mirror has to clamp
    /// before converting. A negative-infinity position makes the countdown itself infinite.
    func testTransitionCountdownSurvivesAPoisonedPosition() {
        let player = stagedPlayer()
        for poison in [Double.nan, .infinity, -.infinity] {
            player.position = poison
            player.refreshTransitionCountdown()
            if let seconds = player.transitionCountdownSeconds {
                XCTAssertGreaterThanOrEqual(seconds, 0)
                XCTAssertLessThanOrEqual(seconds, 86_400)
            }
        }
    }

    /// A non-finite scrub target is not a position: it must be ignored, not reinterpreted as
    /// zero, because every path out of `seek` ends in a frame conversion.
    func testSeekIgnoresNonFiniteTargets() {
        let player = stagedPlayer()
        player.position = 42
        player.seek(to: .nan)
        XCTAssertEqual(player.position, 42)
        player.seek(to: .infinity)
        XCTAssertEqual(player.position, 42)
        player.seek(to: 30)
        XCTAssertEqual(player.position, 30, "a real seek must still land")
    }

    /// A corrupt persisted position must not stage NaN onto `position` / `pendingSeekSeconds`.
    func testRestoreRejectsNonFinitePosition() {
        let player = stagedPlayer()
        let track = player.queue[0]
        let state = PersistedPlaybackState(
            queueTrackIDs: player.queue.map(\.id),
            currentIndex: 0,
            positionSeconds: .nan,
            skipsRemaining: 3,
            historyTrackIDs: []
        )
        player.restore(state, resolving: [track.id: track])
        XCTAssertTrue(player.position.isFinite)
        XCTAssertEqual(player.position, 0)
        XCTAssertNil(player.pendingSeekSeconds)
    }

    /// Pre-play queue edits must not arm stem preparation (ORT jetsam at cold launch).
    func testNotifyUpcomingNoopsBeforeAudioStarts() {
        let player = stagedPlayer()
        var notified = 0
        player.onUpcomingTracks = { _ in notified += 1 }
        player.notifyUpcoming()
        XCTAssertEqual(notified, 0, "stems must stay cold until the first real play")
        player.audioHasStartedThisProcess = true
        player.notifyUpcoming()
        XCTAssertEqual(notified, 1)
    }
}
