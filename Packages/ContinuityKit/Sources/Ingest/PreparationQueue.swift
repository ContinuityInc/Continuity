import AVFoundation
import Domain
import Foundation
import SwiftData
import ContinuityCore
import os

extension Logger {
    /// Import → analyse failures (the path that lands tracks in `.failed`).
    static let ingest = Logger(subsystem: "com.continuity.app", category: "ingest")
    /// Stem-separation pipeline logging (subsystem matches the bundle id for easy filtering).
    static let stems = Logger(subsystem: "com.continuity.app", category: "stems")
}

/// Drives locally-imported tracks through the ingest pipeline (analyse → ready) and,
/// once playable, the optional stem separation — writing the resulting `prepState` /
/// analysis / stem paths back onto the SwiftData model.
///
/// One `Task` is spawned per `enqueue(_:in:)`, but the heavy CPU work is gated by
/// concurrency limiters so importing many files at once doesn't fan out into dozens of
/// simultaneous analyses or stem separations.
///
/// Lives on the main actor because it mutates `@Model` objects bound to the UI's
/// `ModelContext`; the actual DSP happens off-actor inside the awaited calls.
@MainActor
@Observable
public final class PreparationQueue {
    /// Caps simultaneous analyse/backfill work (CPU + file-IO bound).
    private let ingestLimiter = ConcurrencyLimiter(limit: 3)
    /// Caps simultaneous stem separations to one — each is CPU/RAM-heavy, so they queue.
    let stemLimiter = ConcurrencyLimiter(limit: 1)

    public init() {}

    /// Coordination hook: deletions must drop tracks from the live `Player` queue BEFORE the
    /// models die. Wired to `Player.handleDeleted` at startup.
    public var onTracksDeleted: ((Set<UUID>) -> Void)?

    /// Marks `track` as `.pending` and kicks off its preparation in the background.
    ///
    /// Safe to call from the UI: it persists the pending state immediately so the row's
    /// badge updates, then detaches the analysis work into its own `Task`.
    public func enqueue(_ track: Track, in context: ModelContext) {
        track.prepState = .pending
        try? context.save()
        Task { await process(track, in: context) }
    }

    /// Resumes preparation for a persisted library at launch: finishes analysis for tracks that
    /// were interrupted mid-import, and marks ready tracks whose audio file went missing as
    /// `.failed` (a local import has no remote source to re-download from). `.failed` tracks
    /// are left as-is.
    public func resumePreparation(in context: ModelContext) {
        guard let tracks = try? context.fetch(FetchDescriptor<Track>()) else { return }
        for track in tracks {
            // Demo tracks have no source and play synthesized audio — there is nothing to ingest
            // or resume. Heal any that aren't marked ready.
            if track.isDemo {
                if track.prepState != .ready { track.prepState = .ready; try? context.save() }
                continue
            }
            switch track.prepState {
            case .ready:
                let hasAudio = track.localRelativePath.map {
                    FileManager.default.fileExists(atPath: AudioCache.url(forRelativePath: $0).path)
                } ?? false
                if !hasAudio {
                    // The imported file was lost/evicted — nothing to re-fetch it from.
                    track.prepState = .failed
                    try? context.save()
                } else {
                    // Stems are demand-driven from the play queue (`ensureStems`) — never
                    // separated library-wide at launch. Just true-up links vs the disk.
                    reconcileStemLinks(track, in: context)
                    backfillTrackDetails(track, in: context)
                }
            case .pending, .preparing:
                enqueue(track, in: context)   // interrupted before finishing → pick back up
            case .failed:
                break
            }
        }
    }

    /// Runs the analyse → ready pipeline for one already-on-disk track, updating `prepState`.
    /// A missing audio file lands the track in `.failed`; the UI surfaces that as a badge.
    private func process(_ track: Track, in context: ModelContext) async {
        track.prepState = .preparing
        try? context.save()

        let fileExists = track.localRelativePath.map {
            FileManager.default.fileExists(atPath: AudioCache.url(forRelativePath: $0).path)
        } ?? false

        guard fileExists, track.modelContext != nil else {
            Logger.ingest.error("prep failed for \(track.title, privacy: .public): audio file missing")
            if track.modelContext != nil { track.prepState = .failed }
            try? context.save()
            return
        }

        track.prepState = .ready
        try? context.save()

        // Already-cached stems (re-adds) are linked instantly; separation itself stays
        // demand-driven from the play queue. Analysis/backfill runs post-ready.
        reconcileStemLinks(track, in: context)
        backfillTrackDetails(track, in: context)
    }

