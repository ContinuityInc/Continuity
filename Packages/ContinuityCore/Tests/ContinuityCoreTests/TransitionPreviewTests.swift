import XCTest
@testable import ContinuityCore

final class TransitionPreviewTests: XCTestCase {

    // MARK: Tempo

    func testTempoNormalMatch() {
        let preview = TransitionPreview.make(
            curve: .equalPower, duration: 8,
            outgoingBPM: 128, incomingBPM: 124,
            outgoingCamelot: nil, incomingCamelot: nil,
            beatmatchEnabled: true, harmonicEnabled: false, bassSwapEnabled: false)
        let tempo = try! XCTUnwrap(preview.tempo)
        XCTAssertEqual(tempo.outgoingBPM, 128)
        XCTAssertEqual(tempo.incomingBPM, 124)
        // 128/124 ≈ 1.032, so a ~+3.2% nudge on the incoming deck.
        XCTAssertEqual(tempo.matchedRate, 128.0 / 124.0, accuracy: 1e-9)
        XCTAssertEqual(tempo.percentAdjust, (128.0 / 124.0 - 1) * 100, accuracy: 1e-9)
        XCTAssertGreaterThan(tempo.percentAdjust, 0)
    }

    func testTempoHalfDoubleTimeResolvesToNoStretch() {
        // 85 vs 170: the double-time interpretation lines up exactly, so no stretch is needed.
        let preview = TransitionPreview.make(
            curve: .equalPower, duration: 8,
            outgoingBPM: 170, incomingBPM: 85,
            outgoingCamelot: nil, incomingCamelot: nil,
            beatmatchEnabled: true, harmonicEnabled: false, bassSwapEnabled: false)
        let tempo = try! XCTUnwrap(preview.tempo)
        XCTAssertEqual(tempo.matchedRate, 1, accuracy: 1e-9)
        XCTAssertEqual(tempo.percentAdjust, 0, accuracy: 1e-9)
    }

    func testTempoNilWhenBeatmatchDisabled() {
        let preview = TransitionPreview.make(
            curve: .equalPower, duration: 8,
            outgoingBPM: 128, incomingBPM: 124,
            outgoingCamelot: nil, incomingCamelot: nil,
            beatmatchEnabled: false, harmonicEnabled: false, bassSwapEnabled: false)
        XCTAssertNil(preview.tempo)
    }

    func testTempoNilWhenBPMMissing() {
        let preview = TransitionPreview.make(
            curve: .equalPower, duration: 8,
            outgoingBPM: nil, incomingBPM: 124,
            outgoingCamelot: nil, incomingCamelot: nil,
            beatmatchEnabled: true, harmonicEnabled: false, bassSwapEnabled: false)
        XCTAssertNil(preview.tempo)
    }

    func testTempoNilWhenStretchTooLarge() {
        // 100 vs 140: nearest interpretation still needs ~28% stretch → engine won't beatmatch.
        let preview = TransitionPreview.make(
            curve: .equalPower, duration: 8,
            outgoingBPM: 100, incomingBPM: 140,
            outgoingCamelot: nil, incomingCamelot: nil,
            beatmatchEnabled: true, harmonicEnabled: false, bassSwapEnabled: false)
        XCTAssertNil(preview.tempo)
    }

    // MARK: Key

    func testKeyCompatibleNoShift() {
        // 8A and 8B are relative minor/major — compatible with no pitch shift.
        let preview = TransitionPreview.make(
            curve: .equalPower, duration: 8,
            outgoingBPM: nil, incomingBPM: nil,
            outgoingCamelot: "8A", incomingCamelot: "8B",
            beatmatchEnabled: false, harmonicEnabled: true, bassSwapEnabled: false)
        let key = try! XCTUnwrap(preview.key)
        XCTAssertEqual(key.outgoingCode, "8A")
        XCTAssertEqual(key.incomingCode, "8B")
        XCTAssertTrue(key.compatible)
        XCTAssertEqual(key.appliedShiftSemitones, 0)
    }

