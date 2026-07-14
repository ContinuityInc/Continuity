import Foundation
import ContinuityCore

/// On-disk cache of per-track separated stems, keyed by a stable track key (the YouTube video
/// ID). Mirrors `AudioCache`: flat files in one directory, addressed by relative path.
///
/// New stems are AAC `.m4a` (~7 MB/track); legacy float32 `.caf` stems from older builds keep
/// playing (paths are stored on the Track) and remain eviction candidates. The cache is
/// **size-budgeted**: `enforceBudget` evicts least-recently-used keys past `budgetBytes`, never
/// touching protected keys (the play-queue neighborhood). Evicted stems re-separate on demand.
public enum StemCache {
    /// ~8 GB. With ~3.4 GB of downloaded audio and the ~165 MB model, total app storage for a
    /// 1000-song library stays under the ~15 GB target even when the stem cache is full.
    public static let budgetBytes: Int64 = 8_000_000_000

    public static var directory: URL {
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

    public static func vocalsURL(key: String) -> URL { directory.appendingPathComponent("\(key)-vocals.m4a") }
    public static func accompanimentURL(key: String) -> URL { directory.appendingPathComponent("\(key)-accompaniment.m4a") }

    public static func relativePath(for url: URL) -> String { url.lastPathComponent }
    public static func url(forRelativePath path: String) -> URL { directory.appendingPathComponent(path) }

    /// Whether both stems already exist on disk for this key (either format generation).
    public static func hasStems(key: String) -> Bool {
        stemFile(key: key, kind: "vocals") != nil && stemFile(key: key, kind: "accompaniment") != nil
    }

    /// Existing on-disk stem file for a key/kind, preferring the current `.m4a` format and
    /// falling back to a legacy `.caf` from older builds.
    public static func stemFile(key: String, kind: String) -> URL? {
        for ext in ["m4a", "caf"] {
            let url = directory.appendingPathComponent("\(key)-\(kind).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Deletes all stem files for a key, across format generations (m4a + legacy caf).
    public static func removeStems(key: String) {
        for kind in ["vocals", "accompaniment"] {
            for ext in ["m4a", "caf"] {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent("\(key)-\(kind).\(ext)"))
            }
        }
    }

    /// Bumps the LRU clock for a key's stems (called for tracks near the play queue).
    public static func markUsed(key: String) {
        for kind in ["vocals", "accompaniment"] {
            guard let url = stemFile(key: key, kind: kind) else { continue }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
    }

    /// Evicts least-recently-used keys until the cache fits `budgetBytes`. `protected` keys
    /// (the play-queue neighborhood + separations in flight) are never evicted. Safe to call
    /// from any thread; file ops only.
    public static func enforceBudget(protecting protected: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        // Group stem files by key: names are "<key>-vocals.<ext>" / "<key>-accompaniment.<ext>".
        var byKey: [String: (bytes: Int64, lastUsed: Date, urls: [URL])] = [:]
        for file in files {
            let base = file.deletingPathExtension().lastPathComponent
            guard let range = base.range(of: "-vocals") ?? base.range(of: "-accompaniment"),
                  range.upperBound == base.endIndex else { continue }
            let key = String(base[..<range.lowerBound])

            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let bytes = Int64(values?.fileSize ?? 0)
            let date = values?.contentModificationDate ?? .distantPast
            var entry = byKey[key] ?? (0, Date.distantPast, [])
            entry.bytes += bytes
            entry.lastUsed = max(entry.lastUsed, date)
            entry.urls.append(file)
            byKey[key] = entry
        }

        let entries = byKey.map { CacheEviction.Entry(key: $0.key, bytes: $0.value.bytes, lastUsed: $0.value.lastUsed) }
        for key in CacheEviction.keysToEvict(entries: entries, budgetBytes: budgetBytes, protected: protected) {
            for url in byKey[key]?.urls ?? [] {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
