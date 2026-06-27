import Foundation

/// Downloads a resolved audio stream to the on-disk cache.
///
/// The download stage of the M1 ingestion pipeline (resolve → download → ready).
/// Stateless and therefore safely `Sendable`; each call is independent and
/// returns the local file URL of the cached audio.
final class AudioDownloader: AudioFileDownloading {
    init() {}

    /// Downloads `resolved` to `AudioCache`, returning the local file URL.
    ///
    /// Returns immediately on a cache hit. Otherwise downloads via `URLSession`,
    /// validates the HTTP status, and atomically moves the result into place.
    /// - Throws: `IngestError.downloadFailed` if the transfer, HTTP response,
    ///   or file move fails.
    func downloadAudio(_ resolved: ResolvedAudio) async throws -> URL {
        let destination = AudioCache.fileURL(videoID: resolved.videoID, container: resolved.container)

        // Cache hit: the file is already on disk.
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        // Download to a temporary location.
        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await URLSession.shared.download(from: resolved.url)
        } catch {
            throw IngestError.downloadFailed(String(describing: error))
        }
        // The async `download(from:)` hands back a caller-owned temp file that is NOT
        // auto-deleted. Guarantee it never leaks, on success or any error path below.
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Validate the HTTP status when applicable.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw IngestError.downloadFailed("HTTP \(http.statusCode)")
        }

        // Publish into the cache. Move (rename) is atomic on the same volume. If a concurrent
        // download for the same video already won the race and the file now exists, treat that
        // as success rather than racing a remove-then-move that could corrupt the cached file.
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                return destination
            }
            throw IngestError.downloadFailed(String(describing: error))
        }

        return destination
    }
}
