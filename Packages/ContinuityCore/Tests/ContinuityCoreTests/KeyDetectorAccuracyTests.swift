import XCTest
@testable import ContinuityCore

/// Accuracy regression tests for `KeyDetector` against synthesized chord progressions in all
/// 24 keys — ground truth is exact because we render the audio ourselves. The renders include
/// harmonics, bass notes, and optional global detuning/noise to mimic real recordings.
///
/// The detune sweeps guard the tuning-correction path: recordings mastered off A440 used to tip
/// whole pitch classes across the semitone rounding boundary and shift the detected key (the
/// dominant real-world failure — e.g. "Never Gonna Give You Up", A♭ major, read as C minor).
/// Thresholds sit slightly below measured accuracy so incidental changes don't flake, while a
/// genuine regression (measured drops were 20-40 points pre-fix) still fails loudly.
final class KeyDetectorAccuracyTests: XCTestCase {
    private let sr = 44_100.0

    // MARK: - Rendering

    private func midiFreq(_ m: Double) -> Double { 440.0 * pow(2.0, (m - 69.0) / 12.0) }

    /// Adds a note (fundamental + 4 harmonics at 1/h amplitude) into `out`.
    private func addNote(midi: Double, durS: Double, detuneCents: Double, gain: Float,
                         at start: Int, into out: inout [Float]) {
        let f0 = midiFreq(midi) * pow(2.0, detuneCents / 1200.0)
        let n = Int(durS * sr)
        for h in 1...4 {
            let f = f0 * Double(h)
            if f > sr / 2 { continue }
            let amp = gain / Float(h)
            let step = 2.0 * Double.pi * f / sr
            for i in 0..<n where start + i < out.count {
                out[start + i] += amp * Float(sin(step * Double(i)))
            }
        }
    }

    private func triad(minor: Bool) -> [Int] { minor ? [0, 3, 7] : [0, 4, 7] }

    /// A cadence that unambiguously implies the key (major: I–V–vi–IV; minor: i–iv–V–i, whose
    /// major-V leading tone pins the minor tonic vs its relative major).
    private func progression(minor: Bool) -> [(root: Int, minor: Bool)] {
        minor
            ? [(0, true), (5, true), (7, false), (0, true)]
            : [(0, false), (7, false), (9, true), (5, false)]
    }

    /// Deterministic pseudo-noise (xorshift) standing in for broadband percussion/production.
    private func addNoise(level: Float, seed: UInt64, into out: inout [Float]) {
        guard level > 0 else { return }
        var s = seed &+ 0x9E3779B97F4A7C15
        for i in 0..<out.count {
            s ^= s >> 12; s ^= s << 25; s ^= s >> 27
            let r = Float(Int64(bitPattern: s &* 0x2545F4914F6CDD1D) >> 40) / Float(1 << 23)
            out[i] += level * r
        }
    }

    private func renderKey(tonic: Int, minor: Bool, detune: Double, noise: Float = 0) -> [Float] {
        let chordDur = 1.5
        let prog = progression(minor: minor)
        var out = [Float](repeating: 0, count: Int(chordDur * Double(prog.count) * sr) + 1)
        var start = 0
        for chord in prog {
            let rootPc = (tonic + chord.root) % 12
            addNote(midi: Double(36 + rootPc), durS: chordDur, detuneCents: detune, gain: 0.5,
                    at: start, into: &out) // bass
            for interval in triad(minor: chord.minor) {
                addNote(midi: Double(60 + ((rootPc + interval) % 12)), durS: chordDur,
                        detuneCents: detune, gain: 0.4, at: start, into: &out)
            }
            start += Int(chordDur * sr)
        }
        addNoise(level: noise, seed: UInt64(tonic * 2 + (minor ? 1 : 0)) &+ 1, into: &out)
        return out
    }

    private func expected(tonic: Int, minor: Bool) -> MusicalKey {
        let major: [MusicalKey] = [.cMajor, .dFlatMajor, .dMajor, .eFlatMajor, .eMajor, .fMajor,
                                   .fSharpMajor, .gMajor, .aFlatMajor, .aMajor, .bFlatMajor, .bMajor]
        let minorKeys: [MusicalKey] = [.cMinor, .cSharpMinor, .dMinor, .dSharpMinor, .eMinor, .fMinor,
                                       .fSharpMinor, .gMinor, .gSharpMinor, .aMinor, .bFlatMinor, .bMinor]
        return minor ? minorKeys[tonic] : major[tonic]
    }

    /// Detected-exactly count over all 24 keys at the given detune/noise.
    private func exactCount(detune: Double, noise: Float = 0) -> Int {
        var exact = 0
        for tonic in 0..<12 {
            for minor in [false, true] {
                let audio = renderKey(tonic: tonic, minor: minor, detune: detune, noise: noise)
                guard let r = KeyDetector.analyze(samples: audio, sampleRate: sr) else { continue }
                if r.key == expected(tonic: tonic, minor: minor) { exact += 1 }
            }
        }
        return exact
    }

    // MARK: - Thresholds (measured: 24, 22, 19, 22 — asserted with a little headroom)

    func testAllKeysExactAtStandardTuning() {
        XCTAssertEqual(exactCount(detune: 0), 24)
    }

    func testDetunedFlat20Cents() {
        XCTAssertGreaterThanOrEqual(exactCount(detune: -20), 21)
    }

    func testDetunedSharp45Cents() {
        XCTAssertGreaterThanOrEqual(exactCount(detune: 45), 17)
    }

    func testNoisyAndDetuned() {
        XCTAssertGreaterThanOrEqual(exactCount(detune: -20, noise: 0.4), 20)
    }
}
