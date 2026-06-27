import Foundation
import SwiftData

/// Drives a single track through the M1 ingest pipeline (resolve → download → ready)
/// and writes the resulting `prepState` / `localRelativePath` back onto the SwiftData model.
///
/// One `Task` is spawned per `enqueue(_:in:)`; that is sufficient for M1, where the
/// user adds tracks one at a time. There is no shared mutable progress state and the
/// resolver/downloader are each independent per call, so no coordination/locking is
/// needed here. (A bounded, prioritised queue belongs to a later milestone.)
///
/// Lives on the main actor because it mutates `@Model` objects bound to the UI's
/// `ModelContext`; the actual networking happens off-actor inside the awaited
/// `resolver`/`downloader` calls.
@MainActor
@Observable
final class PreparationQueue {
    /// Resolves a YouTube video ID to a downloadable audio stream.
    let resolver: AudioStreamResolving
    /// Downloads a resolved stream into the on-disk audio cache.
    let downloader: AudioFileDownloading

    init(
        resolver: AudioStreamResolving = YouTubeStreamResolver(),
        downloader: AudioFileDownloading = AudioDownloader()
    ) {
        self.resolver = resolver
        self.downloader = downloader
    }

    /// Marks `track` as `.pending` and kicks off its preparation in the background.
    ///
    /// Safe to call from the UI: it persists the pending state immediately so the row's
    /// badge updates, then detaches the resolve/download work into its own `Task`.
    func enqueue(_ track: Track, in context: ModelContext) {
        track.prepState = .pending
        try? context.save()
        Task { await process(track, in: context) }
    }

    /// Runs the resolve → download → ready pipeline for one track, updating `prepState`
    /// at each stage. Any failure (missing video ID, resolve, or download error) lands the
    /// track in `.failed`; the UI surfaces that as a retry-able badge rather than a crash.
    private func process(_ track: Track, in context: ModelContext) async {
        track.prepState = .preparing
        try? context.save()

        guard let id = track.youtubeVideoID else {
            track.prepState = .failed
            try? context.save()
            return
        }

        do {
            let resolved = try await resolver.resolveAudio(videoID: id)
            let fileURL = try await downloader.downloadAudio(resolved)
            // The track could have been deleted while we were off the main actor; don't write to
            // (or resurrect) a dead model.
            guard track.modelContext != nil else { return }
            track.localRelativePath = AudioCache.relativePath(for: fileURL)

            // Analyse tempo + key off the main actor (full-track FFTs). Non-fatal: if analysis
            // fails the track still plays, just without BPM/key metadata.
            if let analysis = try? await Task.detached(priority: .utility, operation: {
                try TrackAnalyzer.analyze(fileURL: fileURL)
            }).value, track.modelContext != nil {
                track.bpm = analysis.bpm > 0 ? analysis.bpm : nil
                track.beatTimes = analysis.beatTimes
                track.keyName = analysis.key?.displayName
                track.camelotCode = analysis.camelot?.code
            }

            guard track.modelContext != nil else { return }
            track.prepState = .ready
        } catch {
            if track.modelContext != nil { track.prepState = .failed }
        }
        try? context.save()
    }
}
