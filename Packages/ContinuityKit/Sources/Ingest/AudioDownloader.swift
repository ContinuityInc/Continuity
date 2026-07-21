import Foundation
import Domain
import ContinuityCore

/// Downloads a resolved audio stream to the on-disk cache.
///
/// The download stage of the M1 ingestion pipeline (resolve → download → ready).
///
/// **Why ranged?** YouTube throttles a single full-file `GET` of a `googlevideo` URL down to a
/// crawl (and frequently drops the connection), but serves small HTTP `Range` requests at full
/// speed — the same trick browsers use. So we pull the file in sequential byte-range chunks and
/// reassemble it, then atomically publish into the cache. Stateless and safely `Sendable`.
final class AudioDownloader: AudioFileDownloading {
    /// Size of each range request. ~1 MiB keeps each request well under the throttling threshold.
    private let chunkSize: Int
    /// Per-chunk retry budget for transient network blips.
    private let maxRetriesPerChunk: Int

    init(chunkSize: Int = 1_048_576, maxRetriesPerChunk: Int = 3) {
        self.chunkSize = chunkSize
        self.maxRetriesPerChunk = maxRetriesPerChunk
    }

    func downloadAudio(_ resolved: ResolvedAudio) async throws -> URL {
        let destination = AudioCache.fileURL(videoID: resolved.videoID, container: resolved.container)

        // Cache hit: already on disk.
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        // Assemble into a unique temp file, guaranteed cleaned up on every exit path.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-\(resolved.videoID)-\(UUID().uuidString).\(resolved.container)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await downloadRanged(from: resolved.url, to: tempURL)

        // Publish. Move (rename) is atomic on the same volume; if a concurrent download already
        // won the race and the file now exists, treat that as success rather than corrupting it.
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

    /// Streams `url` into `fileURL` using sequential `Range` requests until the whole file is fetched.
    private func downloadRanged(from url: URL, to fileURL: URL) async throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        do {
            var offset = 0
            var totalSize: Int?
            repeat {
                let upperBound = offset + chunkSize - 1
                let (data, reportedTotal, isWholeFile) = try await fetchChunk(url: url, from: offset, to: upperBound)
                if let reportedTotal { totalSize = reportedTotal }
                if data.isEmpty { break } // nothing more to read
                if isWholeFile && offset > 0 {
                    // The server ignored Range mid-download and sent the entire file — appending
                    // it would duplicate every byte already written. Restart the file with this
                    // complete body instead.
                    try handle.truncate(atOffset: 0)
                    offset = 0
                }
                try handle.write(contentsOf: data)
                offset += data.count
            } while totalSize == nil || offset < totalSize!

            try handle.close()

            // A truncated or empty body is a transient server-side symptom (throttling, dropped
            // connection), not a permanent property of the video — classify it retryable so the
            // track-level backoff gets another pass rather than failing the row outright.
            if let totalSize, offset < totalSize {
                throw IngestError.network("incomplete download: \(offset)/\(totalSize) bytes")
            }
            if offset == 0 {
                throw IngestError.network("empty download")
            }
        } catch {
            try? handle.close()
            throw error
        }
    }

    /// Fetches one byte range. Returns the chunk, the total file size when the server reports it
    /// (via `Content-Range` on a 206, or the body length on a 200 where the server ignored `Range`),
    /// and whether the body is the WHOLE file (a 200) rather than the requested range — the caller
    /// must not append a whole-file body at a non-zero offset.
    private func fetchChunk(url: URL, from: Int, to: Int) async throws -> (Data, Int?, Bool) {
        var lastError: Error?
        for attempt in 1...max(1, maxRetriesPerChunk) {
            // Share the app-wide cool-down: if the source is throttling other tracks' resolves,
            // pushing chunk requests through anyway just deepens it.
            await IngestThrottle.shared.gate()
            do {
                var request = URLRequest(url: url)
                request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let http = response as? HTTPURLResponse else {
                    await IngestThrottle.shared.noteSuccess()
                    return (data, nil, false)
                }
                switch http.statusCode {
                case 206:
                    // Partial content — the normal ranged path.
                    await IngestThrottle.shared.noteSuccess()
                    let total = Self.totalSize(fromContentRange: http.value(forHTTPHeaderField: "Content-Range"))
                    return (data, total, false)
                case 200:
                    // Server ignored Range and sent the whole file in one shot.
                    await IngestThrottle.shared.noteSuccess()
                    return (data, data.count, true)
                case 416:
                    // Requested range not satisfiable — we've already read past the end.
                    await IngestThrottle.shared.noteSuccess()
                    return (Data(), nil, false)
                case 403, 410:
                    // Signed googlevideo URL went stale (they're short-lived, and a throttled
                    // client gets them invalidated early). Retrying this URL is guaranteed to
                    // fail; bail out immediately so the caller can re-resolve for a fresh one.
                    throw IngestError.streamURLExpired
                case 429:
                    throw IngestError.rateLimited
                default:
                    throw IngestError.network("range fetch HTTP \(http.statusCode)")
                }
            } catch let error as IngestError where error.needsFreshStreamURL {
                throw error     // pointless to retry — needs a different URL
            } catch {
                lastError = error
                let ingestError = error as? IngestError
                await IngestThrottle.shared.noteThrottled(isRateLimit: ingestError?.isRateLimited ?? false)
                guard !IngestBackoff.isFinalAttempt(attempt, maxAttempts: maxRetriesPerChunk) else { break }
                try Task.checkCancellation()
                // Exponential backoff + jitter, matching the resolve path. The old linear
                // 0.2/0.4/0.6s schedule burned its whole budget inside a single throttle window.
                let policy: IngestBackoff.Policy = (ingestError?.isRateLimited ?? false) ? .rateLimited : .request
                let delay = IngestBackoff.delay(afterAttempt: attempt, policy: policy)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        if let ingestError = lastError as? IngestError { throw ingestError }
        throw IngestError.downloadFailed(String(describing: lastError ?? IngestError.downloadFailed("range fetch failed")))
    }

    /// Parses the total length from a `Content-Range: bytes 0-1048575/3449447` header.
    private static func totalSize(fromContentRange header: String?) -> Int? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        let totalString = header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return totalString == "*" ? nil : Int(totalString)
    }
}
