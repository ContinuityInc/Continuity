import AVFoundation
import Domain
import Observation
import ContinuityCore
import os

extension Player {
    /// Records that we're leaving `track` by moving forward, so previous() can come back to it.
    func pushHistory(_ track: Track?) {
        guard let track else { return }
        historyIDs.append(track.id)
        if historyIDs.count > 200 { historyIDs.removeFirst(historyIDs.count - 200) }
    }

    /// Republishes lock-screen / Control Center info after `track`'s title or artist was edited.
    /// In-app views observe the model directly, but `MPNowPlayingInfoCenter` only hears from
    /// us on playback discontinuities (or the ~5 s periodic save) — so without this a rename
    /// of the current song lingers on the lock screen.
    public func refreshNowPlayingMetadata(for track: Track) {
        guard let current = currentTrack, current.id == track.id else { return }
        nowPlayingBridge.update(
            track: current,
            duration: duration,
            position: position,
            isPlaying: isPlaying,
            skipsRemaining: skipsRemaining
        )
    }

    /// Saves the full playback session (queue, position, skips, history) for the next launch,
    /// and mirrors the same state to the lock screen / Control Center. Every playback
    /// discontinuity funnels through here, which is exactly when both need updating.
    func persistState() {
        // Every playback discontinuity funnels through here, which is also exactly when the
        // scheduled-blend countdown moves for a reason other than the clock ticking.
        refreshTransitionCountdown()
        nowPlayingBridge.update(
            track: currentTrack,
            duration: duration,
            position: position,
            isPlaying: isPlaying,
            skipsRemaining: skipsRemaining
        )
        guard !queue.isEmpty else { return }
        // queue.map(\.id) reads a SwiftData property per queued track — wasteful for the ~5 s
        // periodic save where the queue hasn't changed. The cache invalidates on queue mutation
        // (didSet in Player.swift), so the periodic save reuses the same array.
        if cachedQueueIDs == nil { cachedQueueIDs = queue.map(\.id) }
        PlaybackStateStore.save(PersistedPlaybackState(
            queueTrackIDs: cachedQueueIDs ?? queue.map(\.id),
            currentIndex: currentIndex,
            positionSeconds: position,
            skipsRemaining: skipsRemaining,
            historyTrackIDs: historyIDs
        ))
    }
}
