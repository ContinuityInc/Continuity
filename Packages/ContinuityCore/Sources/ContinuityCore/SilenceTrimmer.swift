import Foundation

/// Pure detection of leading/trailing silence in decoded audio, for gapless playback.
///
/// Mastered tracks often carry a second or more of near-silence at the tail (and sometimes the
/// head). A transition scheduled off the *file* duration then blends into dead air — the incoming
/// track fades in over nothing, which reads as a gap. Trimming to the **audible bounds** lets the
/// engine treat the last audible moment as the track's end.
public enum SilenceTrimmer {

    /// The audible span of a track, in seconds from the start of the audio.
    public struct Bounds: Equatable, Sendable {
        /// Time of the first audible audio (0 when the track starts immediately).
        public var audibleStart: Double
        /// Time just after the last audible audio (== duration when there is no trailing silence).
        public var audibleEnd: Double

        public init(audibleStart: Double, audibleEnd: Double) {
            self.audibleStart = audibleStart
            self.audibleEnd = audibleEnd
        }
    }

    /// Scans mono samples for the first/last window whose RMS exceeds `thresholdDB` (dBFS).
    ///
    /// - Windows of `windowSeconds` (50 ms default) are scanned from each end; the bounds snap to
    ///   window edges — plenty of precision for transition timing.
    /// - `thresholdDB` defaults to −48 dBFS: quiet enough that a musical fade-out's tail counts as
    ///   audible until it truly disappears, loud enough that mastering noise floors don't.
    /// - **All-silent audio returns the full span** (nothing is trimmed) — a track that never
    ///   crosses the threshold is better left alone than zeroed out.
    public static func audibleBounds(
        samples: [Float],
        sampleRate: Double,
        thresholdDB: Double = -48,
        windowSeconds: Double = 0.05
    ) -> Bounds {
        let duration = Double(samples.count) / sampleRate
        let window = max(1, Int(windowSeconds * sampleRate))
        guard !samples.isEmpty, sampleRate > 0 else { return Bounds(audibleStart: 0, audibleEnd: 0) }

        let threshold = pow(10.0, thresholdDB / 20.0)   // dBFS → linear amplitude

        func windowIsAudible(startingAt start: Int) -> Bool {
            let end = min(start + window, samples.count)
            var sum = 0.0
            for i in start..<end {
                let s = Double(samples[i])
                sum += s * s
            }
            let rms = (sum / Double(end - start)).squareRoot()
            return rms > threshold
        }

        // First audible window from the head.
        var firstAudible: Int?
        var start = 0
        while start < samples.count {
            if windowIsAudible(startingAt: start) { firstAudible = start; break }
            start += window
        }

        // Nothing above the threshold anywhere → leave the track untrimmed.
        guard let head = firstAudible else { return Bounds(audibleStart: 0, audibleEnd: duration) }

        // Last audible window from the tail.
        var tailEnd = duration
        var tailStart = ((samples.count - 1) / window) * window
        while tailStart >= head {
            if windowIsAudible(startingAt: tailStart) {
                tailEnd = min(Double(tailStart + window) / sampleRate, duration)
                break
            }
            tailStart -= window
        }

        return Bounds(
            audibleStart: Double(head) / sampleRate,
            audibleEnd: tailEnd
        )
    }
}
