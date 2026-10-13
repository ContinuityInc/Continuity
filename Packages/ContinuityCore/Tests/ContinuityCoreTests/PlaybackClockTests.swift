import XCTest
@testable import ContinuityCore

/// Pins the clock arithmetic behind every "transient" playback crash so a regression fails on
/// Linux CI instead of on the owner's phone. Each degenerate input here is one that a disturbed
/// AVAudio render clock has actually produced (route change, engine restart, corrupt header).
final class PlaybackClockTests: XCTestCase {
    // MARK: elapsedSeconds

    func testElapsedSecondsHappyPath() {
        XCTAssertEqual(PlaybackClock.elapsedSeconds(sampleTime: 44_100, sampleRate: 44_100), 1, accuracy: 1e-9)
        XCTAssertEqual(PlaybackClock.elapsedSeconds(sampleTime: 0, sampleRate: 48_000), 0)
    }

    func testElapsedSecondsRefusesUnsetSampleRate() {
        // `sampleTime / 0` is `.infinity` in Swift, not an error — the route-change crash class.
        XCTAssertEqual(PlaybackClock.elapsedSeconds(sampleTime: 44_100, sampleRate: 0), 0)
        XCTAssertEqual(PlaybackClock.elapsedSeconds(sampleTime: 44_100, sampleRate: -44_100), 0)
        XCTAssertEqual(PlaybackClock.elapsedSeconds(sampleTime: 44_100, sampleRate: .nan), 0)
        XCTAssertEqual(PlaybackClock.elapsedSeconds(sampleTime: 44_100, sampleRate: .infinity), 0)
    }

    func testElapsedSecondsRefusesNegativeSampleTime() {
        // Player time can lag node time right after a reschedule → negative sample position.
        XCTAssertEqual(PlaybackClock.elapsedSeconds(sampleTime: -512, sampleRate: 44_100), 0)
    }

    func testElapsedSecondsIsAlwaysFiniteAndNonNegative() {
        for sampleTime in [Int64.min, -1, 0, 1, Int64.max] {
            for rate in [-1.0, 0, 1e-300, 1e300, 44_100, .nan, .infinity, -.infinity] {
                let seconds = PlaybackClock.elapsedSeconds(sampleTime: sampleTime, sampleRate: rate)
                XCTAssertTrue(seconds.isFinite, "\(sampleTime)/\(rate)")
                XCTAssertGreaterThanOrEqual(seconds, 0, "\(sampleTime)/\(rate)")
            }
        }
    }

    // MARK: durationSeconds

    func testDurationSeconds() {
        XCTAssertEqual(PlaybackClock.durationSeconds(frameLength: 88_200, sampleRate: 44_100), 2, accuracy: 1e-9)
        XCTAssertEqual(PlaybackClock.durationSeconds(frameLength: 88_200, sampleRate: 0), 0)
        XCTAssertEqual(PlaybackClock.durationSeconds(frameLength: 0, sampleRate: 44_100), 0)
        XCTAssertEqual(PlaybackClock.durationSeconds(frameLength: -1, sampleRate: 44_100), 0)
        XCTAssertEqual(PlaybackClock.durationSeconds(frameLength: 1, sampleRate: .nan), 0)
    }

    // MARK: segment

    func testSegmentSeeksInsideFile() throws {
        let seg = try XCTUnwrap(PlaybackClock.segment(seconds: 2, sampleRate: 44_100, frameLength: 441_000))
        XCTAssertEqual(seg.startFrame, 88_200)
        XCTAssertEqual(seg.frameCount, 441_000 - 88_200)
    }

    func testSegmentClampsNegativeAndNonFiniteToStart() throws {
        for seconds in [-5.0, .nan, -.infinity] {
            let seg = try XCTUnwrap(PlaybackClock.segment(seconds: seconds, sampleRate: 44_100, frameLength: 1_000))
            XCTAssertEqual(seg.startFrame, 0, "\(seconds)")
            XCTAssertEqual(seg.frameCount, 1_000, "\(seconds)")
        }
    }

    func testSegmentPastEndIsNil() {
        // `scheduleSegment` with a zero frame count raises; "nothing left to play" is nil.
        XCTAssertNil(PlaybackClock.segment(seconds: 10, sampleRate: 44_100, frameLength: 441_000))
        XCTAssertNil(PlaybackClock.segment(seconds: 1e300, sampleRate: 44_100, frameLength: 441_000))
        // +inf is "not a position", not "past the end": it restarts the file like NaN does.
        XCTAssertEqual(PlaybackClock.segment(seconds: .infinity, sampleRate: 44_100, frameLength: 441_000)?.startFrame, 0)
    }

    func testSegmentRefusesUnusableFormat() {
        XCTAssertNil(PlaybackClock.segment(seconds: 1, sampleRate: 0, frameLength: 441_000))
        XCTAssertNil(PlaybackClock.segment(seconds: 1, sampleRate: .nan, frameLength: 441_000))
        XCTAssertNil(PlaybackClock.segment(seconds: 1, sampleRate: 44_100, frameLength: 0))
        XCTAssertNil(PlaybackClock.segment(seconds: 1, sampleRate: 44_100, frameLength: -10))
    }

