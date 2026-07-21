import Foundation
import SwiftData

/// One thumbs-up/down on a transition the user just heard. Votes are keyed by the *directional*
/// track pair (A→B is rated separately from B→A — the blend is not symmetric), and each vote
/// snapshots the settings that actually produced the blend, so a downvote on an adapted (already
/// simplified) transition is distinguishable from one on the user's full settings.
///
/// Plain UUID references instead of SwiftData relationships on purpose: votes must survive a
/// track being deleted and re-imported mid-history without cascade rules getting involved, and
/// the adaptation lookup only ever needs the IDs.
@Model
public final class TransitionVote {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    /// The outgoing track of the rated blend.
    public var fromTrackID: UUID
    /// The incoming track of the rated blend.
    public var toTrackID: UUID
    public var isUpvote: Bool

    // Snapshot of the blend that was rated.
    public var durationSeconds: Double
    public var beatmatchEnabled: Bool
    public var bassSwapEnabled: Bool
    public var harmonicMixingEnabled: Bool
    public var vocalModeRaw: String
    /// The simplification level the engine had already applied to this blend (0 = the user's
    /// settings as configured).
    public var simplificationLevel: Int

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        fromTrackID: UUID,
        toTrackID: UUID,
        isUpvote: Bool,
        settings: TransitionSettings,
        simplificationLevel: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.fromTrackID = fromTrackID
        self.toTrackID = toTrackID
        self.isUpvote = isUpvote
        self.durationSeconds = settings.durationSeconds
        self.beatmatchEnabled = settings.beatmatchEnabled
        self.bassSwapEnabled = settings.bassSwapEnabled
        self.harmonicMixingEnabled = settings.harmonicMixingEnabled
        self.vocalModeRaw = settings.vocalMode.rawValue
        self.simplificationLevel = simplificationLevel
    }
}
