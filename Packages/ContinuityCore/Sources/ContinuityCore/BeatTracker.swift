import Foundation
import Accelerate

/// The result of analyzing a mono PCM buffer for its tempo and beat grid.
///
/// `beatTimes` are absolute onset positions (in seconds) of every estimated beat from the
/// first detected downbeat through the end of the track, so the transition engine can align a
/// crossfade to a real beat rather than a wall-clock guess. `confidence` reflects how peaked the
/// tempo autocorrelation was (1 = a single dominant period, 0 = no periodic structure).
public struct BeatAnalysis: Sendable, Equatable {
    /// Estimated tempo in beats per minute (0 when the input was empty or too short).
    public let bpm: Double
    /// Beat onset times in seconds, ascending.
    public let beatTimes: [Double]
    /// Strength of the chosen tempo, normalized to 0...1.
    public let confidence: Double

    public init(bpm: Double, beatTimes: [Double], confidence: Double) {
        self.bpm = bpm
        self.beatTimes = beatTimes
        self.confidence = confidence
    }
}

/// Pure, hardware-free tempo + beat-grid estimator. Given an already-downmixed mono PCM buffer,
/// it builds a spectral-flux onset envelope (STFT), estimates the period by autocorrelation, and
/// then locks the grid's phase to the strongest beats. Keeping it dependency-light (only Accelerate
/// for the FFT) means the whole pipeline is unit-testable via `swift test` with no audio engine.
public enum BeatTracker {
    // MARK: Tunables

    /// STFT frame size (power of two) and hop. Hann-windowed magnitude spectra are differenced
    /// between consecutive frames to produce one onset-envelope sample per hop.
    private static let frameSize = 1024
    private static let hopSize = 512
    /// Floor for log-magnitude flux (scale-invariant onset detection).
    private static let fluxEpsilon = 1e-6
    /// Tempo search window (BPM). Octave/subdivision errors are resolved by a comb over the metric
    /// hierarchy plus a gentle perceptual prior — not a hard preferred band.
    private static let minBPM = 60.0
    private static let maxBPM = 200.0
    /// Log-normal perceptual tempo prior, used to resolve octave / metric ambiguity (beat vs.
    /// eighth-note tatum) by favoring tempi near the center. Narrow enough to break octave ties,
    /// wide enough not to override genuinely fast or slow tracks.
    private static let preferredCenterBPM = 124.0
    private static let preferredWidthOctaves = 0.75

    /// Analyze `samples` (mono PCM float, downmixed) recorded at `sampleRate` Hz.
    ///
    /// Returns a zeroed `BeatAnalysis` for empty or too-short input (fewer than a couple of frames),
    /// since there is not enough signal to estimate a period.
    public static func analyze(samples: [Float], sampleRate: Double) -> BeatAnalysis {
        let empty = BeatAnalysis(bpm: 0, beatTimes: [], confidence: 0)
        guard sampleRate > 0, samples.count >= frameSize * 4 else { return empty }

        // 1. Spectral-flux onset envelope, one value per hop.
        let envSampleRate = sampleRate / Double(hopSize)
        let envelope = onsetEnvelope(samples: samples)
        guard envelope.count >= 4 else { return empty }

        // 2. Tempo via autocorrelation of the (already mean-removed, rectified) envelope.
        guard let tempo = estimateTempo(envelope: envelope, envSampleRate: envSampleRate) else {
            return empty
        }

        // 3. Phase-lock the beat grid to the strongest onsets.
        let duration = Double(samples.count) / sampleRate
        let beatTimes = beatGrid(
            envelope: envelope,
            envSampleRate: envSampleRate,
            beatPeriodSamples: tempo.periodSamples,
            duration: duration
        )

        return BeatAnalysis(bpm: tempo.bpm, beatTimes: beatTimes, confidence: tempo.confidence)
    }

    // MARK: - Onset envelope (STFT spectral flux)

