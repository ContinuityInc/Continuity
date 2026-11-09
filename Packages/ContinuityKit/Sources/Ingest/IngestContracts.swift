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
    /// The user hasn't granted (or has revoked) access to their Apple Music library.
    case appleMusicAccessDenied
    /// The operation needs a connected account for this service and there is none (or its
    /// tokens were rejected and it was disconnected).
    case notSignedIn(MusicService)
    /// Sign-in can't start: no OAuth client id is configured for this service in the build.
    case notConfigured(MusicService)
    /// The user cancelled sign-in, or the provider refused it.
    case authorizationFailed(String)
    /// The API rejected our bearer token (401) — refresh and retry once, then disconnect.
    case unauthorized

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
    /// One song's metadata from its embed page (`link.kind == .track`).
    func resolveTrack(_ link: SpotifyLink) async throws -> SpotifyTrack
}

/// What a service link resolved to: a whole collection or one song.
enum ResolvedServiceLink: Sendable, Equatable {
    case playlist(ServicePlaylistContents)
    case track(ServiceTrack)
}

/// Resolves a SoundCloud link **anonymously** (page scrape + api-v2 stub fetch).
/// Implemented by `SoundCloudPlaylistResolver`.
protocol SoundCloudResolving: Sendable {
    func resolve(_ link: SoundCloudLink) async throws -> ResolvedServiceLink
}

/// Reads the signed-in user's library on one service through its official API. The caller
/// supplies a valid bearer token (see `ServiceAuthManager.accessToken(for:)`).
/// Implemented by `SpotifyAPIClient`, `YouTubeDataAPIClient`, `SoundCloudAPIClient`.
protocol ConnectedLibraryReading: Sendable {
    var service: MusicService { get }
    /// The account's playlists (and its Liked collection, first), for the import picker.
    func playlists(token: String) async throws -> [ServicePlaylistSummary]
    /// Full tracklist of one listed collection (follows pagination).
    func contents(of summary: ServicePlaylistSummary, token: String) async throws -> ServicePlaylistContents
    /// Resolves a pasted link that belongs to this service — full-length and private items the
    /// anonymous scrape can't see. Nil when the link isn't one this service owns.
    func resolveLink(_ raw: String, token: String) async throws -> ResolvedServiceLink?
}

/// Whether the user has let us read their Apple Music / iTunes library.
public enum AppleMusicAccess: Sendable {
    case notDetermined
    case authorized
    /// Declined, or blocked by Screen Time / MDM restrictions — Settings is the only way back.
    case denied
}

/// Reads playlists out of the user's on-device Apple Music library (metadata only).
/// Implemented by `AppleMusicLibraryReader`.
protocol AppleMusicLibraryReading: Sendable {
    var access: AppleMusicAccess { get }
    /// Prompts on first call; returns the settled status afterwards without re-prompting.
    func requestAccess() async -> AppleMusicAccess
    /// Every non-empty playlist in the library, in the order Music shows them.
    func playlists() async throws -> [AppleMusicPlaylistContents]
    /// One playlist by persistent ID, or nil if it's been deleted from the library.
    func playlist(persistentID: String) async throws -> AppleMusicPlaylistContents?
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

/// One track currently in the ingest pipeline. Surfaced by `PreparationQueue.ingestJobs` so
/// the Downloads screen can show queued vs in-flight work without walking every SwiftData row.
public struct IngestJob: Identifiable, Equatable, Sendable {
    public enum Phase: String, Sendable {
        case queued, downloading, analyzing
    }

    public let id: UUID
    public var title: String
    public var artist: String
    public var phase: Phase
    /// 0...1 while `phase == .downloading` and the server reported a size; nil otherwise.
    public var fraction: Double?
    public var isPrioritized: Bool

    public init(
        id: UUID,
        title: String,
        artist: String,
        phase: Phase,
        fraction: Double?,
        isPrioritized: Bool
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.phase = phase
        self.fraction = fraction
        self.isPrioritized = isPrioritized
    }
}

/// Downloads a resolved stream to local storage and returns the on-disk file URL.
/// Implemented by `AudioDownloader`.
protocol AudioFileDownloading: Sendable {
    /// `progress` reports `(bytesWritten, totalBytes?)` as ranged chunks land. `totalBytes` is
    /// nil until the first `Content-Range` (or a whole-file 200) arrives.
    func downloadAudio(
        _ resolved: ResolvedAudio,
        progress: (@Sendable (Int, Int?) -> Void)?
    ) async throws -> URL
}

extension AudioFileDownloading {
    func downloadAudio(_ resolved: ResolvedAudio) async throws -> URL {
        try await downloadAudio(resolved, progress: nil)
    }
}
