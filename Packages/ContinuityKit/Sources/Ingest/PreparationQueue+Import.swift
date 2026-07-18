import AVFoundation
import Domain
import Foundation
import SwiftData
import ContinuityCore
import os

extension PreparationQueue {
    /// Resolves a YouTube playlist, creates a matching library `Playlist` with one placeholder
    /// `Track` per video, and enqueues every track for ingestion. The page fetch runs off the
    /// main actor inside the awaited resolver; the model writes happen here on the main actor.
    ///
    /// Throws if the playlist can't be resolved (private/empty/unavailable or a YouTube change),
    /// so the caller can surface an inline error. Returns the created playlist on success.
    @discardableResult
    public func importPlaylist(playlistID: String, fallbackTitle: String? = nil, in context: ModelContext) async throws -> Playlist {
        guard RemoteAudioIngest.isEnabled else { throw IngestError.sourceUnavailable }
        let resolved = try await playlistResolver.resolvePlaylist(playlistID: playlistID)

        let title = resolved.title?.isEmpty == false ? resolved.title! : (fallbackTitle ?? "YouTube Playlist")
        // Deterministic-ish gradient seed from the playlist ID so the card has a stable colour.
        let seed = resolved.playlistID.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 90 + 10

        let playlist = Playlist(
            title: title,
            subtitle: "From YouTube · \(resolved.items.count) tracks",
            artworkSymbol: "music.note.list",
            gradientSeed: seed
        )
        playlist.sourceKind = .youtube
        playlist.sourceID = resolved.playlistID
        playlist.lastSyncedAt = Date()
        context.insert(playlist)

        for (index, item) in resolved.items.enumerated() {
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
        }
        playlist.touch()    // creation + initial tracks count as a content change
        try? context.save()
        return playlist
    }

    /// Imports a Spotify playlist/album: resolves its tracklist (metadata only — Spotify audio is
    /// DRM-protected and unusable by our engine), creates a matching library `Playlist`, and
    /// enqueues one `Track` per song. Each track carries a `searchQuery` instead of a video ID;
    /// the ingest pipeline resolves that to real YouTube audio (see `process`).
    ///
    /// Throws if the playlist can't be resolved so the caller can surface an inline error.
    @discardableResult
    public func importSpotifyPlaylist(_ link: SpotifyLink, in context: ModelContext) async throws -> Playlist {
        guard RemoteAudioIngest.isEnabled else { throw IngestError.sourceUnavailable }
        let resolved = try await spotifyResolver.resolvePlaylist(link)

        let title = resolved.name?.isEmpty == false ? resolved.name! : "Spotify \(link.kind.rawValue.capitalized)"
        let seed = link.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 90 + 10

        let playlist = Playlist(
            title: title,
            subtitle: "From Spotify · \(resolved.tracks.count) tracks",
            artworkSymbol: "music.note.list",
            gradientSeed: seed
        )
        playlist.sourceKind = link.kind == .album ? .spotifyAlbum : .spotifyPlaylist
        playlist.sourceID = link.id
        playlist.lastSyncedAt = Date()
        context.insert(playlist)

        for (index, spotifyTrack) in resolved.tracks.enumerated() {
            let track = Track(
                title: spotifyTrack.title,
                artist: spotifyTrack.artist ?? "Unknown Artist",
                durationSeconds: Double(spotifyTrack.durationSeconds ?? 0),
                artworkSymbol: playlist.artworkSymbol,
                gradientSeed: seed * 100 + index,
                sortIndex: index,
                prepState: .pending,
                // No video ID yet — the pipeline finds the audio on YouTube from this query.
                searchQuery: spotifyTrack.youtubeSearchQuery
            )
            playlist.tracks.append(track)
            context.insert(track)
            enqueue(track, in: context)
        }
        playlist.touch()    // creation + initial tracks count as a content change
        try? context.save()
        return playlist
    }
}