    func testSegmentSaturatesFrameCountAtUInt32() throws {
        // A corrupt header claiming more frames than AVAudioFrameCount can hold used to trap
        // in `AVAudioFrameCount(file.length - startFrame)`.
        let huge = Int64(UInt32.max) * 4
        let seg = try XCTUnwrap(PlaybackClock.segment(seconds: 0, sampleRate: 44_100, frameLength: huge))
        XCTAssertEqual(seg.startFrame, 0)
        XCTAssertEqual(seg.frameCount, UInt32.max)
    }

    func testSegmentNeverTrapsOnAdversarialInput() {
        let seconds: [Double] = [-1e308, -1, 0, 0.5, 1e-9, 1e308, .nan, .infinity, -.infinity]
        let rates: [Double] = [-1, 0, 1e-300, 8_000, 44_100, 192_000, 1e300, .nan, .infinity]
        let lengths: [Int64] = [Int64.min, -1, 0, 1, 1_000, Int64(UInt32.max), Int64.max]
        for s in seconds { for r in rates { for l in lengths {
            if let seg = PlaybackClock.segment(seconds: s, sampleRate: r, frameLength: l) {
                XCTAssertGreaterThanOrEqual(seg.startFrame, 0)
                XCTAssertLessThan(seg.startFrame, l)
                XCTAssertGreaterThan(seg.frameCount, 0)
            }
        } } }
    }

    // MARK: isRenderClockUsable

    func testRenderClockFromPreviousEngineRunIsRejected() {
        XCTAssertFalse(PlaybackClock.isRenderClockUsable(
            renderHostTime: 950, engineStartedAtHostTime: 1_000, now: 1_010, maximumAge: 100))
    }

    func testRenderClockFromCurrentEngineRunIsAccepted() {
        XCTAssertTrue(PlaybackClock.isRenderClockUsable(
            renderHostTime: 1_005, engineStartedAtHostTime: 1_000, now: 1_010, maximumAge: 100))
    }

    func testFutureAndExpiredRenderClocksAreRejected() {
        XCTAssertFalse(PlaybackClock.isRenderClockUsable(
            renderHostTime: 1_020, engineStartedAtHostTime: 1_000, now: 1_010, maximumAge: 100))
        XCTAssertFalse(PlaybackClock.isRenderClockUsable(
            renderHostTime: 1_005, engineStartedAtHostTime: 1_000, now: 1_200, maximumAge: 100))
    }

    func testRenderClockBoundaryValuesDoNotOverflow() {
        // `now - renderHostTime` is unsigned; the `renderHostTime <= now` check must come first.
        XCTAssertFalse(PlaybackClock.isRenderClockUsable(
            renderHostTime: UInt64.max, engineStartedAtHostTime: 0, now: 0, maximumAge: 1))
        XCTAssertTrue(PlaybackClock.isRenderClockUsable(
            renderHostTime: UInt64.max - 1, engineStartedAtHostTime: UInt64.max - 1,
            now: UInt64.max, maximumAge: 2))
    }

    // MARK: TimePitchLimits

    func testRateClampAndNonFinite() {
        XCTAssertEqual(TimePitchLimits.clampRate(1.04), 1.04)
        XCTAssertEqual(TimePitchLimits.clampRate(0), TimePitchLimits.minimumRate)
        XCTAssertEqual(TimePitchLimits.clampRate(-3), TimePitchLimits.minimumRate)
        XCTAssertEqual(TimePitchLimits.clampRate(40), TimePitchLimits.maximumRate)
        XCTAssertEqual(TimePitchLimits.clampRate(.nan), 1)
        XCTAssertEqual(TimePitchLimits.clampRate(.infinity), 1)
    }

    func testPitchClampAndNonFinite() {
        XCTAssertEqual(TimePitchLimits.clampPitchCents(100), 100)
        XCTAssertEqual(TimePitchLimits.clampPitchCents(-100), -100)
        XCTAssertEqual(TimePitchLimits.clampPitchCents(5_000), TimePitchLimits.maximumPitchCents)
        XCTAssertEqual(TimePitchLimits.clampPitchCents(-5_000), -TimePitchLimits.maximumPitchCents)
        XCTAssertEqual(TimePitchLimits.clampPitchCents(.nan), 0)
        XCTAssertEqual(TimePitchLimits.clampPitchCents(-.infinity), 0)
    }

    func testBeatmatchOutputsAlwaysInsideRateClamp() {
        // Whatever BeatMath produces for sane BPMs must already be inside the clamp, so the
        // clamp is a safety net and never changes a real beatmatch.
        for incoming in stride(from: 60.0, through: 200.0, by: 7) {
            for outgoing in stride(from: 60.0, through: 200.0, by: 11) {
                guard let rate = BeatMath.matchRate(incomingBPM: incoming, outgoingBPM: outgoing) else { continue }
                XCTAssertEqual(TimePitchLimits.clampRate(Float(rate)), Float(rate), accuracy: 1e-6)
            }
        }
    }
}