    /// Best-effort, fire-and-forget healing of a ready track's details:
    /// - `durationSeconds` from the local audio file when the model still says 0 ("0:00" rows),
    /// - audible bounds for gapless transitions,
    /// - re-analysis when `TrackAnalyzer.analysisVersion` has moved.
    ///
    /// Runs post-`.ready` (never blocks playability) from the import pipeline and
    /// `resumePreparation`. Every heavy step is gated by `ingestLimiter` so a large library's
    /// launch backfill can't fan out into dozens of simultaneous file opens / PCM decodes
    /// (which hitch launch and thrash memory).
    func backfillTrackDetails(_ track: Track, in context: ModelContext) {
        let needsDuration = track.durationSeconds <= 0 && track.localRelativePath != nil
        let needsSilenceScan = track.audibleEndSeconds == nil && track.localRelativePath != nil
        let needsReanalysis = track.localRelativePath != nil
            && (track.analysisVersion ?? 0) < TrackAnalyzer.analysisVersion
        guard needsDuration || needsSilenceScan || needsReanalysis else { return }

        Task {
            guard track.modelContext != nil else { return }
            // Duration header + silence scan used to run ungated — one Task per ready track at
            // every launch. SilenceScan alone decodes ~20 MB of PCM per track.
            if needsDuration || needsSilenceScan, let relativePath = track.localRelativePath {
                let url = AudioCache.url(forRelativePath: relativePath)
                await ingestLimiter.acquire()
                if needsDuration, track.modelContext != nil,
                   let file = try? AVAudioFile(forReading: url) {
                    track.durationSeconds = Double(file.length) / file.processingFormat.sampleRate
                }
                if needsSilenceScan, track.modelContext != nil {
                    MemoryFootprint.breadcrumb("silence scan begin")
                    let bounds = await Task.detached(priority: .utility) {
                        SilenceScan.audibleBounds(fileURL: url)
                    }.value
                    MemoryFootprint.breadcrumb("silence scan end")
                    if let bounds, track.modelContext != nil {
                        track.audibleStartSeconds = bounds.audibleStart
                        track.audibleEndSeconds = bounds.audibleEnd
                    }
                }
                await ingestLimiter.release()
            }
            // Stale analysis: results computed by an older analyzer (e.g. pre-fix key detection)
            // are refreshed so fixes reach the existing library. CPU-heavy → limiter-gated,
            // off the main actor.
            if needsReanalysis, track.modelContext != nil, let relativePath = track.localRelativePath {
                let url = AudioCache.url(forRelativePath: relativePath)
                await ingestLimiter.acquire()
                MemoryFootprint.breadcrumb("analysis begin")
                let analysis = try? await Task.detached(priority: .utility) {
                    try TrackAnalyzer.analyze(fileURL: url)
                }.value
                MemoryFootprint.breadcrumb("analysis end")
                await ingestLimiter.release()
                if let analysis, track.modelContext != nil {
                    track.bpm = analysis.bpm > 0 ? analysis.bpm : nil
                    track.beatTimes = analysis.beatTimes
                    track.keyName = analysis.key?.displayName
                    track.camelotCode = analysis.camelot?.code
                    track.loudnessLUFS = analysis.lufs
                    track.analysisVersion = TrackAnalyzer.analysisVersion
                }
            }
            guard track.modelContext != nil else { return }
            try? context.save()
        }
    }

    // MARK: Stems (demand-driven)

    /// Stem keys for the current play-queue neighborhood — protected from cache eviction.
    var protectedStemKeys: Set<String> = []
    /// Stem keys whose separation is currently running. Keyed like the cache — by the stable
    /// track key (`Track.stemKey`), not the Track row — so the same source in two playlists
    /// can't run two concurrent separations that rewrite the same output files.
    var stemsInFlight: Set<String> = []
    /// Separation is held until this moment — armed on the session's FIRST stem demand
    /// (i.e. when playback starts). Pressing play spins up the audio engine, UI, artwork, and
    /// (first run) the model download all at once; the ORT session-load + first-window peak is
    /// the app's largest allocation and must not stack on that ramp.
    var separationAllowedAt: Date?
    /// At most one pending post-hold retry (ensureStems also re-fires on every track change).
    var stemsRetryScheduled = false
}
