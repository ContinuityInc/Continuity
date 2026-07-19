import AVFoundation
import Domain
import Foundation
import SwiftData
import ContinuityCore
import os

extension PreparationQueue {
    /// Imports user-picked local audio files: copies each into the audio cache, reads its
    /// embedded metadata (title/artist/duration/artwork), creates a ready `Track` in the
    /// shared "My Music" playlist, and kicks off analysis. Returns how many files imported
    /// successfully; failures are logged and skipped (partial imports succeed).
    public func importLocalFiles(_ urls: [URL], in context: ModelContext) async -> Int {
        var imported = 0
        for url in urls {
            if await importOne(url, in: context) { imported += 1 }
        }
        return imported
    }

    private func importOne(_ url: URL, in context: ModelContext) async -> Bool {
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

        // Embedded artwork → Application Support/Artwork/<id>.jpg (excluded from backup by
        // the directory, mirroring StemCache).
        var artworkPath: String?
        if let data = meta.artwork {
            let name = "\(trackID.uuidString).jpg"
            let artworkURL = ArtworkStore.directory.appendingPathComponent(name)
            if (try? data.write(to: artworkURL)) != nil { artworkPath = name }
        }

        let playlist = Self.findOrCreateMyMusicPlaylist(in: context)
        let track = Track(
            id: trackID,
            title: meta.title?.isEmpty == false ? meta.title! : fallbackTitle,
            artist: meta.artist?.isEmpty == false ? meta.artist! : "Unknown Artist",
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

    /// Returns the shared "My Music" playlist for local imports, creating it if missing.
    private static func findOrCreateMyMusicPlaylist(in context: ModelContext) -> Playlist {
        let title = "My Music"
        let descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.title == title })
        // Skip a demo playlist that happens to share the name — imports go to a real one.
        if let existing = (try? context.fetch(descriptor))?.first(where: { !$0.isDemo }) {
            return existing
        }
        let playlist = Playlist(
            title: title,
            subtitle: "Imported from Files",
            artworkSymbol: "music.note",
            gradientSeed: 11
        )
        context.insert(playlist)
        return playlist
    }
}
