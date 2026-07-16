import AVFoundation
import Domain
import Foundation
import SwiftData
import ContinuityCore
import os

extension PreparationQueue {
    /// Launch-time polling pass: refreshes each source-backed playlist that has auto-sync on
    /// (the opt-out) and hasn't synced recently.
    public func autoSyncIfNeeded(in context: ModelContext) {
        guard let playlists = try? context.fetch(FetchDescriptor<Playlist>()) else { return }
        for playlist in playlists where playlist.isSourceBacked && playlist.autoSyncEnabled {
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
            switch kind {
            case .youtube:
                let resolved = try await playlistResolver.resolvePlaylist(playlistID: sourceID)
                guard playlist.modelContext != nil, !resolved.items.isEmpty else { return }
                applyYouTubeSync(resolved.items, to: playlist, in: context)
            case .spotifyPlaylist, .spotifyAlbum:
                let link = SpotifyLink(kind: kind == .spotifyAlbum ? .album : .playlist, id: sourceID)
                let resolved = try await spotifyResolver.resolvePlaylist(link)
                guard playlist.modelContext != nil, !resolved.tracks.isEmpty else { return }
                applySpotifySync(resolved.tracks, to: playlist, in: context)
            }
            playlist.lastSyncedAt = Date()
            try? context.save()
            Logger.sync.info("synced \(playlist.title, privacy: .public)")
        } catch {
            // The local playlist is never modified on a failed fetch; next sync retries.
            Logger.sync.error("sync failed for \(playlist.title, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Applies a fresh remote YouTube tracklist: key = video ID.
    private func applyYouTubeSync(_ remote: [YouTubePlaylistItem], to playlist: Playlist, in context: ModelContext) {
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
    }

    /// Applies a fresh remote Spotify tracklist: key = the YouTube search query (title + artist),
    /// the identity Spotify-sourced tracks carry locally.
    private func applySpotifySync(_ remote: [SpotifyTrack], to playlist: Playlist, in context: ModelContext) {
        var localByKey: [String: Track] = [:]
        for track in playlist.tracks {
            if let query = track.searchQuery { localByKey[query] = track }
        }

        let remoteKeys = Set(remote.map(\.youtubeSearchQuery))
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
        playlist.subtitle = "From Spotify · \(remote.count) tracks"
        if changed { playlist.touch() }
    }

    /// Deletes tracks the same way the UI does: Player first (so the live queue never holds a
    /// dead model), then the models, then share-aware file cleanup.
    private func removeTracks(_ tracks: [Track], in context: ModelContext) {
        guard !tracks.isEmpty else { return }
        onTracksDeleted?(Set(tracks.map(\.id)))
        let videoIDs = tracks.compactMap(\.youtubeVideoID)
        for track in tracks { context.delete(track) }
        LibraryCleanup.removeOrphanedFiles(videoIDs: videoIDs, in: context)
    }
}
