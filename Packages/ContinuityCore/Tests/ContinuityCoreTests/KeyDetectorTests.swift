import XCTest
@testable import ContinuityCore

final class KeyDetectorTests: XCTestCase {

    private let sampleRate: Double = 44_100

    // MARK: - Synthesis helpers

    /// Equal-tempered frequency for a MIDI note (A4 = MIDI 69 = 440 Hz).
    private func freq(midi: Double) -> Double {
        440.0 * pow(2.0, (midi - 69.0) / 12.0)
    }

    /// Sum of equal-amplitude sine waves at the given frequencies, `seconds` long.
    private func tones(_ frequencies: [Double], seconds: Double) -> [Float] {
        let n = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: n)
        let twoPi = 2.0 * Double.pi
        for f in frequencies {
            let step = twoPi * f / sampleRate
            for i in 0..<n {
                out[i] += Float(sin(step * Double(i)))
            }
        }
        // Normalize so we don't clip; magnitude doesn't affect key detection.
        if !frequencies.isEmpty {
            let scale = Float(1.0 / Double(frequencies.count))
            for i in 0..<n { out[i] *= scale }
        }
        return out
    }

    // MARK: - Tests

    func testCMajorTriad() {
        // C4 + E4 + G4.
        let samples = tones([261.63, 329.63, 392.00], seconds: 3)
        let result = KeyDetector.analyze(samples: samples, sampleRate: sampleRate)
        let r = try! XCTUnwrap(result)
        XCTAssertEqual(r.camelot, r.key.camelot) // invariant
        // A bare major triad shares all three pitches with its relative minor, so the
        // K–S correlation can land on either side of 8 (C major / A minor). Require the
        // C-major Camelot (8B) at minimum; the exact-key assertion is the preferred one.
        XCTAssertEqual(r.camelot, Camelot(number: 8, side: .b))
        XCTAssertEqual(r.key, .cMajor)
        XCTAssertGreaterThan(r.confidence, 0)
    }

    func testAMinorTriad() {
        // A3 + C4 + E4.
        let samples = tones([220.0, 261.63, 329.63], seconds: 3)
        let result = KeyDetector.analyze(samples: samples, sampleRate: sampleRate)
        let r = try! XCTUnwrap(result)
        // A minor triad is enharmonically the C-major triad's relative; the bare triad
        // can be ambiguous between 8A and 8B. Assert compatibility with 8A and that it
        // resolves to one of {8A, 8B}. (Exact .aMinor preferred but not required.)
        XCTAssertTrue(r.camelot.isCompatible(with: Camelot(number: 8, side: .a)))
        XCTAssertTrue(r.camelot == Camelot(number: 8, side: .a)
                      || r.camelot == Camelot(number: 8, side: .b))
    }

    func testGMajorScale() {
        // G-major scale: G A B C D E F# (one octave from G3).
        // MIDI: G3=55, A3=57, B3=59, C4=60, D4=62, E4=64, F#4=66.
        let midis: [Double] = [55, 57, 59, 60, 62, 64, 66]
        let samples = tones(midis.map { freq(midi: $0) }, seconds: 3)
        let result = KeyDetector.analyze(samples: samples, sampleRate: sampleRate)
        let r = try! XCTUnwrap(result)
        // Prefer exact G major (9B); accept harmonic compatibility otherwise (the
        // diatonic scale can correlate with relative E minor, 9A — still compatible).
        XCTAssertTrue(r.camelot.isCompatible(with: Camelot(number: 9, side: .b)),
                      "Expected G-major-compatible key, got \(r.camelot.code) (\(r.key))")
    }

    func testEmptyInputIsNil() {
        XCTAssertNil(KeyDetector.analyze(samples: [], sampleRate: sampleRate))
    }

    func testTooShortInputIsNil() {
        // Fewer than one analysis frame (4096 samples) → nil.
        let samples = [Float](repeating: 0, count: 1024)
        XCTAssertNil(KeyDetector.analyze(samples: samples, sampleRate: sampleRate))
    }

    func testConfidenceInRange() {
        let samples = tones([261.63, 329.63, 392.00], seconds: 2)
        let r = try! XCTUnwrap(KeyDetector.analyze(samples: samples, sampleRate: sampleRate))
        XCTAssertGreaterThanOrEqual(r.confidence, 0.0)
        XCTAssertLessThanOrEqual(r.confidence, 1.0)
    }
}
