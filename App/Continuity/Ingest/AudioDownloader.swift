import Foundation

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
                let (data, reportedTotal) = try await fetchChunk(url: url, from: offset, to: upperBound)
                if let reportedTotal { totalSize = reportedTotal }
                if data.isEmpty { break } // nothing more to read
                try handle.write(contentsOf: data)
                offset += data.count
            } while totalSize == nil || offset < totalSize!

            try handle.close()

            if let totalSize, offset < totalSize {
                throw IngestError.downloadFailed("incomplete download: \(offset)/\(totalSize) bytes")
            }
            if offset == 0 {
                throw IngestError.downloadFailed("empty download")
            }
        } catch {
            try? handle.close()
            throw error
        }
    }

    /// Fetches one byte range. Returns the chunk plus the total file size when the server reports it
    /// (via `Content-Range` on a 206, or the body length on a 200 where the server ignored `Range`).
    private func fetchChunk(url: URL, from: Int, to: Int) async throws -> (Data, Int?) {
        var lastError: Error?
        for attempt in 0..<maxRetriesPerChunk {
            do {
                var request = URLRequest(url: url)
                request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let http = response as? HTTPURLResponse else {
                    return (data, nil)
                }
                switch http.statusCode {
                case 206:
                    // Partial content — the normal ranged path.
                    let total = Self.totalSize(fromContentRange: http.value(forHTTPHeaderField: "Content-Range"))
                    return (data, total)
                case 200:
                    // Server ignored Range and sent the whole file in one shot.
                    return (data, data.count)
                case 416:
                    // Requested range not satisfiable — we've already read past the end.
                    return (Data(), nil)
                default:
                    throw IngestError.downloadFailed("HTTP \(http.statusCode)")
                }
            } catch {
                lastError = error
                // Linear backoff before retrying this chunk.
                try? await Task.sleep(nanoseconds: UInt64(200_000_000) * UInt64(attempt + 1))
            }
        }
        throw IngestError.downloadFailed(String(describing: lastError ?? IngestError.downloadFailed("range fetch failed")))
    }

    /// Parses the total length from a `Content-Range: bytes 0-1048575/3449447` header.
    private static func totalSize(fromContentRange header: String?) -> Int? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        let totalString = header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return totalString == "*" ? nil : Int(totalString)
    }
}
