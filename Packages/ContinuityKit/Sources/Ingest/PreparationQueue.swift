import AVFoundation
import Domain
import Foundation
import SwiftData
import os

extension Logger {
    /// Import/analysis failures (the path that lands tracks in `.failed`).
    static let ingest = Logger(subsystem: "com.continuity.app", category: "ingest")
    /// Stem-separation pipeline logging (subsystem matches the bundle id for easy filtering).
    static let stems = Logger(subsystem: "com.continuity.app", category: "stems")
}

/// Prepares library tracks for playback: local-file import (`importLocalFiles`), launch-time
/// healing of persisted tracks, background analysis, and demand-driven stem separation —
/// writing the resulting `prepState` / `localRelativePath` / analysis / stem paths back onto
/// the SwiftData model.
///
/// This App Store cut ships without remote ingest, so audio only enters via the Files importer.
///
/// Lives on the main actor because it mutates `@Model` objects bound to the UI's
/// `ModelContext`; the actual DSP happens off-actor inside the awaited calls.
@MainActor
@Observable
public final class PreparationQueue {
    /// Caps simultaneous import/analyse work (file-I/O and CPU-bound).
    let ingestLimiter = ConcurrencyLimiter(limit: 3)
    /// Caps simultaneous stem separations to one — each is CPU/RAM-heavy, so they queue.
    let stemLimiter = ConcurrencyLimiter(limit: 1)

    public init() {}

    /// Heals a persisted library at launch: trues up stem links and display details for tracks
    /// whose audio is present, and marks tracks whose audio file went missing (or that were
    /// interrupted mid-pipeline by a kill) as `.failed` — this build can't re-download them.
    ///
    /// Yields every 40 rows so a thousand-track library doesn't occupy the main actor for the
    /// whole pass before the first frame can land.
    public func resumePreparation(in context: ModelContext) async {
        guard let tracks = try? context.fetch(FetchDescriptor<Track>()) else { return }
        // One directory listing per cache instead of up to five `fileExists` probes per track.
        let cacheIndex = CacheIndex.snapshot()
        var needsSave = false
        for (i, track) in tracks.enumerated() {
            // Demo tracks have no source and play synthesized audio — there is nothing to
            // resume. Heal any that a past build left non-ready.
            if track.isDemo {
                if track.prepState != .ready {
                    track.prepState = .ready
                    needsSave = true
                }
                continue
            }
            switch track.prepState {
            case .ready:
                let hasAudio = track.localRelativePath.map { cacheIndex.hasAudio($0) } ?? false
                if hasAudio {
                    // Stems are demand-driven from the play queue (`ensureStems`) — never
                    // separated library-wide at launch. Just true-up links vs the disk.
                    reconcileStemLinks(track, in: context, using: cacheIndex)
                    backfillTrackDetails(track, in: context)
                } else {
                    // Audio gone and this build can't re-download — surface as failed rather
                    // than leaving a "ready" track that silently won't play.
                    track.prepState = .failed
                    needsSave = true
                }
            case .pending, .preparing:
                track.prepState = .failed
                needsSave = true
            case .failed:
                break
            }
            if i.isMultiple(of: 40) { await Task.yield() }
        }
        if needsSave { try? context.save() }
    }

    /// Coordination hook: when tracks are deleted, the live `Player` must drop them from its
    /// queue BEFORE the models die. Wired to `Player.handleDeleted` at startup.
    public var onTracksDeleted: ((Set<UUID>) -> Void)?

    /// Best-effort, fire-and-forget healing of a ready track's display details:
    /// - `durationSeconds` from the local audio file when the model still says 0 ("0:00" rows),
    /// - audible bounds for gapless transitions,
    /// - re-analysis when `TrackAnalyzer.analysisVersion` has moved.
    ///
    /// Runs post-`.ready` (never blocks playability) from both the import path and
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
    /// Stem keys whose separation is currently running. Keyed like the cache — by video/UUID,
    /// not Track row — so the same source in two playlists can't run two concurrent
    /// separations that rewrite the same output files.
    var stemsInFlight: Set<String> = []
    /// Separation is held until this moment — armed on the session's FIRST stem demand
    /// (i.e. when playback starts). Pressing play spins up the audio engine, UI, artwork, and
    /// (first run) the model download all at once; the ORT session-load + first-window peak is
    /// the app's largest allocation and must not stack on that ramp.
    var separationAllowedAt: Date?
    /// At most one pending post-hold retry (ensureStems also re-fires on every track change).
    var stemsRetryScheduled = false
    /// True while a stem-cache budget pass is running. `ensureStems` fires on every queue move
    /// and each pass enumerates the whole stem directory with per-file sizes and dates, so
    /// rapid skips used to stack one full scan per skip.
    var budgetPassInFlight = false
    /// A pass was asked for while one was running — run exactly one more when it finishes.
    var budgetPassRequested = false
    /// Keys a queued pass must protect on top of the play-queue neighborhood (a stem written
    /// after the queue moved on), drained into the next pass.
    var budgetExtraProtectedKeys: Set<String> = []
}
