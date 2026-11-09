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
        let cacheIndex = CacheIndex.snapshot()
        var needsSave = false
        for (i, track) in tracks.enumerated() {
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
                    reconcileStemLinks(track, in: context, using: cacheIndex)
                    backfillTrackDetails(track, in: context)
                } else {
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
    /// duration, audible bounds, and re-analysis when `TrackAnalyzer.analysisVersion` moved.
    func backfillTrackDetails(_ track: Track, in context: ModelContext) {
        let needsDuration = track.durationSeconds <= 0 && track.localRelativePath != nil
        let needsSilenceScan = track.audibleEndSeconds == nil && track.localRelativePath != nil
        let needsReanalysis = track.localRelativePath != nil
            && (track.analysisVersion ?? 0) < TrackAnalyzer.analysisVersion
        guard needsDuration || needsSilenceScan || needsReanalysis else { return }

        Task {
            guard track.modelContext != nil else { return }
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

    var protectedStemKeys: Set<String> = []
    var stemsInFlight: Set<String> = []
    var separationAllowedAt: Date?
    var stemsRetryScheduled = false
    var budgetPassInFlight = false
    var budgetPassRequested = false
    var budgetExtraProtectedKeys: Set<String> = []
}
