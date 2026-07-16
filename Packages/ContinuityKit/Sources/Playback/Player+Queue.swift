import Foundation
import SwiftUI
import Domain

extension Player {
    // MARK: Queue editing

    /// Tracks after the current one, in play order.
    public var upcomingTracks: [Track] {
        guard queue.indices.contains(currentIndex), currentIndex + 1 < queue.count else { return [] }
        return Array(queue[(currentIndex + 1)...])
    }

    /// Inserts (or moves, if already upcoming) the track to play immediately after the current one.
    public func playNext(_ track: Track) {
        // No current track → nothing to play "next" after; the current track itself is a no-op.
        guard let current = currentTrack, track.id != current.id else { return }
        beginQueueEdit()
        // Move rather than duplicate if the track is already queued — two entries with one ID
        // would confuse every firstIndex(of:) lookup (history, deletion, blend retargeting).
        if let existing = queue.firstIndex(where: { $0.id == track.id }) {
            queue.remove(at: existing)
            if existing < currentIndex { currentIndex -= 1 }
        }
        queue.insert(track, at: min(currentIndex + 1, queue.count))
        endQueueEdit()
    }

    /// Reorders the upcoming tracks (SwiftUI List.onMove offsets, relative to upcomingTracks).
    public func moveUpcoming(fromOffsets: IndexSet, toOffset: Int) {
        guard !upcomingTracks.isEmpty else { return }
        beginQueueEdit()
        // Edit the upcoming slice in isolation so List offsets apply verbatim, then splice it
        // back — current and history positions can't shift by construction.
        var upcoming = upcomingTracks
        upcoming.move(fromOffsets: fromOffsets, toOffset: toOffset)
        queue.replaceSubrange((currentIndex + 1)..., with: upcoming)
        endQueueEdit()
    }

    /// Removes upcoming tracks (SwiftUI List.onDelete offsets, relative to upcomingTracks).
    public func removeUpcoming(atOffsets: IndexSet) {
        guard !upcomingTracks.isEmpty else { return }
        beginQueueEdit()
        var upcoming = upcomingTracks
        // Drop out-of-range offsets rather than trap — the UI's rows can lag the queue by a frame.
        upcoming.remove(atOffsets: atOffsets.filteredIndexSet { upcoming.indices.contains($0) })
        queue.replaceSubrange((currentIndex + 1)..., with: upcoming)
        endQueueEdit()
    }

    /// Replaces everything after the current track with the given order (used by Flow mode).
    /// Tracks not currently in the queue are appended-in-order; the current track never moves.
    public func replaceUpcoming(with tracks: [Track]) {
        guard let current = currentTrack else { return }
        beginQueueEdit()
        // The current track never appears twice; dedupe the rest so one ID can't occupy two slots.
        var seen: Set<UUID> = [current.id]
        let upcoming = tracks.filter { seen.insert($0.id).inserted }
        // Pull requested tracks out of the played prefix too (move, don't duplicate) — every
        // firstIndex(of:) lookup (history walks, deletion, blend retargeting) assumes unique IDs.
        let upcomingIDs = Set(upcoming.map(\.id))
        let prefix = queue[..<currentIndex].filter { !upcomingIDs.contains($0.id) }
        queue = prefix + [current] + upcoming
        currentIndex = prefix.count
        endQueueEdit()
    }

    /// A queue edit can invalidate the blend target's index, so kill any in-flight blend before
    /// touching the array; tick() re-evaluates the transition window from the new neighborhood.
    private func beginQueueEdit() {
        if isTransitioning { cancelTransition() }
    }

    /// Save the reshaped session and re-prep stems for the new neighborhood.
    private func endQueueEdit() {
        persistState()
        notifyUpcoming()
    }
}
