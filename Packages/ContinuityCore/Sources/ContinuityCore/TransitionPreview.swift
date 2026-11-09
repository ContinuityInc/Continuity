import Foundation

/// A pure, display-oriented summary of what a transition between two tracks will do: the
/// crossfade shape, tempo match, harmonic (key) match, and bass-swap flag. Built from
/// primitives (BPMs, Camelot code strings, toggles) so `ContinuityCore` stays free of any
/// `Domain`/audio dependency — the app maps its `Track`/`TransitionSettings` onto `make(...)`.
public struct TransitionPreview: Equatable, Sendable {
    /// The tempo relationship shown to the listener when beatmatching is active.
    public struct TempoMatch: Equatable, Sendable {
        public let outgoingBPM: Double
        public let incomingBPM: Double
        /// Rate applied to the incoming deck to match the outgoing tempo (1 = no change,
        /// already resolved to the nearest half/double-time interpretation).
        public let matchedRate: Double
        /// `(matchedRate - 1) * 100` — signed percent tempo adjustment (round at display time).
        public let percentAdjust: Double

        public init(outgoingBPM: Double, incomingBPM: Double, matchedRate: Double, percentAdjust: Double) {
            self.outgoingBPM = outgoingBPM
            self.incomingBPM = incomingBPM
            self.matchedRate = matchedRate
            self.percentAdjust = percentAdjust
        }
    }

    /// The harmonic (key) relationship shown when harmonic mixing is active.
    public struct KeyMatch: Equatable, Sendable {
        public let outgoingCode: String
        public let incomingCode: String
        /// Whether the two keys are Camelot-compatible as-is.
        public let compatible: Bool
        /// Semitone pitch shift applied to the incoming track to reach compatibility (0 if none).
        public let appliedShiftSemitones: Int

        public init(outgoingCode: String, incomingCode: String, compatible: Bool, appliedShiftSemitones: Int) {
            self.outgoingCode = outgoingCode
            self.incomingCode = incomingCode
            self.compatible = compatible
            self.appliedShiftSemitones = appliedShiftSemitones
        }
    }

    public let curve: CrossfadeCurve
    public let duration: TimeInterval
    /// nil when beatmatching is disabled or either BPM is missing / non-positive / the required
    /// time-stretch is too large to apply (the engine then blends without tempo matching).
    public let tempo: TempoMatch?
    /// nil when harmonic mixing is disabled or either Camelot code is missing / unparseable.
    public let key: KeyMatch?
    public let bassSwap: Bool

    public init(
        curve: CrossfadeCurve,
        duration: TimeInterval,
        tempo: TempoMatch?,
        key: KeyMatch?,
        bassSwap: Bool
    ) {
        self.curve = curve
        self.duration = duration
        self.tempo = tempo
        self.key = key
        self.bassSwap = bassSwap
    }

    /// Aggregates the display facts of a transition from primitive inputs, reusing the same
    /// verified `BeatMath` / `Camelot` logic the audio engine uses so the preview never disagrees
    /// with what actually happens.
    public static func make(
        curve: CrossfadeCurve,
        duration: TimeInterval,
        outgoingBPM: Double?,
        incomingBPM: Double?,
        outgoingCamelot: String?,
        incomingCamelot: String?,
        beatmatchEnabled: Bool,
        harmonicEnabled: Bool,
        bassSwapEnabled: Bool
    ) -> TransitionPreview {
        var tempo: TempoMatch?
        if beatmatchEnabled,
           let outBPM = outgoingBPM, let inBPM = incomingBPM,
           outBPM > 0, inBPM > 0,
           let rate = BeatMath.matchRate(incomingBPM: inBPM, outgoingBPM: outBPM) {
            tempo = TempoMatch(
                outgoingBPM: outBPM,
                incomingBPM: inBPM,
                matchedRate: rate,
                percentAdjust: (rate - 1) * 100
            )
        }

        var key: KeyMatch?
        if harmonicEnabled,
           let outCode = outgoingCamelot, let inCode = incomingCamelot,
           let out = Camelot.parse(outCode), let inc = Camelot.parse(inCode) {
            let shift = HarmonicMix.pitchShiftSemitones(incoming: inc, outgoing: out) ?? 0
            key = KeyMatch(
                outgoingCode: out.code,
                incomingCode: inc.code,
                compatible: out.isCompatible(with: inc),
                appliedShiftSemitones: shift
            )
        }

        return TransitionPreview(
            curve: curve,
            duration: duration,
            tempo: tempo,
            key: key,
            bassSwap: bassSwapEnabled
        )
    }
}

/// Maps the two tracks' beat grids onto the shared transition x-axis (`0...1`) so a view can
/// draw how the outgoing tail beats line up against the incoming intro beats. Pure and tested:
/// the app only supplies beat times and window bounds.
public enum BeatWindow {
    /// Normalized (`0...1`) positions of the outgoing track's beats within the final `duration`
    /// seconds ending at `windowEnd` (its audible end, or full duration). 0 = start of the blend.
    public static func outgoingPositions(beats: [Double], windowEnd: Double, duration: Double) -> [Double] {
        guard duration > 0 else { return [] }
        let start = windowEnd - duration
        return beats.compactMap { t in
            guard t >= start, t <= windowEnd else { return nil }
            return min(max((t - start) / duration, 0), 1)
        }
    }

    /// Normalized (`0...1`) positions of the incoming track's beats within the first `duration`
    /// seconds starting at `windowStart` (its audible start, or 0). 0 = start of the blend.
    public static func incomingPositions(beats: [Double], windowStart: Double, duration: Double) -> [Double] {
        guard duration > 0 else { return [] }
        let end = windowStart + duration
        return beats.compactMap { t in
            guard t >= windowStart, t <= end else { return nil }
            return min(max((t - windowStart) / duration, 0), 1)
        }
    }
}
