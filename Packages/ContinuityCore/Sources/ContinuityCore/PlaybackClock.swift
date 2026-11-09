import Foundation

/// Pure arithmetic between AVAudio's render clock and the app's notion of "seconds into the
/// track". Lives here, away from AVFoundation, because every past "transient" playback crash
/// was one of these conversions going wrong on a disturbed clock — a `sampleRate` of 0 turning
/// into `.infinity`, a stale host time authorizing `play(at:)` in the past, a negative frame
/// reaching `scheduleSegment`, a `Double → Int64` conversion trapping on NaN — and none of them
/// could be unit-tested while they were inlined in `Deck` behind `AVAudioPlayerNode`.
///
/// Every function here is total: no input (NaN, ±inf, zero rate, negative length) can trap,
/// and the degenerate answer is always "don't advance / start from the beginning / don't
/// anchor", never a number that poisons downstream layout or scheduling.
public enum PlaybackClock {
    /// Seconds a player has rendered, from its player-time sample position.
    /// Returns 0 when the clock cannot be trusted (zero/negative/non-finite rate, negative
    /// sample time), so the position simply holds for a tick instead of jumping to infinity.
    public static func elapsedSeconds(sampleTime: Int64, sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0, sampleTime >= 0 else { return 0 }
        let seconds = Double(sampleTime) / sampleRate
        return seconds.isFinite && seconds >= 0 ? seconds : 0
    }

    /// Duration of an audio file in seconds, or 0 when the format can't say.
    public static func durationSeconds(frameLength: Int64, sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0, frameLength > 0 else { return 0 }
        let seconds = Double(frameLength) / sampleRate
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// Frame range to schedule when seeking a file to `seconds`.
    ///
    /// Clamps into the file before converting: `Double → Int64` traps on infinity/NaN/out of
    /// range, and `scheduleSegment` raises an uncatchable ObjC exception on a negative start or
    /// a zero frame count. A request past the end (or an unusable format) yields `nil`, which
    /// callers treat as "nothing to schedule" rather than a reason to crash.
    public static func segment(
        seconds: Double,
        sampleRate: Double,
        frameLength: Int64
    ) -> (startFrame: Int64, frameCount: UInt32)? {
        guard sampleRate.isFinite, sampleRate > 0, frameLength > 0 else { return nil }
        let fileSeconds = Double(frameLength) / sampleRate
        let safeSeconds = seconds.isFinite ? min(max(0, seconds), fileSeconds) : 0
        let rawFrame = safeSeconds * sampleRate
        guard rawFrame.isFinite else { return nil }
        // `Double(Int64.max)` rounds UP to 2^63, so a frame count near the top of Int64 can
        // produce a `rawFrame` that `Int64(_:)` traps on even though it was clamped "into"
        // the file. Compare in Double first; only convert values that provably fit.
        let startFrame = rawFrame >= Double(Int64.max) ? frameLength : min(Int64(rawFrame), frameLength)
        let remaining = frameLength - startFrame
        guard remaining > 0 else { return nil }
        // AVAudioFrameCount is UInt32; a corrupt header can claim more frames than that.
        let frameCount = remaining > Int64(UInt32.max) ? UInt32.max : UInt32(remaining)
        return (startFrame, frameCount)
    }

    /// Whether a player node's last render timestamp may anchor a shared `play(at:)` start.
    ///
    /// Requires a render cycle from THIS engine run (`renderHostTime >= engineStartedAtHostTime`)
    /// that is not in the future and is younger than `maximumAge`. A *valid-but-stale* timestamp
    /// from before an interruption/restart would put the anchored start in the past, which
    /// AVFAudio reports with an uncatchable exception — the original Siri-announcement SIGABRT.
    public static func isRenderClockUsable(
        renderHostTime: UInt64,
        engineStartedAtHostTime: UInt64,
        now: UInt64,
        maximumAge: UInt64
    ) -> Bool {
        renderHostTime >= engineStartedAtHostTime
            && renderHostTime <= now
            && now - renderHostTime < maximumAge
    }
}

/// Bounds for `AVAudioUnitTimePitch` parameters. The unit's own valid ranges are 1/32…32 for
/// rate and ±2400 cents for pitch; values outside them (and non-finite values, which a NaN
/// BPM ratio can produce) raise inside the audio unit. Beatmatching never needs more than a
/// few percent and key-sync never more than a semitone, so the clamps are far tighter than
/// the unit's limits — anything beyond them is a bug upstream, not a musical intent.
public enum TimePitchLimits {
    public static let minimumRate: Float = 0.5
    public static let maximumRate: Float = 2.0
    public static let maximumPitchCents: Float = 1_200

    /// Clamps a playback rate into `minimumRate…maximumRate`; non-finite → 1 (unchanged tempo).
    public static func clampRate(_ rate: Float) -> Float {
        guard rate.isFinite else { return 1 }
        return min(max(rate, minimumRate), maximumRate)
    }

    /// Clamps a pitch offset into ±`maximumPitchCents`; non-finite → 0 (true pitch).
    public static func clampPitchCents(_ cents: Float) -> Float {
        guard cents.isFinite else { return 0 }
        return min(max(cents, -maximumPitchCents), maximumPitchCents)
    }
}
