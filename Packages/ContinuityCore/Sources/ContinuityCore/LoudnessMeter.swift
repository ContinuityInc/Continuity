import Foundation

/// Integrated loudness measurement (ITU-R BS.1770 style) for loudness leveling.
///
/// Tracks are mastered at wildly different loudness; a blend between a quiet master and a loud
/// one lurches even when beat-locked. Measuring each track once (at analysis time) lets the
/// engine apply per-deck makeup gain so every transition meets at a common level.
///
/// Implementation: K-weighting (pre-shelf + high-pass biquads, coefficients derived for the
/// actual sample rate) → mean-square over 400 ms blocks at 75% overlap → −70 LUFS absolute gate
/// → −10 LU relative gate → integrated loudness. Input is the analysis pipeline's **downmixed
/// mono**, so absolute values sit a little below a true multichannel measurement — a consistent
/// bias that cancels out in track-to-track leveling.
public enum LoudnessMeter {

    /// Integrated loudness in LUFS, or nil for silence (nothing above the absolute gate).
    public static func integratedLUFS(samples: [Float], sampleRate: Double) -> Double? {
        guard sampleRate > 0, !samples.isEmpty else { return nil }

        // K-weighting: stage 1 high-shelf (+~4 dB above ~1.5 kHz), stage 2 high-pass (~38 Hz).
        var shelf = Biquad.highShelf(f0: 1681.974450955533, gainDB: 3.999843853973347,
                                     q: 0.7071752369554196, sampleRate: sampleRate)
        var highPass = Biquad.highPass(f0: 38.13547087602444, q: 0.5003270373238773,
                                       sampleRate: sampleRate)

        var weighted = [Double](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            weighted[i] = highPass.process(shelf.process(Double(samples[i])))
        }

        // 400 ms blocks, 100 ms hop (75% overlap).
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

        // Absolute gate: drop blocks below −70 LUFS.
        var gated = zip(blockMeanSquare, blockLoudness).filter { $0.1 > -70 }
        guard !gated.isEmpty else { return nil }

        // Relative gate: drop blocks more than 10 LU below the mean of the survivors.
        let meanMS = gated.reduce(0) { $0 + $1.0 } / Double(gated.count)
        let relativeThreshold = -0.691 + 10 * log10(meanMS) - 10
        gated = gated.filter { $0.1 > relativeThreshold }
        guard !gated.isEmpty else { return nil }

        let finalMS = gated.reduce(0) { $0 + $1.0 } / Double(gated.count)
        return -0.691 + 10 * log10(finalMS)
    }

    /// Makeup gain (dB) to bring `measuredLUFS` to `targetLUFS`. Cuts are allowed generously;
    /// boosts are capped low — boosting a quiet master toward the target risks clipping peaks
    /// we never measured, and under-boosting merely leaves a smaller step than before.
    public static func makeupGainDB(
        measuredLUFS: Double,
        targetLUFS: Double = -14,
        maxBoostDB: Double = 6,
        maxCutDB: Double = 12
    ) -> Double {
        min(maxBoostDB, max(-maxCutDB, targetLUFS - measuredLUFS))
    }

    /// One RBJ-cookbook biquad section (direct form II transposed).
    struct Biquad {
        let b0, b1, b2, a1, a2: Double
        private var z1 = 0.0
        private var z2 = 0.0

        static func highShelf(f0: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
            let a = pow(10, gainDB / 40)
            let w0 = 2 * Double.pi * f0 / sampleRate
            let alpha = sin(w0) / (2 * q)
            let cosw = cos(w0)
            let a0 = (a + 1) - (a - 1) * cosw + 2 * sqrt(a) * alpha
            return Biquad(
                b0: (a * ((a + 1) + (a - 1) * cosw + 2 * sqrt(a) * alpha)) / a0,
                b1: (-2 * a * ((a - 1) + (a + 1) * cosw)) / a0,
                b2: (a * ((a + 1) + (a - 1) * cosw - 2 * sqrt(a) * alpha)) / a0,
                a1: (2 * ((a - 1) - (a + 1) * cosw)) / a0,
                a2: ((a + 1) - (a - 1) * cosw - 2 * sqrt(a) * alpha) / a0
            )
        }

        static func highPass(f0: Double, q: Double, sampleRate: Double) -> Biquad {
            let w0 = 2 * Double.pi * f0 / sampleRate
            let alpha = sin(w0) / (2 * q)
            let cosw = cos(w0)
            let a0 = 1 + alpha
            return Biquad(
                b0: ((1 + cosw) / 2) / a0,
                b1: (-(1 + cosw)) / a0,
                b2: ((1 + cosw) / 2) / a0,
                a1: (-2 * cosw) / a0,
                a2: (1 - alpha) / a0
            )
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
}
