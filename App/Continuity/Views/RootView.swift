import SwiftUI
import Domain
import SwiftData

/// Top-level shell: the app always opens onto the minimal Now Playing screen, resuming the
/// previous session's song (or staging COMË N GO on first launch). The library lives in a
/// sheet behind its corner button.
struct RootView: View {
    @Environment(Player.self) private var player
    @Environment(PreparationQueue.self) private var prepQueue
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        MinimalNowPlayingView()
            // On launch: drop cached files orphaned by deletions, resume unfinished ingestion,
            // then bring back the previous playback session (or stage the first-run track).
            .task {
                // Sync-driven deletions must clear the live queue before models are destroyed.
                prepQueue.onTracksDeleted = { [weak player] ids in
                    player?.handleDeleted(trackIDs: ids)
                }
                // Stems are prepared just-in-time for the play-queue neighborhood, not eagerly
                // for the whole library (CPU-hours + gigabytes). Wire before restore so the
                // restored session's tracks get their stems going immediately.
                player.onUpcomingTracks = { [weak prepQueue] tracks in
                    prepQueue?.ensureStems(for: tracks, in: modelContext)
                }
                LibraryCleanup.sweepOrphanedFiles(in: modelContext)
                prepQueue.resumePreparation(in: modelContext)
                restorePlaybackSession()
                // Launch-time polling pass over source-backed playlists (per-playlist opt-out).
                prepQueue.autoSyncIfNeeded(in: modelContext)
            }
    }

    /// Restores the persisted session — same song, position, skip budget, and history — or, on a
    /// fresh install, stages COMË N GO paused at the start of its playlist.
    private func restorePlaybackSession() {
        guard player.currentTrack == nil else { return }   // already playing (e.g. state restore re-entry)
        let tracks = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []

        if let state = PlaybackStateStore.load() {
            let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            player.restore(state, resolving: byID)
            if player.currentTrack != nil { return }
            // Every persisted track was deleted — fall through to the first-run seed.
        }

        // First launch (or an emptied library): COMË N GO is always the first song. Prefer the
        // real ingested track over the demo of the same name; queue its whole playlist from there.
        let candidates = tracks.filter { $0.title.localizedCaseInsensitiveContains("COMË N GO") }
        guard let seed = candidates.first(where: { !$0.isDemo }) ?? candidates.first,
              let playlist = seed.playlist else { return }
        let queue = playlist.orderedTracks
        guard let index = queue.firstIndex(where: { $0.id == seed.id }) else { return }
        player.prepare(tracks: queue, startAt: index)
    }
}
