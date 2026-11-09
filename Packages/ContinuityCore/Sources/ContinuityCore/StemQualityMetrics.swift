import Foundation

/// Offline quality numbers for stem A/B (ORT CPU vs Core ML `.mlpackage`).
///
/// Continuity only needs **vocals** + **accompaniment = mix − vocals**. The spike
/// compares backends on the same mix window using SI-SDR against an ORT reference
/// (parity) and energy leakage into the derived accompaniment when the mix is
/// vocal-dominated. Pure Foundation — Linux-testable.
public enum StemQualityMetrics {
    /// Scale-invariant SDR in dB between `estimate` and `reference`.
    /// Returns nil when lengths mismatch or the reference is (near) silence.
    public static func siSDR(estimate: [Float], reference: [Float]) -> Double? {
        guard estimate.count == reference.count, !reference.isEmpty else { return nil }
        var refEnergy = 0.0
        var dot = 0.0
        for i in 0..<reference.count {
            let r = Double(reference[i])
            let e = Double(estimate[i])
            refEnergy += r * r
            dot += e * r
        }
        guard refEnergy > 1e-12 else { return nil }
        let scale = dot / refEnergy
        var errorEnergy = 0.0
        for i in 0..<reference.count {
            let r = Double(reference[i])
            let e = Double(estimate[i])
            let err = e - scale * r
            errorEnergy += err * err
        }
        guard errorEnergy > 1e-20 else { return 100 }
        let target = (scale * scale) * refEnergy
        return 10 * log10(target / errorEnergy)
    }

    /// Mean SI-SDR across planar stereo channels (`left` then `right`, each of length `frames`).
    public static func meanSiSDR(estimatePlanar: [Float], referencePlanar: [Float], frames: Int) -> Double? {
        guard frames > 0,
              estimatePlanar.count >= frames * 2,
              referencePlanar.count >= frames * 2 else { return nil }
        let left = siSDR(
            estimate: Array(estimatePlanar[..<frames]),
            reference: Array(referencePlanar[..<frames]))
        let right = siSDR(
            estimate: Array(estimatePlanar[frames..<(frames * 2)]),
            reference: Array(referencePlanar[frames..<(frames * 2)]))
        guard let left, let right else { return nil }
        return (left + right) / 2
    }

    /// Energy of `numerator` relative to `denominator`, in dB. Used as a cheap vocal-bleed
    /// proxy: accompaniment energy under a vocals-heavy mix should stay low.
    public static func energyRatioDB(numerator: [Float], denominator: [Float]) -> Double? {
        guard numerator.count == denominator.count, !numerator.isEmpty else { return nil }
        var num = 0.0
        var den = 0.0
        for i in 0..<numerator.count {
            let n = Double(numerator[i])
            let d = Double(denominator[i])
            num += n * n
            den += d * d
        }
        guard den > 1e-12 else { return nil }
        return 10 * log10(max(num, 1e-20) / den)
    }

    /// Peak absolute sample-wise difference (parity check after conversion / before device A/B).
    public static func maxAbsDiff(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var peak: Float = 0
        for i in 0..<a.count {
            peak = max(peak, abs(a[i] - b[i]))
        }
        return peak
    }
}
