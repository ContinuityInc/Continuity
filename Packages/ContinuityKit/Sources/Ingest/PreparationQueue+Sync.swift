import AVFoundation
import Domain
import Foundation
import SwiftData
import ContinuityCore
import os

extension PreparationQueue {
    /// Polling pass (launch + foreground minute tick): refreshes each source-backed playlist
    /// that has auto-sync on (the opt-out) and hasn't synced recently. `lastSyncedAt` staleness
    /// is the rate limiter — a tick right after a sync is a no-op per playlist.
    public func autoSyncIfNeeded(in context: ModelContext) {
        guard let playlists = try? context.fetch(FetchDescriptor<Playlist>()) else { return }
        for playlist in playlists where playlist.isSourceBacked && playlist.autoSyncEnabled {
            // Failing sources sit out their backoff — staleness alone would retry every tick,
            // since only success advances `lastSyncedAt`.
            if let notBefore = syncBackoff[playlist.id]?.notBefore, Date() < notBefore { continue }
            let stale = playlist.lastSyncedAt.map {
                Date().timeIntervalSince($0) > Self.autoSyncStaleness
            } ?? true
            if stale {
                Task { await syncPlaylist(playlist, in: context) }
            }
        }
    }

    /// Manual "sync everything now" — ignores staleness but still skips in-flight playlists.
    public func syncAll(in context: ModelContext) {
        guard let playlists = try? context.fetch(FetchDescriptor<Playlist>()) else { return }
        for playlist in playlists where playlist.isSourceBacked {
            Task { await syncPlaylist(playlist, in: context) }
        }
    }

