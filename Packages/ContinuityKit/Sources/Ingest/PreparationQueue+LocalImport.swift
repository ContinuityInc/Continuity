import AVFoundation
import Domain
import Foundation
import SwiftData
import UniformTypeIdentifiers
import os

extension PreparationQueue {
    /// Copies user-picked audio files into `AudioCache`, creates ready tracks in an "Imported"
    /// playlist, and kicks off background analysis. Works when remote YouTube ingest is disabled
    /// (External TestFlight / App Store builds).
    @discardableResult
    public func importLocalAudio(urls: [URL], in context: ModelContext) async throws -> Playlist {
        guard !urls.isEmpty else { throw IngestError.invalidURL }

        let playlist = Self.findOrCreateImportedPlaylist(in: context)
        var imported = 0
        var startIndex = playlist.tracks.count

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            do {
                let dest = try Self.copyIntoAudioCache(from: url)
                let duration: Double
                if let file = try? AVAudioFile(forReading: dest) {
                    duration = Double(file.length) / file.processingFormat.sampleRate
                } else {
                    duration = 0
                }

                let title = url.deletingPathExtension().lastPathComponent
                let track = Track(
                    title: title,
                    artist: "Imported",
                    durationSeconds: duration,
                    artworkSymbol: "doc.fill",
                    gradientSeed: (title.hashValue & 0x7fff_ffff) % 90 + 10,
                    sortIndex: startIndex,
                    prepState: .ready,
                    sourceURLString: url.absoluteString,
                    localRelativePath: AudioCache.relativePath(for: dest)
                )
                playlist.tracks.append(track)
                context.insert(track)
                startIndex += 1
                imported += 1

                // Analysis is optional polish — don't block the import on it.
                scheduleLocalAnalysis(track, fileURL: dest, in: context)
            } catch {
                Logger.ingest.error(
                    "local import failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }

        guard imported > 0 else { throw IngestError.decodeFailed("Couldn't open any of the selected files") }
        playlist.subtitle = "\(playlist.tracks.count) tracks"
        playlist.touch()
        try? context.save()
        return playlist
    }

    private func scheduleLocalAnalysis(_ track: Track, fileURL: URL, in context: ModelContext) {
        let trackID = track.id
        Task {
            await ingestLimiter.acquire()
            let analysis = try? await Task.detached(priority: .utility) {
                try TrackAnalyzer.analyze(fileURL: fileURL)
            }.value
            if let analysis,
               let live = try? context.fetch(FetchDescriptor<Track>()).first(where: { $0.id == trackID }),
               live.modelContext != nil {
                live.bpm = analysis.bpm > 0 ? analysis.bpm : nil
                live.beatTimes = analysis.beatTimes
                live.keyName = analysis.key?.displayName
                live.camelotCode = analysis.camelot?.code
                live.loudnessLUFS = analysis.lufs
                live.analysisVersion = TrackAnalyzer.analysisVersion
                try? context.save()
            }
            await ingestLimiter.release()
        }
    }

    private static func findOrCreateImportedPlaylist(in context: ModelContext) -> Playlist {
        let descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.title == "Imported" }
        )
        if let existing = try? context.fetch(descriptor).first { return existing }
        let playlist = Playlist(
            title: "Imported",
            subtitle: "From Files",
            artworkSymbol: "folder.fill",
            gradientSeed: 42
        )
        context.insert(playlist)
        return playlist
    }

    /// Copies `source` into the audio cache as `<uuid>.<ext>`, returning the destination URL.
    private static func copyIntoAudioCache(from source: URL) throws -> URL {
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let dest = AudioCache.directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }
}
