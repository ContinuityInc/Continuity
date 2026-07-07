import Foundation

/// On-disk location helper for downloaded audio in the M1 ingestion pipeline.
///
/// Cached files live flat in `<Caches>/ContinuityAudio`, named `<videoID>.<container>`.
/// This enum only computes URLs and ensures the directory exists; it does not read,
/// write, or delete file contents.
enum AudioCache {
    /// The directory holding all cached audio, created on first access.
    ///
    /// Located under the user's caches directory so the OS may evict it under
    /// storage pressure. Intermediate directories are created best-effort.
    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("ContinuityAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The on-disk URL for a given video's audio, e.g. `.../ContinuityAudio/<videoID>.<container>`.
    static func fileURL(videoID: String, container: String) -> URL {
        directory.appendingPathComponent("\(videoID).\(container)")
    }

    /// The path of a cached file relative to `directory`.
    ///
    /// Files live flat in `directory`, so the last path component is the relative path.
    /// Useful for persisting a stable reference that survives caches-directory relocation.
    static func relativePath(for url: URL) -> String {
        url.lastPathComponent
    }

    /// Resolves a relative path (as returned by `relativePath(for:)`) back to an absolute URL.
    static func url(forRelativePath path: String) -> URL {
        directory.appendingPathComponent(path)
    }
}
