import Foundation

/// Pure logic for transition voting: turns a track-pair's thumbs-up/down history into a
/// *simplification level* the engine applies to that pair's next blend. The idea: when a fancy
/// transition (beatmatched, key-shifted, vocal-aware) gets downvoted, the next attempt backs
/// off toward a plain short crossfade one notch at a time; upvotes climb back toward the user's
/// configured settings.
public enum TransitionFeedback {
    /// Levels are 0 (user's settings untouched) through `maxSimplificationLevel` (minimal,
    /// radio-style fade). What each notch disables is the engine's mapping, not ours — this
    /// type only decides *how far* to back off.
    public static let maxSimplificationLevel = 3

    /// Only the most recent votes count, so a pair the user once hated can climb back to full
    /// settings after a few upvotes instead of dragging years of history around.
    public static let voteWindow = 8

    /// The simplification level for a pair, from its vote history.
    /// - Parameter votes: chronological (oldest first) votes for one directional track pair;
    ///   `true` = thumbs up.
    /// - Returns: `max(downs - ups, 0)` over the last `voteWindow` votes, clamped to
    ///   `maxSimplificationLevel`.
    public static func simplificationLevel(votes: [Bool]) -> Int {
        let recent = votes.suffix(voteWindow)
        let net = recent.reduce(0) { $0 + ($1 ? -1 : 1) }
        return min(max(net, 0), maxSimplificationLevel)
    }
}
