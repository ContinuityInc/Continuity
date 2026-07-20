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
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                // Security scope covers the folder's descendants, so files found by the scan
                // are readable without their own scoped access.
                for file in Self.scanForMusic(in: url) {
                    if await importOne(file, in: context) { imported += 1 }
                }
            } else if await importOne(url, in: context) {
                imported += 1
            }
        }
        return imported
    }

    /// Recursively lists the music files in a folder: audio extension, not hidden, and large
    /// enough to plausibly be a song. Sorted by path so import order (→ `sortIndex`) is stable.
    private static func scanForMusic(in folder: URL) -> [URL] {
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

    private func importOne(_ url: URL, in context: ModelContext) async -> Bool {
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
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            Logger.ingest.error("local import copy failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }

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
        // (±1s) already in Local Files means we've seen this song.
        if playlist.tracks.contains(where: {
            $0.title == title && $0.artist == artist && abs($0.durationSeconds - meta.duration) < 1
        }) {
            try? FileManager.default.removeItem(at: destination)
            return false
        }

        // Embedded artwork → Application Support/Artwork/<id>.jpg (excluded from backup by
        // the directory, mirroring StemCache).
        var artworkPath: String?
        if let data = meta.artwork {
            let name = "\(trackID.uuidString).jpg"
            let artworkURL = ArtworkStore.directory.appendingPathComponent(name)
            if (try? data.write(to: artworkURL)) != nil { artworkPath = name }
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
        return true
    }

    /// Returns the shared "Local Files" playlist for local imports, creating it if missing.
    private static func findOrCreateLocalFilesPlaylist(in context: ModelContext) -> Playlist {
        let title = "Local Files"
        let descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.title == title })
        // Skip a demo playlist that happens to share the name — imports go to a real one.
        if let existing = (try? context.fetch(descriptor))?.first(where: { !$0.isDemo }) {
            return existing
        }
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
