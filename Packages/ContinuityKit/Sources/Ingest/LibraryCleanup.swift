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
///
/// The surviving-key set is resolved on the main actor (it reads the model context); every
/// filesystem pass then runs off it. Enumerating and deleting hundreds of cache files is
/// exactly the kind of work that made deleting a playlist — and launching with a large
/// library — hitch.
public enum LibraryCleanup {

    @MainActor
    public static func removeOrphanedFiles(keys: [String], in context: ModelContext) {
        let referenced = referencedStemKeys(in: context)
        let orphaned = Set(keys).subtracting(referenced)
        guard !orphaned.isEmpty else { return }
        Task.detached(priority: .utility) { removeCachedFiles(keys: orphaned) }
    }

    /// Launch-time sweep: removes any cached file whose stem key has no surviving track.
    /// Catches files that were still being written when their tracks were deleted and landed
    /// on disk after the delete-time cleanup had already run.
    @MainActor
    public static func sweepOrphanedFiles(in context: ModelContext) {
        let referenced = referencedStemKeys(in: context)
        Task.detached(priority: .utility) { sweep(referenced: referenced) }
    }

    /// Stem keys still claimed by a surviving track. Only `id` and `youtubeVideoID` feed
    /// `Track.stemKey`, so the fetch asks for those rather than hydrating every row's analysis
    /// arrays.
    @MainActor
    private static func referencedStemKeys(in context: ModelContext) -> Set<String> {
        var descriptor = FetchDescriptor<Track>()
        descriptor.propertiesToFetch = [\.id, \.youtubeVideoID]
        guard let tracks = try? context.fetch(descriptor) else { return [] }
        return Set(tracks.map(\.stemKey))
    }

    // MARK: - Filesystem passes (off the main actor)

    private static func sweep(referenced: Set<String>) {
        for file in contents(of: AudioCache.directory) {
            if !referenced.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        for file in contents(of: StemCache.directory) {
            // Stem names are "<key>-vocals.*" / "<key>-accompaniment.*". Suffix-only parsing
            // (a key can contain "-vocals" as a substring); files that don't match the
            // stem naming scheme at all are junk in this directory and stay sweepable.
            let base = file.deletingPathExtension().lastPathComponent
            let key = StemCache.key(fromStemBaseName: base) ?? base
            if !referenced.contains(key) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        for file in contents(of: ArtworkStore.directory) {
            if !referenced.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Deletes every cached artifact for a set of stem keys: audio (extension varies, match by
    /// basename), stems, and extracted artwork.
    ///
    /// Takes the whole key set at once: the audio cache is a flat directory that has to be
    /// enumerated to match a basename against an unknown extension, and doing that per key
    /// meant one full listing per deleted track (a hundred listings to delete a playlist).
    private static func removeCachedFiles(keys: Set<String>) {
        for file in contents(of: AudioCache.directory) {
            if keys.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        for key in keys {
            StemCache.removeStems(key: key)
            try? FileManager.default.removeItem(
                at: ArtworkStore.directory.appendingPathComponent("\(key).jpg"))
        }
    }

    private static func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}
