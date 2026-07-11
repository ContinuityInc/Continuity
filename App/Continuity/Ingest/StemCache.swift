import Foundation

/// On-disk cache of per-track separated stems (`.caf`), keyed by a stable track key (the YouTube
/// video ID). Mirrors `AudioCache`: flat files in one directory, addressed by relative path.
enum StemCache {
    static var directory: URL {
        // Under Application Support (not Caches) so stems persist across launches. Excluded from
        // iCloud backup — they're large and re-derivable from the cached audio.
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stems", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    static func vocalsURL(key: String) -> URL { directory.appendingPathComponent("\(key)-vocals.caf") }
    static func accompanimentURL(key: String) -> URL { directory.appendingPathComponent("\(key)-accompaniment.caf") }

    static func relativePath(for url: URL) -> String { url.lastPathComponent }
    static func url(forRelativePath path: String) -> URL { directory.appendingPathComponent(path) }

    /// Whether both stems already exist on disk for this key.
    static func hasStems(key: String) -> Bool {
        FileManager.default.fileExists(atPath: vocalsURL(key: key).path)
            && FileManager.default.fileExists(atPath: accompanimentURL(key: key).path)
    }
}
