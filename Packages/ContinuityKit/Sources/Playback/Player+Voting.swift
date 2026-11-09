import Foundation
import Domain
import ContinuityCore

/// A blend the user can rate: created when a transition starts, completed (timestamped) when the
/// decks swap. The UI shows thumbs while the record exists; the app layer persists the vote and
/// the engine adapts the pair's next blend from the accumulated history.
public struct TransitionRecord: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let fromTrackID: UUID
    public let toTrackID: UUID
    public let fromTitle: String
    public let toTitle: String
    /// The settings the blend actually ran with (post-adaptation).
    public let settings: TransitionSettings
    /// How far the engine had already backed this pair off (0 = user's settings).
    public let simplificationLevel: Int
    /// Set when the blend finishes; nil while it's still in flight.
    public var completedAt: Date?
}

extension Player {
    /// Vote history for a directional track pair (chronological, `true` = thumbs up), supplied
    /// by the app layer from SwiftData — same hook pattern as `onQueueExhausted`. nil (unwired)
    /// disables adaptation.
    /// Set via `configureTransitionVoting` so the adaptation cache can't serve stale history.
    public var transitionVoteHistory: ((UUID, UUID) -> [Bool])? {
        get { transitionVoteHistoryStorage }
        set { transitionVoteHistoryStorage = newValue; adaptationCache = nil }
    }

    /// The settings the next blend from `from` into `to` should run with, given the pair's vote
    /// history. Cached per pair because the scheduling check runs at 20 Hz and the history lookup
    /// is a SwiftData fetch.
    func adaptedTransitionSettings(from: Track?, to: Track) -> (settings: TransitionSettings, level: Int) {
        guard let from, let historyProvider = transitionVoteHistoryStorage else {
            return (transitionSettings, 0)
        }
        if let cached = adaptationCache,
           cached.fromID == from.id, cached.toID == to.id, cached.base == transitionSettings {
            return (cached.settings, cached.level)
        }
        let level = TransitionFeedback.simplificationLevel(votes: historyProvider(from.id, to.id))
        let settings = level > 0 ? transitionSettings.simplified(level: level) : transitionSettings
        adaptationCache = (from.id, to.id, transitionSettings, settings, level)
        return (settings, level)
    }

    /// Drops the cached per-pair adaptation so the next scheduling tick re-reads vote history.
    /// The app layer calls this after persisting a new vote.
    public func invalidateTransitionAdaptation() {
        adaptationCache = nil
    }
}
