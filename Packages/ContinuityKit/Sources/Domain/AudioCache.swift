import Foundation

/// On-disk location helper for downloaded audio in the ingestion pipeline.
///
/// Files live flat in `<Application Support>/ContinuityAudio`, named `<videoID>.<container>`.
/// This enum only computes URLs and ensures the directory exists; it does not read,
/// write, or delete file contents.
public enum AudioCache {
    /// The directory holding all downloaded audio, created on first access.
    ///
    /// Under Application Support (not Caches) so the library survives relaunch and isn't evicted
    /// under storage pressure. Excluded from iCloud backup — it's large and re-downloadable.
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        var dir = base.appendingPathComponent("ContinuityAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// The on-disk URL for a given video's audio, e.g. `.../ContinuityAudio/<videoID>.<container>`.
    public static func fileURL(videoID: String, container: String) -> URL {
        directory.appendingPathComponent("\(videoID).\(container)")
    }

    /// The path of a cached file relative to `directory`.
    ///
    /// Files live flat in `directory`, so the last path component is the relative path.
    /// Useful for persisting a stable reference that survives caches-directory relocation.
    public static func relativePath(for url: URL) -> String {
        url.lastPathComponent
    }

    /// Resolves a relative path (as returned by `relativePath(for:)`) back to an absolute URL.
    public static func url(forRelativePath path: String) -> URL {
        directory.appendingPathComponent(path)
    }
}
