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
            .task {
                prepQueue.onTracksDeleted = { [weak player] ids in
                    player?.handleDeleted(trackIDs: ids)
                }
                // Stems are prepared just-in-time for the play-queue neighborhood, not eagerly
                // for the whole library (CPU-hours + gigabytes). `notifyUpcoming` stays inert
                // until the first real play so restore/queue edits cannot open ORT at launch.
                player.onUpcomingTracks = { [weak prepQueue] tracks in
                    prepQueue?.ensureStems(for: tracks, in: modelContext)
                }
                player.transitionVoteHistory = { fromID, toID in
                    let descriptor = FetchDescriptor<TransitionVote>(
                        predicate: #Predicate { $0.fromTrackID == fromID && $0.toTrackID == toID },
                        sortBy: [SortDescriptor(\.createdAt)]
                    )
                    return ((try? modelContext.fetch(descriptor)) ?? []).map(\.isUpvote)
                }
                player.onQueueExhausted = { ids in
                    var descriptor = FetchDescriptor<Track>()
                    descriptor.propertiesToFetch = [\.id]
                    let tracks = (try? modelContext.fetch(descriptor)) ?? []
                    let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    return ids.compactMap { byID[$0] }
                }
                LibraryCleanup.sweepOrphanedFiles(in: modelContext)
                restorePlaybackSession()
                await Task.yield()
                await prepQueue.resumePreparation(in: modelContext)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                prepQueue.handleMemoryPressure()
            }
    }

    /// Restores the persisted session — same song, position, skip budget, and history — or, on a
    /// fresh install, stages COMË N GO paused at the start of its playlist.
    private func restorePlaybackSession() {
        guard player.currentTrack == nil else { return }

        if let state = PlaybackStateStore.load() {
            var descriptor = FetchDescriptor<Track>()
            descriptor.propertiesToFetch = [\.id]
            let stored = (try? modelContext.fetch(descriptor)) ?? []
            let byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            player.restore(state, resolving: byID)
            if player.currentTrack != nil { return }
        }

        let tracks = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
        let candidates = tracks.filter { $0.title.localizedCaseInsensitiveContains("COMË N GO") }
        guard let seed = candidates.first(where: { !$0.isDemo }) ?? candidates.first,
              let playlist = seed.playlist else { return }
        let queue = playlist.orderedTracks
        guard let index = queue.firstIndex(where: { $0.id == seed.id }) else { return }
        player.prepare(tracks: queue, startAt: index)
    }
}
