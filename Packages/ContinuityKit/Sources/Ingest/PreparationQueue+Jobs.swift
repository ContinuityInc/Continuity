import Domain
import Foundation
import SwiftData

extension PreparationQueue {
    static let songPriority = 100
    static let playlistPriority = 50

    /// Drop Downloads rows, priority, and ingest waiters for tracks the UI or sync just deleted.
    /// Call *before* destroying the `@Model`s so a mid-backoff retry doesn't leave a ghost.
    public func handleTracksDeleted(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            ingestAttempts[id] = nil
            ingestPriority[id] = nil
            retryScheduledTrackIDs.remove(id)
            removeJob(id)
        }
        Task { await ingestLimiter.cancel(ids: ids) }
    }

    /// Jump `track` to the head of the ingest queue. Failed rows are re-enqueued.
    /// Already-ready tracks are a no-op — there's nothing to download.
    public func prioritize(_ track: Track, in context: ModelContext) {
        guard !track.isDemo, track.prepState != .ready else { return }
        ingestPriority[track.id] = max(ingestPriority[track.id] ?? 0, Self.songPriority)
        if let idx = ingestJobs.firstIndex(where: { $0.id == track.id }) {
            ingestJobs[idx].isPrioritized = true
            sortJobs()
        }
        let id = track.id
        Task { await ingestLimiter.bump(ids: [id], to: Self.songPriority) }
        if track.prepState == .failed {
            enqueue(track, in: context)
        }
    }

    /// Jump every not-yet-ready track in a playlist/album ahead of the rest of the library.
    public func prioritize(playlist: Playlist, in context: ModelContext) {
        let tracks = playlist.tracks.filter { !$0.isDemo && $0.prepState != .ready }
        guard !tracks.isEmpty else { return }
        let ids = Set(tracks.map(\.id))
        for track in tracks {
            ingestPriority[track.id] = max(ingestPriority[track.id] ?? 0, Self.playlistPriority)
        }
        for i in ingestJobs.indices where ids.contains(ingestJobs[i].id) {
            ingestJobs[i].isPrioritized = true
        }
        sortJobs()
        Task { await ingestLimiter.bump(ids: ids, to: Self.playlistPriority) }
        var enqueued = false
        for track in tracks where track.prepState == .failed {
            enqueue(track, in: context, saving: false)
            enqueued = true
        }
        if enqueued { try? context.save() }
    }

    func upsertJob(_ track: Track, phase: IngestJob.Phase) {
        let prioritized = (ingestPriority[track.id] ?? 0) > 0
        if let idx = ingestJobs.firstIndex(where: { $0.id == track.id }) {
            ingestJobs[idx].title = track.title
            ingestJobs[idx].artist = track.artist
            ingestJobs[idx].phase = phase
            ingestJobs[idx].isPrioritized = prioritized
            if phase != .downloading { ingestJobs[idx].fraction = nil }
        } else {
            ingestJobs.append(IngestJob(
                id: track.id,
                title: track.title,
                artist: track.artist,
                phase: phase,
                fraction: nil,
                isPrioritized: prioritized
            ))
        }
        if jobSortSuspended == 0 { sortJobs() }
    }

    func updateJobProgress(_ id: UUID, bytes: Int, total: Int?) {
        guard let idx = ingestJobs.firstIndex(where: { $0.id == id }) else { return }
        ingestJobs[idx].phase = .downloading
        guard let total, total > 0 else { return }
        let fraction = min(1, Double(bytes) / Double(total))
        // Skip sub-percent redraws — ranged chunks are 1 MiB, so this still updates often.
        if let current = ingestJobs[idx].fraction, abs(current - fraction) < 0.01 { return }
        ingestJobs[idx].fraction = fraction
    }

    func removeJob(_ id: UUID) {
        ingestJobs.removeAll { $0.id == id }
    }

    /// Active downloads first, then analysis, then the waiting queue. Prioritized rows float up
    /// within a phase so "Download first" is visible at the top of each section — never above an
    /// in-flight download we can't preempt.
    func sortJobs() {
        ingestJobs.sort { a, b in
            let pa = Self.phaseOrder(a.phase)
            let pb = Self.phaseOrder(b.phase)
            if pa != pb { return pa < pb }
            if a.isPrioritized != b.isPrioritized { return a.isPrioritized && !b.isPrioritized }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    private static func phaseOrder(_ phase: IngestJob.Phase) -> Int {
        switch phase {
        case .downloading: return 0
        case .analyzing: return 1
        case .queued: return 2
        }
    }
}
