import Foundation

/// Pure, engine-agnostic logic for a crossfade between two decks: *when* a transition should
/// begin and the per-instant gains while it runs. The audio engine just applies these gains to
/// its deck volumes, so the timing and the equal-power blend are unit-tested with no audio hardware.
public struct TransitionPlan: Equatable, Sendable {
    public let curve: CrossfadeCurve
    /// Length of the blend in seconds (clamped to ≥ 0).
    public let duration: TimeInterval

    public init(curve: CrossfadeCurve, duration: TimeInterval) {
        self.curve = curve
        self.duration = max(0, duration)
    }

    /// Whether the crossfade into the next track should begin now.
    /// - Parameters:
    ///   - position: elapsed seconds of the **outgoing** track.
    ///   - trackDuration: total length of the outgoing track.
    ///   - hasNextTrack: whether there is a track to transition into.
    public func shouldStart(position: TimeInterval, trackDuration: TimeInterval, hasNextTrack: Bool) -> Bool {
        guard hasNextTrack, duration > 0, trackDuration > 0 else { return false }
        // Only crossfade when the track is meaningfully longer than the blend itself.
        guard trackDuration > duration else { return false }
        return position >= trackDuration - duration
    }

    /// Normalized progress (0...1) of a transition that began at `startPosition`, given the
    /// outgoing track's current `position`.
    public func progress(position: TimeInterval, startPosition: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return min(max((position - startPosition) / duration, 0), 1)
    }

    /// The outgoing/incoming gains at the outgoing track's current position.
    public func gains(position: TimeInterval, startPosition: TimeInterval) -> CrossfadeGains {
        curve.gains(at: progress(position: position, startPosition: startPosition))
    }

    /// Whether the transition has fully completed (incoming fully faded in).
    public func isComplete(position: TimeInterval, startPosition: TimeInterval) -> Bool {
        progress(position: position, startPosition: startPosition) >= 1
    }
}
