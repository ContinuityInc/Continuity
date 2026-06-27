import Foundation

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

enum IngestError: Error, Sendable {
    case invalidURL
    case noVideoID
    case noPlayableStream
    case resolveFailed(String)
    case downloadFailed(String)
    case decodeFailed(String)
}

/// Resolves a YouTube video ID to a downloadable audio stream.
/// Implemented by `YouTubeStreamResolver`.
protocol AudioStreamResolving: Sendable {
    func resolveAudio(videoID: String) async throws -> ResolvedAudio
}

/// Downloads a resolved stream to local storage and returns the on-disk file URL.
/// Implemented by `AudioDownloader`.
protocol AudioFileDownloading: Sendable {
    func downloadAudio(_ resolved: ResolvedAudio) async throws -> URL
}
