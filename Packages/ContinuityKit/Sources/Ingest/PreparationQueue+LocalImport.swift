import AVFoundation
import Domain
import Foundation
import SwiftData
import ContinuityCore
import os

extension PreparationQueue {
    /// Audio containers iOS can decode — anything else in a scanned folder is not importable
    /// music.
    private static let musicExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "m4b", "mp4",
    ]
    /// Below this size a file is "obviously not music" (ringtone snippets, UI sounds,
    /// notification tones) — roughly 15 seconds of 128 kbps audio.
    private static let minimumMusicBytes = 250_000

    /// Imports user-picked local audio: files are imported directly; folders are scanned
    /// recursively for music (audio extension + big enough to be a song), so pointing the
    /// picker at a music folder imports the whole thing in one shot. Everything lands in the
    /// shared "Local Files" playlist, deduplicated against what's already there. Returns how
    /// many tracks were imported; failures are logged and skipped (partial imports succeed).
    public func importLocalFiles(_ urls: [URL], in context: ModelContext) async -> Int {
        var imported = 0
        // What "Local Files" already holds, snapshotted once as plain values. The duplicate
        // check used to re-scan the playlist's SwiftData rows for every file imported — three
        // managed-property reads per comparison, quadratic over a folder import.
        var existing = (Self.existingLocalFilesPlaylist(in: context)?.tracks ?? []).map {
            ImportedSong(title: $0.title, artist: $0.artist, duration: $0.durationSeconds)
        }
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                // Security scope covers the folder's descendants, so files found by the scan
                // are readable without their own scoped access. The scan itself is a recursive
                // enumeration with per-file resource reads — thousands of syscalls for a real
                // music folder — so it runs off the main actor, or the import spinner freezes
                // along with the rest of the UI.
                let files = await Task.detached(priority: .userInitiated) {
                    Self.scanForMusic(in: url)
                }.value
                for file in files {
                    if let song = await importOne(file, in: context, existing: existing) {
                        existing.append(song)
                        imported += 1
                    }
                }
            } else if let song = await importOne(url, in: context, existing: existing) {
                existing.append(song)
                imported += 1
            }
        }
        return imported
    }

    /// The identity the duplicate check compares — kept as plain values so a folder import
    /// doesn't read the growing playlist out of SwiftData once per file.
    struct ImportedSong {
        let title: String
        let artist: String
        let duration: Double
    }

    /// Recursively lists the music files in a folder: audio extension, not hidden, and large
    /// enough to plausibly be a song. Sorted by path so import order (→ `sortIndex`) is stable.
    private nonisolated static func scanForMusic(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  musicExtensions.contains(url.pathExtension.lowercased()),
                  (values.fileSize ?? 0) >= minimumMusicBytes else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Imports one file, returning its identity on success (nil when it failed or was a
    /// duplicate of something in `existing`).
    private func importOne(_ url: URL, in context: ModelContext,
                           existing: [ImportedSong]) async -> ImportedSong? {
        // Direct file picks carry their own security scope; files inside a scanned folder
        // are covered by the folder's scope (startAccessing then returns false — harmless).
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // One fresh UUID keys everything for this track: the model row, the cached audio
        // file's basename, and the stem-cache key (`Track.stemKey` == id for local imports) —
        // so cleanup/sweep can match files to tracks by basename.
        let trackID = UUID()
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
        let destination = AudioCache.fileURL(videoID: trackID.uuidString, container: ext)
        // Off the main actor: songs are multi-megabyte files, and a folder import copies
        // hundreds of them back to back.
        let copied = await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                return true
            } catch {
                Logger.ingest.error("local import copy failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                return false
            }
        }.value
        guard copied else { return nil }

        // Metadata load runs off-main (AVURLAsset touches the file).
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let meta = await Task.detached(priority: .userInitiated) { () -> (title: String?, artist: String?, duration: Double, artwork: Data?) in
            let asset = AVURLAsset(url: destination)
            var title: String?
            var artist: String?
            var artwork: Data?
            var duration: Double = 0
            if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite {
                duration = seconds
            }
            if let items = try? await asset.load(.commonMetadata) {
                for item in items {
                    switch item.commonKey {
                    case .commonKeyTitle?: title = try? await item.load(.stringValue)
                    case .commonKeyArtist?: artist = try? await item.load(.stringValue)
                    case .commonKeyArtwork?: artwork = try? await item.load(.dataValue)
                    default: break
                    }
                }
            }
            return (title, artist, duration, artwork)
        }.value

        let playlist = Self.findOrCreateLocalFilesPlaylist(in: context)
        let title = meta.title?.isEmpty == false ? meta.title! : fallbackTitle
        let artist = meta.artist?.isEmpty == false ? meta.artist! : "Unknown Artist"

        // Re-scanning the same folder must not double-import: same title + artist + length
        // (±1s) already in Local Files means we've seen this song. Compared against the
        // caller's snapshot, so this stays plain-value work as the playlist grows.
        if existing.contains(where: {
            $0.title == title && $0.artist == artist && abs($0.duration - meta.duration) < 1
        }) {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }

        // Embedded artwork → Application Support/Artwork/<id>.jpg (excluded from backup by
        // the directory, mirroring StemCache).
        var artworkPath: String?
        if let data = meta.artwork {
            let name = "\(trackID.uuidString).jpg"
            let artworkURL = ArtworkStore.directory.appendingPathComponent(name)
            // Cover art runs to megabytes; write it off the main actor like the audio copy.
            let wrote = await Task.detached(priority: .userInitiated) {
                (try? data.write(to: artworkURL)) != nil
            }.value
            if wrote { artworkPath = name }
        }

        let track = Track(
            id: trackID,
            title: title,
            artist: artist,
            durationSeconds: meta.duration,
            artworkSymbol: playlist.artworkSymbol,
            // Vary the gradient per track so rows are visually distinct.
            gradientSeed: playlist.gradientSeed * 100 + playlist.tracks.count,
            sortIndex: playlist.tracks.count,
            prepState: .ready,
            localRelativePath: AudioCache.relativePath(for: destination)
        )
        track.artworkPath = artworkPath

        playlist.tracks.append(track)
        context.insert(track)
        playlist.touch()    // membership changed → resort the library
        try? context.save()

        // BPM/key/loudness/silence analysis runs post-ready, limiter-gated.
        backfillTrackDetails(track, in: context)
        return ImportedSong(title: title, artist: artist, duration: meta.duration)
    }

    /// The shared "Local Files" playlist, if one exists. Lookup only: the dedupe snapshot is
    /// taken before anything is known to import, and picking a folder with no music in it must
    /// not leave an empty playlist behind.
    private static func existingLocalFilesPlaylist(in context: ModelContext) -> Playlist? {
        let title = "Local Files"
        let descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.title == title })
        // Skip a demo playlist that happens to share the name — imports go to a real one.
        return (try? context.fetch(descriptor))?.first(where: { !$0.isDemo })
    }

    /// Returns the shared "Local Files" playlist for local imports, creating it if missing.
    private static func findOrCreateLocalFilesPlaylist(in context: ModelContext) -> Playlist {
        if let existing = existingLocalFilesPlaylist(in: context) {
            return existing
        }
        let title = "Local Files"
        let playlist = Playlist(
            title: title,
            subtitle: "Imported from Files",
            artworkSymbol: "folder.fill",
            gradientSeed: 53
        )
        context.insert(playlist)
        return playlist
    }
}
