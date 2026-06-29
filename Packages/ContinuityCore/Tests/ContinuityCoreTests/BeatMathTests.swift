import XCTest
@testable import ContinuityCore

final class BeatMathTests: XCTestCase {

    func testTempoRatio() {
        XCTAssertEqual(BeatMath.tempoRatio(fromBPM: 124, toBPM: 128), 128.0 / 124.0, accuracy: 1e-9)
        XCTAssertEqual(BeatMath.tempoRatio(fromBPM: 120, toBPM: 120), 1, accuracy: 1e-9)
    }

    func testStretchAcceptability() {
        XCTAssertTrue(BeatMath.isStretchAcceptable(1.03))   // 3%
        XCTAssertTrue(BeatMath.isStretchAcceptable(0.93))   // -7%
        XCTAssertFalse(BeatMath.isStretchAcceptable(1.15))  // 15%, too far
    }

    func testBestTempoRatioPrefersHalfOrDouble() {
        // 170 vs 85: matching straight is a 2x stretch; via double it's exact.
        let ratio = BeatMath.bestTempoRatio(fromBPM: 170, toBPM: 85)
        XCTAssertEqual(ratio, 1, accuracy: 1e-9)
    }

    func testBestTempoRatioStaysCloseToOne() {
        let ratio = BeatMath.bestTempoRatio(fromBPM: 128, toBPM: 64)
        XCTAssertTrue(BeatMath.isStretchAcceptable(ratio))
    }

    func testMatchRateSmallStretchAccepted() {
        // 120 → 124: ~3.3% stretch, accepted.
        XCTAssertEqual(BeatMath.matchRate(incomingBPM: 120, outgoingBPM: 124)!, 124.0 / 120.0, accuracy: 1e-9)
    }

    func testMatchRateUsesDoubleWhenCloser() {
        // 170 incoming vs 86 outgoing → match at the double (172/170), a tiny stretch.
        XCTAssertEqual(BeatMath.matchRate(incomingBPM: 170, outgoingBPM: 86)!, 172.0 / 170.0, accuracy: 1e-9)
    }

    func testMatchRateRejectsTooFar() {
        // 100 → 150: nearest interpretation (0.75) is a 25% stretch → reject (nil).
        XCTAssertNil(BeatMath.matchRate(incomingBPM: 100, outgoingBPM: 150))
    }

    func testMatchRateRejectsUnknownTempo() {
        XCTAssertNil(BeatMath.matchRate(incomingBPM: 0, outgoingBPM: 120))
        XCTAssertNil(BeatMath.matchRate(incomingBPM: 120, outgoingBPM: 0))
    }

    func testSecondsPerBeat() {
        XCTAssertEqual(BeatMath.secondsPerBeat(bpm: 120), 0.5, accuracy: 1e-9)
        XCTAssertEqual(BeatMath.secondsPerBeat(bpm: 60), 1.0, accuracy: 1e-9)
    }

    func testAlignmentStartFrame() {
        // Outgoing beat at 180.0s, incoming downbeat 0.5s into its file, 44.1kHz.
        // Incoming deck must start at (180.0 - 0.5) * 44100 = 7,915,950.
        let frame = BeatMath.alignmentStartFrame(
            outgoingBeatTime: 180.0,
            incomingFirstBeatOffset: 0.5,
            sampleRate: 44_100
        )
        XCTAssertEqual(frame, 7_915_950)
    }

    func testAlignmentCanBeNegativeWhenIntroIsLong() {
        // If the incoming intro is longer than the chosen outgoing beat time, the start
        // frame goes negative -> caller should pick a later outgoing beat.
        let frame = BeatMath.alignmentStartFrame(
            outgoingBeatTime: 0.2,
            incomingFirstBeatOffset: 1.0,
            sampleRate: 48_000
        )
        XCTAssertLessThan(frame, 0)
    }
}
