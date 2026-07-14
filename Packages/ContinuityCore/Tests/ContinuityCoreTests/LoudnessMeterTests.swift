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
}