    func testKeyIncompatibleNeedingSemitoneShift() {
        // 8A into 3A isn't compatible as-is, but +1 semitone (+7 wheel hours) lands 8A on 3A.
        let preview = TransitionPreview.make(
            curve: .equalPower, duration: 8,
            outgoingBPM: nil, incomingBPM: nil,
            outgoingCamelot: "3A", incomingCamelot: "8A",
            beatmatchEnabled: false, harmonicEnabled: true, bassSwapEnabled: false)
        let key = try! XCTUnwrap(preview.key)
        XCTAssertFalse(key.compatible)
        XCTAssertEqual(key.appliedShiftSemitones, 1)
    }

    func testKeyIncompatibleBeyondShift() {
        // 5B and 8A: no ±1 semitone shift reaches compatibility → shift stays 0.
        let preview = TransitionPreview.make(
            curve: .equalPower, duration: 8,
            outgoingBPM: nil, incomingBPM: nil,
            outgoingCamelot: "5B", incomingCamelot: "8A",
            beatmatchEnabled: false, harmonicEnabled: true, bassSwapEnabled: false)
        let key = try! XCTUnwrap(preview.key)
        XCTAssertFalse(key.compatible)
        XCTAssertEqual(key.appliedShiftSemitones, 0)
    }

    func testKeyNilWhenHarmonicDisabled() {
        let preview = TransitionPreview.make(
            curve: .equalPower, duration: 8,
            outgoingBPM: nil, incomingBPM: nil,
            outgoingCamelot: "8A", incomingCamelot: "8B",
            beatmatchEnabled: false, harmonicEnabled: false, bassSwapEnabled: false)
        XCTAssertNil(preview.key)
    }

    func testKeyNilWhenCodeUnparseable() {
        let preview = TransitionPreview.make(
            curve: .equalPower, duration: 8,
            outgoingBPM: nil, incomingBPM: nil,
            outgoingCamelot: "not-a-code", incomingCamelot: "8B",
            beatmatchEnabled: false, harmonicEnabled: true, bassSwapEnabled: false)
        XCTAssertNil(preview.key)
    }

    // MARK: Passthrough

    func testCurveDurationAndBassSwapPassThrough() {
        let preview = TransitionPreview.make(
            curve: .smooth, duration: 12,
            outgoingBPM: nil, incomingBPM: nil,
            outgoingCamelot: nil, incomingCamelot: nil,
            beatmatchEnabled: true, harmonicEnabled: true, bassSwapEnabled: true)
        XCTAssertEqual(preview.curve, .smooth)
        XCTAssertEqual(preview.duration, 12)
        XCTAssertTrue(preview.bassSwap)
    }
}

final class BeatWindowTests: XCTestCase {

    func testOutgoingPositionsMapTailBeats() {
        // Final 4s ending at 10s → window [6, 10]. Beats at 8, 9, 10 map to 0.5, 0.75, 1.0.
        let positions = BeatWindow.outgoingPositions(beats: [2, 6, 8, 9, 10], windowEnd: 10, duration: 4)
        XCTAssertEqual(positions, [0, 0.5, 0.75, 1.0])
    }

    func testIncomingPositionsMapIntroBeats() {
        // First 4s from 0 → window [0, 4]. Beats at 0, 1, 2 map to 0, 0.25, 0.5; 5 is excluded.
        let positions = BeatWindow.incomingPositions(beats: [0, 1, 2, 5], windowStart: 0, duration: 4)
        XCTAssertEqual(positions, [0, 0.25, 0.5])
    }

    func testIncomingPositionsHonorAudibleStartOffset() {
        // Intro window starting at 3s → [3, 7]. Beats at 3, 5, 7 map to 0, 0.5, 1.0.
        let positions = BeatWindow.incomingPositions(beats: [1, 3, 5, 7, 9], windowStart: 3, duration: 4)
        XCTAssertEqual(positions, [0, 0.5, 1.0])
    }

    func testEmptyBeatsYieldNothing() {
        XCTAssertTrue(BeatWindow.outgoingPositions(beats: [], windowEnd: 10, duration: 4).isEmpty)
        XCTAssertTrue(BeatWindow.incomingPositions(beats: [], windowStart: 0, duration: 4).isEmpty)
    }

    func testZeroDurationYieldsNothing() {
        XCTAssertTrue(BeatWindow.outgoingPositions(beats: [8, 9], windowEnd: 10, duration: 0).isEmpty)
        XCTAssertTrue(BeatWindow.incomingPositions(beats: [0, 1], windowStart: 0, duration: 0).isEmpty)
    }
}
