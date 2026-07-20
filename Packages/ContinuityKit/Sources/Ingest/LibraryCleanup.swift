import Foundation
import Domain
import SwiftData

/// Removes cached files (imported audio + separated stems + extracted artwork) for deleted
/// tracks — but only when no surviving track still shares the same stem key (a legacy
/// YouTube-sourced video can appear in several playlists; caches are keyed by `Track.stemKey`
/// and shared).
///
/// Call AFTER the track models have been deleted and saved, so the reference check sees the
/// post-deletion library.
public enum LibraryCleanup {

    /// Fetch limited to the fields `stemKey` reads — a cleanup pass has no business eagerly
    /// hydrating every track's beat grid.
    private static func stemKeyDescriptor() -> FetchDescriptor<Track> {
        var descriptor = FetchDescriptor<Track>()
        descriptor.propertiesToFetch = [\.youtubeVideoID, \.id]
        return descriptor
    }

    @MainActor
    public static func removeOrphanedFiles(keys: [String], in context: ModelContext) {
        let tracks = (try? context.fetch(Self.stemKeyDescriptor())) ?? []
        let referenced = Set(tracks.map(\.stemKey))
        for key in Set(keys) where !referenced.contains(key) {
            removeCachedFiles(key: key)
        }
    }

    /// Launch-time sweep: removes any cached file whose stem key has no surviving track.
    /// Catches files that were still being written when their tracks were deleted and landed
    /// on disk after the delete-time cleanup had already run.
    @MainActor
    public static func sweepOrphanedFiles(in context: ModelContext) {
        guard let tracks = try? context.fetch(Self.stemKeyDescriptor()) else { return }
        let referenced = Set(tracks.map(\.stemKey))

        if let files = try? FileManager.default.contentsOfDirectory(
            at: AudioCache.directory, includingPropertiesForKeys: nil
        ) {
            for file in files where !referenced.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        if let files = try? FileManager.default.contentsOfDirectory(
            at: StemCache.directory, includingPropertiesForKeys: nil
        ) {
            for file in files {
                // Stem names are "<key>-vocals.*" / "<key>-accompaniment.*". Suffix-only parsing
                // (a key can contain "-vocals" as a substring); files that don't match the
                // stem naming scheme at all are junk in this directory and stay sweepable.
                let base = file.deletingPathExtension().lastPathComponent
                let key = StemCache.key(fromStemBaseName: base) ?? base
                if !referenced.contains(key) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }

        if let files = try? FileManager.default.contentsOfDirectory(
            at: ArtworkStore.directory, includingPropertiesForKeys: nil
        ) {
            for file in files where !referenced.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Deletes every cached artifact for one stem key: audio (extension varies, match by
    /// basename), stems, and extracted artwork.
    private static func removeCachedFiles(key: String) {
        if let files = try? FileManager.default.contentsOfDirectory(
            at: AudioCache.directory, includingPropertiesForKeys: nil
        ) {
            for file in files where file.deletingPathExtension().lastPathComponent == key {
                try? FileManager.default.removeItem(at: file)
            }
        }
        StemCache.removeStems(key: key)
        try? FileManager.default.removeItem(
            at: ArtworkStore.directory.appendingPathComponent("\(key).jpg"))
    }
}
