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

    func testIncomingStartOffsetAlignsToOutgoingBeat() {
        // Outgoing at 10.0s; beats every 0.5s (120 BPM). Incoming beats every 0.5s from 0.
        // Next outgoing beat >= 10.08 is 10.5 -> lead 0.5s. rate 1 -> target 0.5s. First incoming
        // beat >= 0.5 is 0.5 -> offset 0. Playing from 0, the incoming beat at 0.5 lands at t=0.5
        // == the outgoing beat. Verify the grids stay phase-locked from there.
        let out = stride(from: 0.0, through: 20.0, by: 0.5).map { $0 }
        let inc = stride(from: 0.0, through: 20.0, by: 0.5).map { $0 }
        let offset = BeatMath.incomingStartOffset(outgoingPosition: 10.0, outgoingBeats: out, incomingBeats: inc)!
        XCTAssertEqual(offset, 0.0, accuracy: 1e-9)

        // After the offset seek, the incoming beat reached `lead` seconds later coincides with the
        // outgoing beat — i.e. (inBeat - offset)/rate == lead.
        let lead = 0.5
        XCTAssertEqual((0.5 - offset) / 1.0, lead, accuracy: 1e-9)
    }

    func testIncomingStartOffsetSeeksToPhaseAlign() {
        // Incoming grid offset by 0.2s (beats at 0.2, 0.7, 1.2, …) against an on-grid outgoing.
        // Outgoing at 4.0; next beat 4.5 -> lead 0.5, target 0.5. First incoming beat >= 0.5 is 0.7,
        // so seek 0.2s in so that 0.7 is reached exactly 0.5s after start.
        let out = stride(from: 0.0, through: 10.0, by: 0.5).map { $0 }
        let inc = stride(from: 0.2, through: 10.0, by: 0.5).map { $0 }
        let offset = BeatMath.incomingStartOffset(outgoingPosition: 4.0, outgoingBeats: out, incomingBeats: inc)!
        XCTAssertEqual(offset, 0.2, accuracy: 1e-9)
    }

    func testIncomingStartOffsetAccountsForRate() {
        // With rate 2 the incoming plays twice as fast, so `target` (file-seconds before the beat)
        // doubles. Outgoing at 0.0; next beat 0.5 -> lead 0.5; target = 0.5*2 = 1.0. First incoming
        // beat >= 1.0 is 1.0 -> offset 0.
        let out = stride(from: 0.0, through: 5.0, by: 0.5).map { $0 }
        let inc = stride(from: 0.0, through: 5.0, by: 0.5).map { $0 }
        let offset = BeatMath.incomingStartOffset(outgoingPosition: 0.0, outgoingBeats: out, incomingBeats: inc, rate: 2)!
        XCTAssertEqual(offset, 0.0, accuracy: 1e-9)
    }

    func testIncomingStartOffsetAccountsForOutgoingRate() {
        // The outgoing deck itself plays at rate 2 (a persisted beatmatch), so its file-time lead
        // passes in half the real time. Outgoing at 0.0; next beat >= minLead*2 = 0.16 is 0.5 ->
        // file lead 0.5 -> real lead 0.25. Incoming at rate 1 -> target 0.25 file-seconds. First
        // incoming beat >= 0.25 is 0.3 -> offset 0.05.
        let out = stride(from: 0.0, through: 5.0, by: 0.5).map { $0 }
        let inc = stride(from: 0.3, through: 5.0, by: 0.5).map { $0 }
        let offset = BeatMath.incomingStartOffset(
            outgoingPosition: 0.0, outgoingBeats: out, incomingBeats: inc, outgoingRate: 2)!
        XCTAssertEqual(offset, 0.05, accuracy: 1e-9)
    }

    func testIncomingStartOffsetOutgoingRateScalesMinLead() {
        // minLead is real time; at outgoingRate 2 a file-time gap of 0.1s passes in only 0.05s of
        // real time (< default minLead 0.08), so the 0.1 beat must be skipped for the 0.5 one.
        let out = [0.1, 0.5, 1.0, 1.5]
        let inc = stride(from: 0.0, through: 5.0, by: 0.25).map { $0 }
        let offset = BeatMath.incomingStartOffset(
            outgoingPosition: 0.0, outgoingBeats: out, incomingBeats: inc, outgoingRate: 2)!
        // File lead 0.5 -> real lead 0.25 -> target 0.25; first incoming beat >= 0.25 is 0.25.
        XCTAssertEqual(offset, 0.0, accuracy: 1e-9)
    }

    func testIncomingStartOffsetNilOnNonPositiveOutgoingRate() {
        let out = [0.5, 1.0]
        let inc = [0.0, 0.5]
        XCTAssertNil(BeatMath.incomingStartOffset(
            outgoingPosition: 0.0, outgoingBeats: out, incomingBeats: inc, outgoingRate: 0))
    }

    func testIncomingStartOffsetDeclinesOnLongIntro() {
        // Incoming's first beat is 10s in; aligning to a near outgoing beat would require skipping
        // ~9.5s (> maxSkip) -> decline so the caller just starts at 0.
        let out = stride(from: 0.0, through: 20.0, by: 0.5).map { $0 }
        let inc = [10.0, 10.5, 11.0]
        XCTAssertNil(BeatMath.incomingStartOffset(outgoingPosition: 5.0, outgoingBeats: out, incomingBeats: inc))
    }

    func testIncomingStartOffsetNilWithoutGrids() {
        XCTAssertNil(BeatMath.incomingStartOffset(outgoingPosition: 1, outgoingBeats: [], incomingBeats: [0.5]))
        XCTAssertNil(BeatMath.incomingStartOffset(outgoingPosition: 1, outgoingBeats: [1.5], incomingBeats: []))
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
