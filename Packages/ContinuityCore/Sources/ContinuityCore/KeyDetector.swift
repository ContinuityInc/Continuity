import Foundation
import Accelerate

/// The result of a musical-key estimate over a block of PCM audio.
///
/// `camelot` is always `key.camelot`; it is surfaced directly so callers doing
/// harmonic-mixing decisions don't have to reach through the key.
public struct KeyAnalysis: Sendable, Equatable {
    /// The most likely musical key.
    public let key: MusicalKey
    /// The Camelot code for `key` (`== key.camelot`).
    public let camelot: Camelot
    /// How strongly the chroma matched the winning key profile, mapped to 0...1.
    public let confidence: Double

    public init(key: MusicalKey, confidence: Double) {
        self.key = key
        self.camelot = key.camelot
        self.confidence = confidence
    }
}

/// Estimates the musical key of mono PCM audio using the Krumhansl–Schmuckler
/// key-finding algorithm: build a 12-bin chroma vector from an STFT, then correlate
/// it against the 24 rotated major/minor key profiles and pick the best fit.
///
/// Pure Swift + Accelerate (vDSP) only, so it compiles and unit-tests via `swift test`
/// without any audio framework.
public enum KeyDetector {

    /// Estimate the key of already-downmixed mono audio.
    ///
    /// - Parameters:
    ///   - samples: mono PCM float samples.
    ///   - sampleRate: sample rate in Hz.
    /// - Returns: the best key estimate, or `nil` if the input is empty or too short
    ///   to produce a single analysis frame.
    public static func analyze(samples: [Float], sampleRate: Double) -> KeyAnalysis? {
        guard sampleRate > 0 else { return nil }
        guard let chroma = makeChroma(samples: samples, sampleRate: sampleRate) else {
            return nil
        }
        return classify(chroma: chroma)
    }

    // MARK: - Tuning constants

    private static let frameSize = 4096
    private static let hopSize = 2048
    private static let minHz: Double = 55.0    // ~A1
    private static let maxHz: Double = 5000.0

