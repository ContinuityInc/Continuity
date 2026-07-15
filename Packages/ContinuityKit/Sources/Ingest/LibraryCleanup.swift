import Foundation
import Domain
import SwiftData

/// Removes cached files (downloaded audio + separated stems) for deleted tracks — but only when
/// no surviving track still references the same source video (the same video can appear in
/// several playlists; caches are keyed by video ID and shared).
///
/// Call AFTER the track models have been deleted and saved, so the reference check sees the
/// post-deletion library.
public enum LibraryCleanup {

    @MainActor
    public static func removeOrphanedFiles(videoIDs: [String], in context: ModelContext) {
        for videoID in Set(videoIDs) {
            let descriptor = FetchDescriptor<Track>(
                predicate: #Predicate { $0.youtubeVideoID == videoID }
            )
            let stillReferenced = ((try? context.fetchCount(descriptor)) ?? 0) > 0
            guard !stillReferenced else { continue }

            // Audio: the container extension varies (m4a/webm/…), so match by basename.
            if let files = try? FileManager.default.contentsOfDirectory(
                at: AudioCache.directory, includingPropertiesForKeys: nil
            ) {
                for file in files where file.deletingPathExtension().lastPathComponent == videoID {
                    try? FileManager.default.removeItem(at: file)
                }
            }

            StemCache.removeStems(key: videoID)
        }
    }

    /// Launch-time sweep: removes any cached file whose video ID has no surviving track. Catches
    /// downloads/stems that were still in flight when their tracks were deleted and landed on
    /// disk after the delete-time cleanup had already run.
    @MainActor
    public static func sweepOrphanedFiles(in context: ModelContext) {
        guard let tracks = try? context.fetch(FetchDescriptor<Track>()) else { return }
        let referenced = Set(tracks.compactMap(\.youtubeVideoID))

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
                // Stem names are "<videoID>-vocals.caf" / "<videoID>-accompaniment.caf".
                let base = file.deletingPathExtension().lastPathComponent
                let key = base
                    .replacingOccurrences(of: "-vocals", with: "")
                    .replacingOccurrences(of: "-accompaniment", with: "")
                if !referenced.contains(key) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}