    /// Mirrors one playlist against its remote source: tracks added remotely are created (and
    /// ingested), tracks removed remotely are deleted locally (Player-coordinated, files cleaned
    /// share-aware), and local ordering follows the remote. Best-effort: a resolve failure leaves
    /// the local playlist untouched.
    public func syncPlaylist(_ playlist: Playlist, in context: ModelContext) async {
        guard playlist.isSourceBacked, let sourceID = playlist.sourceID, let kind = playlist.sourceKind,
              !syncingPlaylistIDs.contains(playlist.id) else { return }
        syncingPlaylistIDs.insert(playlist.id)
        defer { syncingPlaylistIDs.remove(playlist.id) }

        do {
            let changed: Bool
            switch kind {
            case .youtube:
                let resolved = try await playlistResolver.resolvePlaylist(playlistID: sourceID)
                guard playlist.modelContext != nil, !resolved.items.isEmpty else { return }
                changed = applyYouTubeSync(resolved.items, to: playlist, in: context)
            case .spotifyPlaylist, .spotifyAlbum:
                let link = SpotifyLink(kind: kind == .spotifyAlbum ? .album : .playlist, id: sourceID)
                let resolved = try await spotifyResolver.resolvePlaylist(link)
                guard playlist.modelContext != nil, !resolved.tracks.isEmpty else { return }
                changed = applyMetadataSync(
                    resolved.tracks,
                    subtitle: "From Spotify · \(resolved.tracks.count) tracks",
                    to: playlist,
                    in: context
                )
            case .appleMusic:
                // Reads the on-device library, so this succeeds offline — but a playlist the
                // user deleted in Music resolves to nil, and we leave the local copy alone
                // rather than wiping an import they may still want.
                guard let contents = try await appleMusicLibrary.playlist(persistentID: sourceID) else { return }
                guard playlist.modelContext != nil, !contents.isEmpty else { return }
                changed = applyMetadataSync(
                    contents.tracks,
                    subtitle: Self.appleMusicSubtitle(count: contents.tracks.count),
                    to: playlist,
                    in: context
                )
            }
            playlist.lastSyncedAt = Date()
            syncBackoff[playlist.id] = nil
            try? context.save()
            Logger.sync.info("synced \(playlist.title, privacy: .public)")
            // Real content change only — a steady-state sync must not churn the live queue.
            if changed { onPlaylistSynced?(playlist.id, playlist.orderedTracks) }
        } catch {
            // The local playlist is never modified on a failed fetch; auto-sync retries after
            // an exponential backoff (2 min doubling to a 30 min cap) — each attempt already
            // costs up to 3 requests via Retry, and hammering a rate limit only extends it.
            let failures = (syncBackoff[playlist.id]?.failures ?? 0) + 1
            let delay = min(120 * pow(2, Double(failures - 1)), 1_800)
            syncBackoff[playlist.id] = (Date().addingTimeInterval(delay), failures)
            Logger.sync.error("sync failed for \(playlist.title, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Applies a fresh remote YouTube tracklist: key = video ID. Returns whether membership
    /// or order actually changed (drives `touch()` and `onPlaylistSynced`).
    private func applyYouTubeSync(_ remote: [YouTubePlaylistItem], to playlist: Playlist, in context: ModelContext) -> Bool {
        var localByKey: [String: Track] = [:]
        for track in playlist.tracks {
            if let id = track.youtubeVideoID { localByKey[id] = track }
        }

        let remoteKeys = Set(remote.map(\.videoID))
        let removed = playlist.tracks.filter { track in
            guard let id = track.youtubeVideoID else { return false }
            return !remoteKeys.contains(id)
        }
        removeTracks(removed, in: context)

        // Bump `updatedAt` only when the sync actually changed content — a no-op auto-sync
        // must not float untouched playlists to the top of the library.
        var changed = !removed.isEmpty
        // Duplicate remote entries share one local track; settle on the last occurrence's index
        // up front so an unchanged remote reaches a steady state instead of touching every sync.
        var targetIndexByKey: [String: Int] = [:]
        for (index, item) in remote.enumerated() { targetIndexByKey[item.videoID] = index }
        let seed = playlist.gradientSeed
        for (index, item) in remote.enumerated() {
            if let existing = localByKey[item.videoID] {
                let target = targetIndexByKey[item.videoID] ?? index
                if existing.sortIndex != target {
                    existing.sortIndex = target  // follow remote ordering
                    changed = true
                }
            } else {
                let track = Track(
                    title: item.title ?? "YouTube Video (\(item.videoID.prefix(6)))",
                    artist: item.author ?? "YouTube",
                    durationSeconds: Double(item.lengthSeconds ?? 0),
                    artworkSymbol: playlist.artworkSymbol,
                    gradientSeed: seed * 100 + index,
                    sortIndex: index,
                    prepState: .pending,
                    youtubeVideoID: item.videoID,
                    sourceURLString: "https://www.youtube.com/watch?v=\(item.videoID)"
                )
                playlist.tracks.append(track)
                context.insert(track)
                enqueue(track, in: context)
                changed = true
            }
        }
        playlist.subtitle = "From YouTube · \(remote.count) tracks"
        if changed { playlist.touch() }
        return changed
    }

    /// Applies a fresh metadata-only tracklist (Spotify or Apple Music): key = the YouTube search
    /// query (title + artist), the identity such tracks carry locally since they have no video ID.
    /// Returns whether membership or order actually changed (drives `touch()` and
    /// `onPlaylistSynced`).
    private func applyMetadataSync(
        _ remote: [any MetadataSourcedTrack],
        subtitle: String,
        to playlist: Playlist,
        in context: ModelContext
    ) -> Bool {
        var localByKey: [String: Track] = [:]
        for track in playlist.tracks {
            if let query = track.searchQuery { localByKey[query] = track }
        }

        let remoteKeys = Set(remote.map { $0.youtubeSearchQuery })
        let removed = playlist.tracks.filter { track in
            guard let query = track.searchQuery else { return false }
            return !remoteKeys.contains(query)
        }
        removeTracks(removed, in: context)

        // Same rule as the YouTube path: only a real content change bumps `updatedAt`.
        var changed = !removed.isEmpty
        // As above: duplicate keys settle on one index so unchanged remotes stop touching.
        var targetIndexByKey: [String: Int] = [:]
        for (index, item) in remote.enumerated() { targetIndexByKey[item.youtubeSearchQuery] = index }
        let seed = playlist.gradientSeed
        for (index, item) in remote.enumerated() {
            if let existing = localByKey[item.youtubeSearchQuery] {
                let target = targetIndexByKey[item.youtubeSearchQuery] ?? index
                if existing.sortIndex != target {
                    existing.sortIndex = target
                    changed = true
                }
            } else {
                let track = Track(
                    title: item.title,
                    artist: item.artist ?? "Unknown Artist",
                    durationSeconds: Double(item.durationSeconds ?? 0),
                    artworkSymbol: playlist.artworkSymbol,
                    gradientSeed: seed * 100 + index,
                    sortIndex: index,
                    prepState: .pending,
                    searchQuery: item.youtubeSearchQuery
                )
                playlist.tracks.append(track)
                context.insert(track)
                enqueue(track, in: context)
                changed = true
            }
        }
        playlist.subtitle = subtitle
        if changed { playlist.touch() }
        return changed
    }

    /// Deletes tracks the same way the UI does: Player first (so the live queue never holds a
    /// dead model), then the models, then share-aware file cleanup.
    private func removeTracks(_ tracks: [Track], in context: ModelContext) {
        guard !tracks.isEmpty else { return }
        onTracksDeleted?(Set(tracks.map(\.id)))
        let keys = tracks.map(\.stemKey)
        for track in tracks { context.delete(track) }
        LibraryCleanup.removeOrphanedFiles(keys: keys, in: context)
    }
}
