import XCTest
@testable import ContinuityCore

final class LoudnessMeterTests: XCTestCase {
    private let sr = 44_100.0

    private func sine(dBFS: Double, seconds: Double, hz: Double = 997) -> [Float] {
        let amp = pow(10, dBFS / 20)
        let n = Int(seconds * sr)
        return (0..<n).map { Float(amp * sin(2 * .pi * hz * Double($0) / sr)) }
    }

    func testKnownSineLevel() {
        // A 997 Hz sine at −20 dBFS: mean square = amp²/2 → −23.01 dB, K-weighting ≈ 0 dB at
        // 1 kHz, plus the −0.691 offset → ≈ −23.7 LUFS.
        let lufs = LoudnessMeter.integratedLUFS(samples: sine(dBFS: -20, seconds: 8), sampleRate: sr)
        XCTAssertNotNil(lufs)
        XCTAssertEqual(lufs!, -23.7, accuracy: 1.0)
    }

    func testRelativeLevelsDifferExactly() {
        // Leveling only needs RELATIVE accuracy: a 10 dB quieter signal must read 10 LU lower.
        let loud = LoudnessMeter.integratedLUFS(samples: sine(dBFS: -20, seconds: 8), sampleRate: sr)!
        let quiet = LoudnessMeter.integratedLUFS(samples: sine(dBFS: -30, seconds: 8), sampleRate: sr)!
        XCTAssertEqual(loud - quiet, 10, accuracy: 0.1)
    }

    func testSilenceReturnsNil() {
        XCTAssertNil(LoudnessMeter.integratedLUFS(samples: [Float](repeating: 0, count: 44_100 * 4),
                                                  sampleRate: sr))
        XCTAssertNil(LoudnessMeter.integratedLUFS(samples: [], sampleRate: sr))
    }

    func testGatingIgnoresSilentHalf() {
        // Half loud sine, half silence: gating must exclude the silence, so the integrated value
        // stays near the loud half's loudness instead of averaging down ~3 dB.
        var samples = sine(dBFS: -20, seconds: 6)
        samples += [Float](repeating: 0, count: Int(6 * sr))
        let gated = LoudnessMeter.integratedLUFS(samples: samples, sampleRate: sr)!
        let reference = LoudnessMeter.integratedLUFS(samples: sine(dBFS: -20, seconds: 6), sampleRate: sr)!
        XCTAssertEqual(gated, reference, accuracy: 0.5)
    }

    func testHighPassRemovesSubBass() {
        // K-weighting's ~38 Hz high-pass: a 20 Hz rumble must read far quieter than 1 kHz at the
        // same amplitude (this is what stops sub-bass from dominating the measurement).
        let bass = LoudnessMeter.integratedLUFS(samples: sine(dBFS: -20, seconds: 8, hz: 20), sampleRate: sr)
        let mid = LoudnessMeter.integratedLUFS(samples: sine(dBFS: -20, seconds: 8, hz: 997), sampleRate: sr)!
        if let bass { XCTAssertLessThan(bass, mid - 6) } // attenuated or gated out entirely
    }

    func testMakeupGainClamps() {
        XCTAssertEqual(LoudnessMeter.makeupGainDB(measuredLUFS: -16, targetLUFS: -14), 2, accuracy: 1e-9)
        XCTAssertEqual(LoudnessMeter.makeupGainDB(measuredLUFS: -30, targetLUFS: -14), 6, accuracy: 1e-9)   // boost cap
        XCTAssertEqual(LoudnessMeter.makeupGainDB(measuredLUFS: -1, targetLUFS: -14), -12, accuracy: 1e-9)  // cut cap
    }

    /// The streaming ring-buffer implementation must reproduce the straightforward
    /// whole-buffer measurement bit-for-bit — including at sample rates where the 400 ms
    /// block is NOT an exact multiple of the 100 ms hop (integer truncation, e.g. 44056 Hz).
    func testStreamingMatchesReferenceImplementation() {
        for rate in [44_100.0, 48_000.0, 44_056.0] {
            let n = Int(3.7 * rate)   // non-whole block count exercises the tail handling
            let samples = (0..<n).map { i -> Float in
                // Deterministic multi-tone with a quiet stretch so both gates engage.
                let t = Double(i) / rate
                let quiet = t > 2.5 ? 0.001 : 1.0
                return Float(quiet * (0.08 * sin(2 * .pi * 997 * t) + 0.04 * sin(2 * .pi * 210 * t)))
            }
            let streamed = LoudnessMeter.integratedLUFS(samples: samples, sampleRate: rate)
            let reference = Self.referenceLUFS(samples: samples, sampleRate: rate)
            XCTAssertEqual(streamed, reference, "sample rate \(rate)")
        }
    }

    /// The pre-optimization implementation: full-length weighted buffer, then blocks.
    private static func referenceLUFS(samples: [Float], sampleRate: Double) -> Double? {
        guard sampleRate > 0, !samples.isEmpty else { return nil }
        var shelf = LoudnessMeter.Biquad.highShelf(f0: 1681.974450955533, gainDB: 3.999843853973347,
                                                   q: 0.7071752369554196, sampleRate: sampleRate)
        var highPass = LoudnessMeter.Biquad.highPass(f0: 38.13547087602444, q: 0.5003270373238773,
                                                     sampleRate: sampleRate)
        var weighted = [Double](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            weighted[i] = highPass.process(shelf.process(Double(samples[i])))
        }
        let block = Int(0.4 * sampleRate)
        let hop = Int(0.1 * sampleRate)
        guard block > 0, hop > 0, weighted.count >= block else { return nil }
        var blockLoudness: [Double] = []
        var blockMeanSquare: [Double] = []
        var start = 0
        while start + block <= weighted.count {
            var sum = 0.0
            for i in start..<(start + block) { sum += weighted[i] * weighted[i] }
            let ms = sum / Double(block)
            blockMeanSquare.append(ms)
            blockLoudness.append(-0.691 + 10 * log10(max(ms, .leastNormalMagnitude)))
            start += hop
        }
        var gated = zip(blockMeanSquare, blockLoudness).filter { $0.1 > -70 }
        guard !gated.isEmpty else { return nil }
        let meanMS = gated.reduce(0) { $0 + $1.0 } / Double(gated.count)
        let relativeThreshold = -0.691 + 10 * log10(meanMS) - 10
        gated = gated.filter { $0.1 > relativeThreshold }
        guard !gated.isEmpty else { return nil }
        let finalMS = gated.reduce(0) { $0 + $1.0 } / Double(gated.count)
        return -0.691 + 10 * log10(finalMS)
    }
}