    /// Build the onset-detection function: per-hop spectral flux, locally mean-subtracted,
    /// half-wave rectified, then normalized to a 0...1 peak.
    private static func onsetEnvelope(samples: [Float]) -> [Double] {
        guard let fft = FFT(size: frameSize) else { return [] }
        let window = hannWindow(frameSize)
        let bins = frameSize / 2

        var previousMag = [Float](repeating: 0, count: bins)
        var current = [Float](repeating: 0, count: bins)
        var frame = [Float](repeating: 0, count: frameSize)

        var flux: [Double] = []
        var start = 0
        var isFirst = true
        while start + frameSize <= samples.count {
            // Windowed frame.
            samples.withUnsafeBufferPointer { src in
                window.withUnsafeBufferPointer { win in
                    vDSP_vmul(src.baseAddress! + start, 1, win.baseAddress!, 1, &frame, 1, vDSP_Length(frameSize))
                }
            }

            fft.magnitudes(of: frame, into: &current)

            if isFirst {
                isFirst = false
            } else {
                // Sum of positive log-magnitude differences across bins. The log makes flux
                // scale-invariant and emphasizes rhythmic onsets (a bin going 1→100 counts the
                // same as 10→1000) rather than being dominated by a few loud broadband transients.
                var sum = 0.0
                for i in 0..<bins {
                    let d = log(Double(current[i]) + fluxEpsilon) - log(Double(previousMag[i]) + fluxEpsilon)
                    if d > 0 { sum += d }
                }
                flux.append(sum)
            }
            swap(&previousMag, &current)
            start += hopSize
        }

        guard !flux.isEmpty else { return [] }

        // Subtract a local mean (moving average) and half-wave rectify to emphasize onsets.
        let rectified = halfWaveRectifyAgainstMovingMean(flux, window: 16)

        // Normalize to a 0...1 peak so confidence/phase math is scale-free.
        let peak = rectified.max() ?? 0
        guard peak > 0 else { return rectified }
        return rectified.map { $0 / peak }
    }

