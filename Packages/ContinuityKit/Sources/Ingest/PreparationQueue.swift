import AVFoundation
import Domain
import Foundation
import SwiftData
import ContinuityCore
import os

extension Logger {
    /// Import/analysis failures (the path that lands tracks in `.failed`).
    static let ingest = Logger(subsystem: "com.continuity.app", category: "ingest")
    /// Stem-separation pipeline logging (subsystem matches the bundle id for easy filtering).
    static let stems = Logger(subsystem: "com.continuity.app", category: "stems")
}

/// Prepares library tracks for playback: local-file import (`importLocalAudio`), launch-time
/// healing of persisted tracks, background analysis, and demand-driven stem separation —
/// writing the resulting `prepState` / `localRelativePath` / analysis / stem paths back onto
/// the SwiftData model.
///
/// On `main` this type also drives the YouTube/Spotify resolve → download pipeline; this
/// branch ships without remote ingest, so audio only enters via the Files importer.
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
    public func resumePreparation(in context: ModelContext) {
        guard let tracks = try? context.fetch(FetchDescriptor<Track>()) else { return }
        for track in tracks {
            // Demo tracks have no source and play synthesized audio — there is nothing to
            // resume. Heal any that a past build left non-ready.
            if track.isDemo {
                if track.prepState != .ready { track.prepState = .ready; try? context.save() }
                continue
            }
            switch track.prepState {
            case .ready:
                let hasAudio = track.localRelativePath.map {
                    FileManager.default.fileExists(atPath: AudioCache.url(forRelativePath: $0).path)
                } ?? false
                if hasAudio {
                    // Stems are demand-driven from the play queue (`ensureStems`) — never
                    // separated library-wide at launch. Just true-up links vs the disk.
                    reconcileStemLinks(track, in: context)
                    backfillTrackDetails(track, in: context)
                } else {
                    // Audio gone and this build can't re-download — surface as failed rather
                    // than leaving a "ready" track that silently won't play.
                    track.prepState = .failed
                    try? context.save()
                }
            case .pending, .preparing:
                track.prepState = .failed                // can't resume a download this build won't do
                try? context.save()
            case .failed:
                break
            }
        }
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
    private func backfillTrackDetails(_ track: Track, in context: ModelContext) {
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
                    let bounds = await Task.detached(priority: .utility) {
                        SilenceScan.audibleBounds(fileURL: url)
                    }.value
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
                let analysis = try? await Task.detached(priority: .utility) {
                    try TrackAnalyzer.analyze(fileURL: url)
                }.value
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
    /// Tracks whose separation is currently running (dedup across repeated `ensureStems` calls).
    var stemsInFlight: Set<UUID> = []
}
