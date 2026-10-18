import Domain
import Foundation
import SwiftData
import ContinuityCore
import os

extension PreparationQueue {
    /// Imports a YouTube playlist as a library `Playlist` with one `Track` per video and
    /// enqueues every track for ingestion. A connected YouTube account reads it through the Data
    /// API (private playlists and Liked videos included); otherwise the public page is scraped.
    ///
    /// Throws if the playlist can't be resolved (private/empty/unavailable or a YouTube change),
    /// so the caller can surface an inline error. Returns the created playlist on success.
    @discardableResult
    public func importPlaylist(playlistID: String, fallbackTitle: String? = nil, in context: ModelContext) async throws -> Playlist {
        let contents = try await fetchRemoteContents(kind: .youtube, sourceID: playlistID, fallbackName: fallbackTitle)
        guard !contents.isEmpty else { throw IngestError.sourceUnavailable }
        return await importServicePlaylist(contents, in: context)
    }

    /// Imports a Spotify playlist/album: resolves its tracklist (metadata only — Spotify audio is
    /// DRM-protected and unusable by our engine), creates a matching library `Playlist`, and
    /// enqueues one `Track` per song. Each track carries a `searchQuery` instead of a video ID;
    /// the ingest pipeline resolves that to real YouTube audio (see `process`).
    ///
    /// A connected Spotify account reads the full tracklist through the Web API (the embed page
    /// stops at ~50 tracks and can't see private playlists). Throws if the playlist can't be
    /// resolved so the caller can surface an inline error.
    @discardableResult
    public func importSpotifyPlaylist(_ link: SpotifyLink, in context: ModelContext) async throws -> Playlist {
        guard link.isCollection else { throw IngestError.invalidURL }
        let contents = try await fetchRemoteContents(kind: link.kind == .album ? .spotifyAlbum : .spotifyPlaylist, sourceID: link.id)
        guard !contents.isEmpty else { throw IngestError.sourceUnavailable }
        return await importServicePlaylist(contents, in: context)
    }
}
