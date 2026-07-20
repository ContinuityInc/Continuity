import Foundation
import Domain
import SwiftData

/// Removes cached files (imported audio + separated stems) for deleted tracks — but only when
/// no surviving track still references the same source (a YouTube-sourced video can appear in
/// several playlists; its audio/stems are keyed by video ID and shared. Locally imported files
/// are keyed by the track's own UUID and never shared).
///
/// Call AFTER the track models have been deleted and saved, so the reference check sees the
/// post-deletion library.
public enum LibraryCleanup {

    /// What a track owned on disk, captured BEFORE the model is deleted.
    public struct DeletedTrackFiles: Sendable {
        let stemKey: String
        let youtubeVideoID: String?
        let audioRelativePath: String?

        public init(_ track: Track) {
            stemKey = track.stemKey
            youtubeVideoID = track.youtubeVideoID
            audioRelativePath = track.localRelativePath
        }
    }

    @MainActor
    public static func removeOrphanedFiles(for deleted: [DeletedTrackFiles], in context: ModelContext) {
        for item in deleted {
            // Shared-source check only applies to YouTube-keyed files; a local import's UUID
            // key dies with its track.
            if let videoID = item.youtubeVideoID {
                let descriptor = FetchDescriptor<Track>(
                    predicate: #Predicate { $0.youtubeVideoID == videoID }
                )
                let stillReferenced = ((try? context.fetchCount(descriptor)) ?? 0) > 0
                guard !stillReferenced else { continue }

                // Legacy audio is named "<videoID>.<ext>"; the container extension varies
                // (m4a/webm/…), so match by basename.
                if let files = try? FileManager.default.contentsOfDirectory(
                    at: AudioCache.directory, includingPropertiesForKeys: nil
                ) {
                    for file in files where file.deletingPathExtension().lastPathComponent == videoID {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            } else if let relativePath = item.audioRelativePath {
                try? FileManager.default.removeItem(at: AudioCache.url(forRelativePath: relativePath))
            }

            StemCache.removeStems(key: item.stemKey)
        }
    }

    /// Launch-time sweep: removes any cached file no surviving track references. Catches
    /// stems that were still in flight when their tracks were deleted and landed on disk
    /// after the delete-time cleanup had already run.
    @MainActor
    public static func sweepOrphanedFiles(in context: ModelContext) {
        guard let tracks = try? context.fetch(FetchDescriptor<Track>()) else { return }
        // Audio files are referenced by exact relative path (local imports use a random UUID
        // filename unrelated to the track id); stems are keyed by `stemKey`.
        let referencedAudio = Set(tracks.compactMap {
            $0.localRelativePath.map { AudioCache.url(forRelativePath: $0).lastPathComponent }
        })
        let referencedStemKeys = Set(tracks.map(\.stemKey))

        if let files = try? FileManager.default.contentsOfDirectory(
            at: AudioCache.directory, includingPropertiesForKeys: nil
        ) {
            for file in files where !referencedAudio.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        if let files = try? FileManager.default.contentsOfDirectory(
            at: StemCache.directory, includingPropertiesForKeys: nil
        ) {
            for file in files {
                // Stem names are "<key>-vocals.caf" / "<key>-accompaniment.caf".
                let base = file.deletingPathExtension().lastPathComponent
                let key = base
                    .replacingOccurrences(of: "-vocals", with: "")
                    .replacingOccurrences(of: "-accompaniment", with: "")
                if !referencedStemKeys.contains(key) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}
