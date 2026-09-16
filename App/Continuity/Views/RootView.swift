import SwiftUI
import UIKit
import Ingest
import Playback
import Domain
import SwiftData

/// Top-level shell: the app always opens onto the minimal Now Playing page, resuming the
/// previous session's song (or staging COMË N GO on first launch). Library and Up Next are
/// sticky vertical neighbors (scroll up / down from home).
struct RootView: View {
    @Environment(Player.self) private var player
    @Environment(PreparationQueue.self) private var prepQueue
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        MainPagerView()
            // On launch: drop cached files orphaned by deletions, resume unfinished
            // preparation, then bring back the previous playback session (or stage the
            // first-run track).
            .task {
                // Deletions must clear the live queue before models are destroyed.
                prepQueue.onTracksDeleted = { [weak player] ids in
                    player?.handleDeleted(trackIDs: ids)
                }
                // Stems are prepared just-in-time for the play-queue neighborhood, not eagerly
                // for the whole library (CPU-hours + gigabytes). Wire before restore so the
                // restored session's tracks get their stems going immediately.
                player.onUpcomingTracks = { [weak prepQueue] tracks in
                    prepQueue?.ensureStems(for: tracks, in: modelContext)
                }
                // Transition voting: the engine asks for a pair's thumb history when scheduling
                // its next blend (cached per pair, so this fetch is rare, not per-tick).
                player.transitionVoteHistory = { fromID, toID in
                    let descriptor = FetchDescriptor<TransitionVote>(
                        predicate: #Predicate { $0.fromTrackID == fromID && $0.toTrackID == toID },
                        sortBy: [SortDescriptor(\.createdAt)]
                    )
                    return ((try? modelContext.fetch(descriptor)) ?? []).map(\.isUpvote)
                }
                // Natural queue exhaustion loops playback into the listening history — resolve
                // the persisted IDs to live tracks in order; deleted tracks simply drop out.
                player.onQueueExhausted = { ids in
                    // Only the id → Track mapping is needed; a bare fetch hydrates every row's
                    // `beatTimes` array (hundreds of doubles each) to build a dictionary of
                    // UUIDs. The rest of each surviving track faults in when it's played.
                    var descriptor = FetchDescriptor<Track>()
                    descriptor.propertiesToFetch = [\.id]
                    let tracks = (try? modelContext.fetch(descriptor)) ?? []
                    // `uniquingKeysWith`, not `uniqueKeysWithValues`: the latter traps on a
                    // duplicate key, and trapping is not the right answer to a store that
                    // handed back the same row twice.
                    let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    return ids.compactMap { byID[$0] }
                }
                LibraryCleanup.sweepOrphanedFiles(in: modelContext)
                // Restore the last song before walking the library for resume — otherwise
                // a large unfinished import occupies the main actor until the first frame.
                restorePlaybackSession()
                await Task.yield()
                await prepQueue.resumePreparation(in: modelContext)
            }
            // Memory warning precedes a jetsam kill: abort any in-flight stem separation and
            // free the ONNX session. Losing stems for one track beats losing the process.
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                prepQueue.handleMemoryPressure()
            }
    }

    // MARK: - Session restore

    /// Restores the persisted session — same song, position, skip budget, and history — or, on a
    /// fresh install, stages COMË N GO paused at the start of its playlist.
    private func restorePlaybackSession() {
        guard player.currentTrack == nil else { return }   // already playing (e.g. state restore re-entry)

        if let state = PlaybackStateStore.load() {
            // The common launch path only resolves ids to rows. Fetching whole tracks here
            // hydrated every one of them — `beatTimes` arrays included — on the launch path,
            // to build a dictionary of UUIDs.
            var descriptor = FetchDescriptor<Track>()
            descriptor.propertiesToFetch = [\.id]
            let stored = (try? modelContext.fetch(descriptor)) ?? []
            // Never trap on a duplicate id here — this is the cold-launch path.
            let byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            player.restore(state, resolving: byID)
            if player.currentTrack != nil { return }
            // Every persisted track was deleted — fall through to the first-run seed.
        }

        // First launch (or an emptied library): COMË N GO is always the first song. Prefer the
        // real ingested track over the demo of the same name; queue its whole playlist from there.
        let tracks = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
        let candidates = tracks.filter { $0.title.localizedCaseInsensitiveContains("COMË N GO") }
        guard let seed = candidates.first(where: { !$0.isDemo }) ?? candidates.first,
              let playlist = seed.playlist else { return }
        let queue = playlist.orderedTracks
        guard let index = queue.firstIndex(where: { $0.id == seed.id }) else { return }
        player.prepare(tracks: queue, startAt: index)
    }
}
