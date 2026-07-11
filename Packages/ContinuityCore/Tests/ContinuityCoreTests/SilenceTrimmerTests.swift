import XCTest
@testable import ContinuityCore

final class SilenceTrimmerTests: XCTestCase {
    private let sr = 44_100.0

    /// `silence | tone | silence` with the given durations (seconds).
    private func render(lead: Double, tone: Double, tail: Double, amplitude: Float = 0.5) -> [Float] {
        let leadN = Int(lead * sr), toneN = Int(tone * sr), tailN = Int(tail * sr)
        var out = [Float](repeating: 0, count: leadN + toneN + tailN)
        let step = 2.0 * Double.pi * 440.0 / sr
        for i in 0..<toneN {
            out[leadN + i] = amplitude * Float(sin(step * Double(i)))
        }
        return out
    }

    func testDetectsLeadingAndTrailingSilence() {
        let samples = render(lead: 1.5, tone: 5.0, tail: 2.5)
        let bounds = SilenceTrimmer.audibleBounds(samples: samples, sampleRate: sr)
        XCTAssertEqual(bounds.audibleStart, 1.5, accuracy: 0.1)
        XCTAssertEqual(bounds.audibleEnd, 6.5, accuracy: 0.1)
    }

    func testNoSilenceReturnsFullSpan() {
        let samples = render(lead: 0, tone: 4.0, tail: 0)
        let bounds = SilenceTrimmer.audibleBounds(samples: samples, sampleRate: sr)
        XCTAssertEqual(bounds.audibleStart, 0, accuracy: 0.06)
        XCTAssertEqual(bounds.audibleEnd, 4.0, accuracy: 0.06)
    }

    func testAllSilentReturnsFullSpanUntrimmed() {
        let samples = [Float](repeating: 0, count: Int(3.0 * sr))
        let bounds = SilenceTrimmer.audibleBounds(samples: samples, sampleRate: sr)
        XCTAssertEqual(bounds.audibleStart, 0)
        XCTAssertEqual(bounds.audibleEnd, 3.0, accuracy: 1e-9)
    }

    func testQuietNoiseFloorCountsAsSilence() {
        // A -70 dBFS hiss tail after the tone should be trimmed (threshold -48 dBFS).
        var samples = render(lead: 0, tone: 3.0, tail: 0)
        let hissN = Int(2.0 * sr)
        var seed: UInt64 = 42
        for _ in 0..<hissN {
            seed ^= seed >> 12; seed ^= seed << 25; seed ^= seed >> 27
            let r = Float(Int64(bitPattern: seed &* 0x2545F4914F6CDD1D) >> 40) / Float(1 << 23)
            samples.append(0.0003 * r)   // ≈ -70 dBFS
        }
        let bounds = SilenceTrimmer.audibleBounds(samples: samples, sampleRate: sr)
        XCTAssertEqual(bounds.audibleEnd, 3.0, accuracy: 0.1)
    }

    func testFadeOutTailKeptUntilInaudible() {
        // Tone fading linearly to zero over its last 2s: the audible end should sit inside the
        // fade (where it drops under -48 dB), not at the fade's start.
        var samples = render(lead: 0, tone: 4.0, tail: 1.0)
        let fadeStart = Int(2.0 * sr), fadeEnd = Int(4.0 * sr)
        for i in fadeStart..<fadeEnd {
            let progress = Float(i - fadeStart) / Float(fadeEnd - fadeStart)
            samples[i] *= (1 - progress)
        }
        let bounds = SilenceTrimmer.audibleBounds(samples: samples, sampleRate: sr)
        XCTAssertGreaterThan(bounds.audibleEnd, 3.0)   // most of the fade is audible
        XCTAssertLessThan(bounds.audibleEnd, 4.05)     // but it ends by the fade's end
    }
}
