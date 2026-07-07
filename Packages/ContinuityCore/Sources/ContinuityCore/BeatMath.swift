import Foundation

/// Pure math for beat-synchronised transitions: tempo ratios, stretch clamping, and the
/// sample offset needed to line up an incoming track's downbeat with an outgoing beat.
/// All of this is engine-agnostic so it can be unit-tested without audio hardware.
public enum BeatMath {

    /// The playback-rate multiplier required to retempo `fromBPM` to `toBPM`.
    /// e.g. matching a 124 BPM track up to 128 BPM → 128/124 ≈ 1.032.
    public static func tempoRatio(fromBPM: Double, toBPM: Double) -> Double {
        precondition(fromBPM > 0 && toBPM > 0, "BPM must be positive")
        return toBPM / fromBPM
    }

    /// Whether `ratio` is within an acceptable time-stretch window. Beyond roughly ±8%,
    /// time-stretching audibly degrades, so the engine should fall back to a
    /// non-beatmatched style instead of forcing the match.
    public static func isStretchAcceptable(_ ratio: Double, maxPercent: Double = 8) -> Bool {
        let pct = abs(ratio - 1) * 100
        return pct <= maxPercent + 1e-9
    }

    /// Some tracks beatmatch better at half/double tempo (e.g. an 85 BPM track against a
    /// 170 BPM track). Returns the tempo ratio with the smallest required stretch among
    /// `toBPM`, `toBPM/2`, and `toBPM*2`.
    public static func bestTempoRatio(fromBPM: Double, toBPM: Double) -> Double {
        let candidates = [toBPM, toBPM * 2, toBPM / 2]
        return candidates
            .map { tempoRatio(fromBPM: fromBPM, toBPM: $0) }
            .min(by: { abs($0 - 1) < abs($1 - 1) })!
    }

    /// Duration of one beat, in seconds, at the given tempo.
    public static func secondsPerBeat(bpm: Double) -> Double {
        precondition(bpm > 0, "BPM must be positive")
        return 60.0 / bpm
    }

    /// The playback rate to apply to an INCOMING track so it beat-matches the outgoing track,
    /// using the nearest half/double interpretation. Returns `nil` when either tempo is unknown
    /// or the required time-stretch exceeds `maxPercent` — beyond which stretching audibly degrades,
    /// so the caller should fall back to a non-beatmatched (plain equal-power) crossfade.
    public static func matchRate(incomingBPM: Double, outgoingBPM: Double, maxPercent: Double = 8) -> Double? {
        guard incomingBPM > 0, outgoingBPM > 0 else { return nil }
        let ratio = bestTempoRatio(fromBPM: incomingBPM, toBPM: outgoingBPM)
        return isStretchAcceptable(ratio, maxPercent: maxPercent) ? ratio : nil
    }

    /// How many seconds to seek **into** the incoming track so that, when it starts playing now
    /// (with the outgoing track at `outgoingPosition`), one of its beats lands on an upcoming
    /// outgoing beat — phase-locking the two beat grids through the blend. This is the core of a
    /// beat-aligned transition: without it the incoming downbeat lands at a random phase and the
    /// two grooves fight.
    ///
    /// - Parameters:
    ///   - outgoingPosition: current playhead of the outgoing track (s).
    ///   - outgoingBeats: outgoing beat grid (s, ascending).
    ///   - incomingBeats: incoming beat grid (s, ascending).
    ///   - rate: playback rate applied to the incoming for tempo matching (its beats play back
    ///     `rate`× faster, so real-time spacing is scaled). 1 when not beatmatched.
    ///   - minLead: don't align to an outgoing beat sooner than this — we need a moment to actually
    ///     start the deck.
    ///   - maxSkip: cap on how much intro we'll skip; beyond this we decline (return nil) rather
    ///     than jump deep into the track. Guards against sparse/mis-detected grids.
    /// - Returns: the incoming seek offset (s) in `[0, maxSkip]`, or nil when no reasonable
    ///   alignment exists (caller should just start the incoming at 0).
    public static func incomingStartOffset(
        outgoingPosition: Double,
        outgoingBeats: [Double],
        incomingBeats: [Double],
        rate: Double = 1,
        minLead: Double = 0.08,
        maxSkip: Double = 2.0
    ) -> Double? {
        guard rate > 0, !incomingBeats.isEmpty else { return nil }
        // The outgoing beat we'll land the incoming on: the first one comfortably ahead.
        guard let outBeat = outgoingBeats.first(where: { $0 >= outgoingPosition + minLead }) else { return nil }
        let lead = outBeat - outgoingPosition          // real seconds until that outgoing beat
        let target = lead * rate                        // incoming file-seconds that must elapse first
        // Land the first incoming beat at/after `target` exactly on the outgoing beat.
        guard let inBeat = incomingBeats.first(where: { $0 >= target }) else { return nil }
        let offset = inBeat - target
        guard offset >= 0, offset <= maxSkip else { return nil }
        return offset
    }

    /// The sample frame at which to start the incoming deck so that its first downbeat
    /// lands exactly on the chosen outgoing beat.
    ///
    /// - Parameters:
    ///   - outgoingBeatTime: time (s) of the outgoing beat we are aligning to, measured
    ///     from the start of the outgoing track.
    ///   - incomingFirstBeatOffset: time (s) from the start of the incoming track's audio
    ///     to its first downbeat (its intro silence / pickup before beat 1).
    ///   - sampleRate: shared engine sample rate.
    /// - Returns: the outgoing-track sample frame at which the incoming deck must be
    ///   scheduled so the two downbeats coincide. May be negative if the incoming track
    ///   would need to have started before `outgoingBeatTime`, which the caller should
    ///   handle by choosing a later outgoing beat.
    public static func alignmentStartFrame(
        outgoingBeatTime: Double,
        incomingFirstBeatOffset: Double,
        sampleRate: Double
    ) -> Int {
        precondition(sampleRate > 0, "sampleRate must be positive")
        let startSeconds = outgoingBeatTime - incomingFirstBeatOffset
        return Int((startSeconds * sampleRate).rounded())
    }
}