    // Krumhansl–Kessler key profiles, C-rooted.
    private static let majorProfile: [Double] =
        [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Double] =
        [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    // MARK: - Chroma

    /// Build a normalized 12-bin chroma vector (index 0 = C ... 11 = B) from the STFT magnitude
    /// spectrum, **corrected for global tuning** so recordings that sit off A440 (very common) still
    /// land in the right pitch classes. Returns `nil` if the audio is too short for even one frame.
    private static func makeChroma(samples: [Float], sampleRate: Double) -> [Double]? {
        let n = samples.count
        guard n >= frameSize else { return nil }

        // Precompute the radix-2 FFT setup for `frameSize`.
        let log2n = vDSP_Length(log2(Double(frameSize)).rounded())
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let halfN = frameSize / 2
        let window = makeHannWindow(frameSize)

        // Continuous MIDI number of each FFT bin (NaN if out of [minHz, maxHz]).
        var binMidi = [Double](repeating: .nan, count: halfN)
        for bin in 1..<halfN {  // skip DC bin
            let f = Double(bin) * sampleRate / Double(frameSize)
            if f >= minHz && f <= maxHz {
                binMidi[bin] = 69.0 + 12.0 * log2(f / 440.0)
            }
        }

        // Sum the magnitude spectrum across all frames. Chroma is linear in magnitude, so summing
        // the spectra first (then binning) is equivalent to per-frame binning — and it gives the
        // tuning estimate the whole track's spectrum to work with.
        var magSum = [Double](repeating: 0, count: halfN)

        // Reusable buffers for the split-complex FFT.
        var windowed = [Float](repeating: 0, count: frameSize)
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)

        var frameStart = 0
        while frameStart + frameSize <= n {
            samples.withUnsafeBufferPointer { src in
                window.withUnsafeBufferPointer { win in
                    vDSP_vmul(src.baseAddress! + frameStart, 1,
                              win.baseAddress!, 1,
                              &windowed, 1, vDSP_Length(frameSize))
                }
            }

            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!,
                                                imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                          capacity: halfN) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(halfN))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfN))
                }
            }

            for bin in 1..<halfN { magSum[bin] += Double(magnitudes[bin]) }
            frameStart += hopSize
        }

        let tuning = estimateTuningSemitones(binMidi: binMidi, magSum: magSum, halfN: halfN)

        // Bin into pitch classes using the tuning-corrected note number, splitting each bin between
        // its two nearest pitch classes (linear interpolation) so a bin sitting between semitones
        // doesn't tip entirely one way — this keeps the chroma stable near rounding boundaries.
        var chroma = [Double](repeating: 0, count: 12)
        for bin in 1..<halfN {
            let midi = binMidi[bin]
            if midi.isNaN { continue }
            let corrected = midi - tuning
            let lower = floor(corrected)
            let frac = corrected - lower                 // [0, 1)
            var pcLow = Int(lower) % 12
            if pcLow < 0 { pcLow += 12 }
            let pcHigh = (pcLow + 1) % 12
            let w = magSum[bin]
            chroma[pcLow] += w * (1 - frac)
            chroma[pcHigh] += w * frac
        }

        // Normalize by L2 norm so the correlation isn't level-dependent.
        let norm = sqrt(chroma.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        for i in 0..<12 { chroma[i] /= norm }
        return chroma
    }

    /// Estimate the recording's global tuning offset from equal-temperament, in semitones within
    /// `[-0.5, 0.5]`, as the magnitude-weighted circular mean of every bin's deviation from its
    /// nearest semitone. A track mastered ~45¢ flat returns ≈ -0.45, which we then subtract before
    /// quantizing — otherwise those bins tip across the rounding boundary and shift the whole
    /// chroma by a semitone (the dominant real-world key-detection failure).
    private static func estimateTuningSemitones(binMidi: [Double], magSum: [Double], halfN: Int) -> Double {
        // Use only local spectral peaks well above the noise floor: their frequencies sit right on
        // the played notes, so their deviations cluster tightly at the true offset. Averaging every
        // bin instead lets windowing leakage straddle the ±0.5 wrap and bias the estimate.
        let maxMag = magSum.max() ?? 0
        guard maxMag > 0 else { return 0 }
        let threshold = maxMag * 0.05

        var sinAcc = 0.0
        var cosAcc = 0.0
        for bin in 2..<(halfN - 1) {
            let midi = binMidi[bin]
            if midi.isNaN { continue }
            let m = magSum[bin]
            guard m > threshold, m >= magSum[bin - 1], m >= magSum[bin + 1] else { continue }
            let dev = midi - midi.rounded()          // deviation from nearest semitone, [-0.5, 0.5]
            let angle = 2.0 * Double.pi * dev         // wrap at the ±0.5 boundary
            sinAcc += m * sin(angle)
            cosAcc += m * cos(angle)
        }
        guard sinAcc != 0 || cosAcc != 0 else { return 0 }
        return atan2(sinAcc, cosAcc) / (2.0 * Double.pi)
    }

    private static func makeHannWindow(_ size: Int) -> [Float] {
        var w = [Float](repeating: 0, count: size)
        vDSP_hann_window(&w, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        return w
    }

    // MARK: - Classification

    /// Correlate the chroma against all 24 rotated key profiles and return the best fit.
    private static func classify(chroma: [Double]) -> KeyAnalysis {
        var bestTonic = 0
        var bestIsMinor = false
        var bestCorrelation = -Double.infinity

        for tonic in 0..<12 {
            let majorR = pearson(chroma, rotate(majorProfile, by: tonic))
            if majorR > bestCorrelation {
                bestCorrelation = majorR
                bestTonic = tonic
                bestIsMinor = false
            }
            let minorR = pearson(chroma, rotate(minorProfile, by: tonic))
            if minorR > bestCorrelation {
                bestCorrelation = minorR
                bestTonic = tonic
                bestIsMinor = true
            }
        }

        let key = musicalKey(tonic: bestTonic, isMinor: bestIsMinor)
        // Map correlation (-1...1) into a 0...1 confidence; negatives clamp to 0.
        let confidence = max(0.0, min(1.0, bestCorrelation))
        return KeyAnalysis(key: key, confidence: confidence)
    }

    /// Rotate a C-rooted profile so its tonic sits at pitch class `tonic`.
    /// Result index `pc` holds the profile weight for that pitch class.
    private static func rotate(_ profile: [Double], by tonic: Int) -> [Double] {
        var out = [Double](repeating: 0, count: 12)
        for i in 0..<12 {
            out[(i + tonic) % 12] = profile[i]
        }
        return out
    }

    /// Pearson correlation coefficient between two 12-element vectors.
    private static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let count = Double(a.count)
        let meanA = a.reduce(0, +) / count
        let meanB = b.reduce(0, +) / count
        var num = 0.0
        var denA = 0.0
        var denB = 0.0
        for i in 0..<a.count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            num += da * db
            denA += da * da
            denB += db * db
        }
        let den = sqrt(denA * denB)
        return den == 0 ? 0 : num / den
    }

    /// Map a (tonic pitch class, mode) pair to the existing `MusicalKey` case,
    /// using the enharmonic spellings defined in Camelot.swift.
    /// Pitch classes: 0 C, 1 C#/Db, 2 D, 3 D#/Eb, 4 E, 5 F,
    ///                6 F#/Gb, 7 G, 8 G#/Ab, 9 A, 10 A#/Bb, 11 B.
    private static func musicalKey(tonic: Int, isMinor: Bool) -> MusicalKey {
        if isMinor {
            switch tonic {
            case 0:  return .cMinor
            case 1:  return .cSharpMinor
            case 2:  return .dMinor
            case 3:  return .dSharpMinor
            case 4:  return .eMinor
            case 5:  return .fMinor
            case 6:  return .fSharpMinor
            case 7:  return .gMinor
            case 8:  return .gSharpMinor
            case 9:  return .aMinor
            case 10: return .bFlatMinor
            default: return .bMinor   // 11
            }
        } else {
            switch tonic {
            case 0:  return .cMajor
            case 1:  return .dFlatMajor
            case 2:  return .dMajor
            case 3:  return .eFlatMajor
            case 4:  return .eMajor
            case 5:  return .fMajor
            case 6:  return .fSharpMajor
            case 7:  return .gMajor
            case 8:  return .aFlatMajor
            case 9:  return .aMajor
            case 10: return .bFlatMajor
            default: return .bMajor   // 11
            }
        }
    }
}
