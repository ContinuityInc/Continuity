import Foundation
import ContinuityCore

/// Shared contracts for the M1 ingestion pipeline (resolve → download → ready).
/// Concrete types implement these so each stage stays swappable and independently testable.

/// A resolved, directly-downloadable audio stream for one YouTube video.
struct ResolvedAudio: Sendable, Equatable {
    let videoID: String
    let url: URL
    let itag: Int
    /// Container/extension, e.g. "m4a".
    let container: String
    /// True if `AVAudioFile` can decode it without transcoding (AAC/m4a).
    let isNativelyPlayable: Bool
    /// Best-effort average bitrate in bits/sec.
    let approxBitrate: Int
}

public enum IngestError: Error, Sendable {
    case invalidURL
    case noVideoID
    case noPlayableStream
    case resolveFailed(String)
    case downloadFailed(String)
    case decodeFailed(String)
    /// Connectivity/timeout/5xx talking to the source — a retry may succeed.
    case network(String)
    /// HTTP 429 from the source — a retry after a short delay may succeed.
    case rateLimited
    /// The `googlevideo` URL was rejected (403/410): its signature expired, or the source
    /// invalidated it mid-download. Retrying the same URL can never work — the video must be
    /// re-resolved for a fresh one.
    case streamURLExpired
    /// The source was reached and understood, but has no usable content
    /// (private, empty, region-locked, or deleted). Retrying won't help.
    case sourceUnavailable

    /// Whether retrying the same request with backoff could plausibly succeed. Distinguishes a
    /// transient blip (worth retrying, and not the user's fault) from a definitively empty source.
    ///
    /// `.streamURLExpired` is deliberately excluded: it needs a *different* URL, not another
    /// attempt at this one. `process` handles it by re-resolving.
    var isRetryable: Bool {
        switch self {
        case .network, .rateLimited: return true
        default: return false
        }
    }

    /// Whether a fresh resolve could plausibly fix this — i.e. the failure is about the URL we
    /// used, not about the video or the connection.
    var needsFreshStreamURL: Bool {
        if case .streamURLExpired = self { return true }
        return false
    }
}

/// A resolved YouTube playlist: its videos (in order) plus the playlist's own title.
struct ResolvedPlaylist: Sendable, Equatable {
    let playlistID: String
    let title: String?
    let items: [YouTubePlaylistItem]
}

/// A resolved Spotify playlist/album: its tracks (metadata only — audio comes from YouTube).
struct ResolvedSpotifyPlaylist: Sendable, Equatable {
    let link: SpotifyLink
    let name: String?
    let tracks: [SpotifyTrack]
}

/// Resolves a YouTube video ID to a downloadable audio stream.
/// Implemented by `YouTubeStreamResolver`.
protocol AudioStreamResolving: Sendable {
    func resolveAudio(videoID: String) async throws -> ResolvedAudio
}

/// Resolves a YouTube playlist ID to its constituent videos.
/// Implemented by `YouTubePlaylistResolver`.
protocol PlaylistResolving: Sendable {
    func resolvePlaylist(playlistID: String) async throws -> ResolvedPlaylist
}

/// Resolves a Spotify playlist/album to its tracklist (metadata only).
/// Implemented by `SpotifyPlaylistResolver`.
protocol SpotifyPlaylistResolving: Sendable {
    func resolvePlaylist(_ link: SpotifyLink) async throws -> ResolvedSpotifyPlaylist
}

/// Finds the best-matching YouTube video ID for a text query.
/// Implemented by `YouTubeSearchResolver`.
protocol YouTubeSearching: Sendable {
    func firstVideoID(query: String) async throws -> String?
}

/// Real display metadata for one YouTube video (title + channel/author).
struct VideoMetadata: Sendable, Equatable {
    let title: String
    let author: String?
}

/// Resolves a video ID to its display metadata.
/// Implemented by `YouTubeOEmbedResolver`.
protocol VideoMetadataResolving: Sendable {
    func metadata(videoID: String) async throws -> VideoMetadata
}

/// Downloads a resolved stream to local storage and returns the on-disk file URL.
/// Implemented by `AudioDownloader`.
protocol AudioFileDownloading: Sendable {
    func downloadAudio(_ resolved: ResolvedAudio) async throws -> URL
}