    /// Half-wave rectify a signal against its local mean computed over a centered moving window.
    private static func halfWaveRectifyAgainstMovingMean(_ x: [Double], window: Int) -> [Double] {
        let n = x.count
        guard n > 0 else { return [] }
        let half = max(1, window / 2)
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n - 1, i + half)
            var sum = 0.0
            for j in lo...hi { sum += x[j] }
            let mean = sum / Double(hi - lo + 1)
            let v = x[i] - mean
            out[i] = v > 0 ? v : 0
        }
        return out
    }

    // MARK: - Tempo estimation (autocorrelation)

    private struct Tempo {
        let bpm: Double
        let periodSamples: Double  // beat period in envelope samples
        let confidence: Double
    }

    /// Estimate tempo by autocorrelating the onset envelope and picking the strongest lag whose
    /// implied BPM is in range, with octave-error correction toward `preferred` BPM.
    private static func estimateTempo(envelope: [Double], envSampleRate: Double) -> Tempo? {
        let n = envelope.count
        guard n >= 4 else { return nil }

        // Mean-remove before autocorrelation so the DC component doesn't dominate.
        let mean = envelope.reduce(0, +) / Double(n)
        let centered = envelope.map { $0 - mean }

        // Candidate beat-period lags (envelope samples) for the BPM search window.
        // lag = 60 * envSampleRate / bpm. The comb reaches up to `combHarmonics`× the slowest
        // period, so the ACF is computed out to that longer lag.
        let minLag = max(2, Int((60.0 * envSampleRate / maxBPM).rounded(.down)))
        let maxLag = min(n - 1, Int((60.0 * envSampleRate / minBPM).rounded(.up)))
        guard maxLag > minLag else { return nil }

        var energy = 0.0
        for v in centered { energy += v * v }
        guard energy > 0 else { return nil }

        // Energy-normalized autocorrelation across the candidate lags.
        var acf = [Double](repeating: 0, count: maxLag + 1)
        for lag in 1...maxLag {
            var sum = 0.0
            var i = lag
            while i < n {
                sum += centered[i] * centered[i - lag]
                i += 1
            }
            acf[lag] = sum / energy
        }

        func bpm(forLag lag: Double) -> Double { 60.0 * envSampleRate / lag }

        // Pick the lag maximizing ACF × perceptual prior. The prior resolves octave / metric
        // ambiguity (beat vs. eighth-note tatum): a plain ACF max tends to lock onto whichever
        // subdivision is loudest, while the prior gently favors a musically-plausible tempo.
        var bestLag = minLag
        var bestScore = -Double.infinity
        for lag in minLag...maxLag {
            let score = acf[lag] * tempoPrior(bpm: bpm(forLag: Double(lag)))
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        guard bestScore > 0 else { return nil }

        // Sub-sample refinement on the ACF peak around the chosen lag.
        let refinedLag = parabolicPeak(acf, around: bestLag, lo: 1, hi: maxLag) ?? Double(bestLag)
        let confidence = min(max(acf[bestLag], 0), 1)
        return Tempo(bpm: bpm(forLag: refinedLag), periodSamples: refinedLag, confidence: confidence)
    }

    /// Gentle log-normal perceptual prior, favoring tempi near `preferredCenterBPM`.
    private static func tempoPrior(bpm: Double) -> Double {
        guard bpm > 0 else { return 0 }
        let z = log2(bpm / preferredCenterBPM) / preferredWidthOctaves
        return exp(-0.5 * z * z)
    }

    /// Parabolic interpolation around an integer peak index to get a sub-sample lag.
    private static func parabolicPeak(_ x: [Double], around i: Int, lo: Int, hi: Int) -> Double? {
        guard i > lo, i < hi else { return Double(i) }
        let ym = x[i - 1], y0 = x[i], yp = x[i + 1]
        let denom = (ym - 2 * y0 + yp)
        guard denom != 0 else { return Double(i) }
        let delta = 0.5 * (ym - yp) / denom
        guard delta.isFinite, abs(delta) <= 1 else { return Double(i) }
        return Double(i) + delta
    }

    // MARK: - Beat grid / phase

    /// Find the phase offset (within one beat period) that maximizes the onset energy sampled at
    /// the implied beat positions, then emit the full ascending beat grid up to `duration`.
    private static func beatGrid(
        envelope: [Double],
        envSampleRate: Double,
        beatPeriodSamples: Double,
        duration: Double
    ) -> [Double] {
        let n = envelope.count
        guard n > 0, beatPeriodSamples >= 1 else { return [] }

        let periodInt = Int(beatPeriodSamples.rounded())
        guard periodInt >= 1 else { return [] }

        // Try every integer phase offset within one beat period; score by summed onset energy at
        // each implied beat index.
        var bestOffset = 0
        var bestScore = -1.0
        for offset in 0..<periodInt {
            var score = 0.0
            var pos = Double(offset)
            while pos < Double(n) {
                let idx = Int(pos.rounded())
                if idx >= 0 && idx < n { score += envelope[idx] }
                pos += beatPeriodSamples
            }
            if score > bestScore {
                bestScore = score
                bestOffset = offset
            }
        }

        // Emit beat times in seconds from the chosen phase across the whole track.
        let beatPeriodSeconds = beatPeriodSamples / envSampleRate
        guard beatPeriodSeconds > 0 else { return [] }
        let phaseSeconds = Double(bestOffset) / envSampleRate

        var beats: [Double] = []
        var t = phaseSeconds
        while t <= duration {
            beats.append(t)
            t += beatPeriodSeconds
        }
        return beats
    }

    // MARK: - DSP helpers

    /// Periodic Hann window of `n` points.
    private static func hannWindow(_ n: Int) -> [Float] {
        var w = [Float](repeating: 0, count: n)
        // vDSP_hann_window with HANN_NORM gives a standard Hann; HANN_DENORM is the raw window.
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        return w
    }

    /// Thin wrapper over a real forward FFT producing a per-bin magnitude spectrum.
    /// Scaling is intentionally left consistent-but-unnormalized: spectral flux and autocorrelation
    /// only care about relative magnitudes, so an exact dB scale is unnecessary.
    private final class FFT {
        private let log2n: vDSP_Length
        private let size: Int
        private let bins: Int
        private let setup: FFTSetup

        // Reusable split-complex storage.
        private var realp: [Float]
        private var imagp: [Float]

        init?(size: Int) {
            // Require a power of two.
            guard size > 0, (size & (size - 1)) == 0 else { return nil }
            let l2 = vDSP_Length(log2(Double(size)).rounded())
            guard let s = vDSP_create_fftsetup(l2, FFTRadix(kFFTRadix2)) else { return nil }
            self.setup = s
            self.log2n = l2
            self.size = size
            self.bins = size / 2
            self.realp = [Float](repeating: 0, count: size / 2)
            self.imagp = [Float](repeating: 0, count: size / 2)
        }

        deinit {
            vDSP_destroy_fftsetup(setup)
        }

        /// Compute the magnitude spectrum of a real `signal` of length `size` into `out` (length `bins`).
        func magnitudes(of signal: [Float], into out: inout [Float]) {
            precondition(signal.count == size, "FFT input length must equal configured size")
            precondition(out.count == bins, "FFT output length must equal bins")

            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)

                    // Pack the real signal into split-complex form (even → real, odd → imag).
                    signal.withUnsafeBufferPointer { sig in
                        sig.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { typed in
                            vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(size / 2))
                        }
                    }

                    // In-place real forward FFT.
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                    // Magnitudes from the half-spectrum. Note: realp[0] is DC, imagp[0] is Nyquist
                    // (packed). We zero those interleaved terms' cross-contamination by computing
                    // straightforward magnitude per bin; the DC/Nyquist packing only affects bin 0,
                    // which is irrelevant for flux.
                    out.withUnsafeMutableBufferPointer { o in
                        vDSP_zvabs(&split, 1, o.baseAddress!, 1, vDSP_Length(bins))
                    }
                }
            }
        }
    }
}
