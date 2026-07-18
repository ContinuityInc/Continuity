import AVFoundation
import Domain
import Foundation
import SwiftData
import ContinuityCore
import os

extension Logger {
    /// Resolve → download → analyse failures (the path that lands tracks in `.failed`).
    static let ingest = Logger(subsystem: "com.continuity.app", category: "ingest")
    /// Stem-separation pipeline logging (subsystem matches the bundle id for easy filtering).
    static let stems = Logger(subsystem: "com.continuity.app", category: "stems")
    /// Playlist source-sync logging.
    static let sync = Logger(subsystem: "com.continuity.app", category: "sync")
}

/// Drives tracks through the M1 ingest pipeline (resolve → download → analyse → ready) and,
/// once playable, the optional M4 stem separation — writing the resulting `prepState` /
/// `localRelativePath` / analysis / stem paths back onto the SwiftData model.
///
/// One `Task` is spawned per `enqueue(_:in:)`, but the heavy network/CPU work is gated by
/// concurrency limiters so importing a whole playlist (`importPlaylist(...)`) doesn't fan out
/// into dozens of simultaneous downloads or stem separations.
///
/// Lives on the main actor because it mutates `@Model` objects bound to the UI's
/// `ModelContext`; the actual networking/DSP happens off-actor inside the awaited calls.
@MainActor
@Observable
public final class PreparationQueue {
    /// Resolves a YouTube video ID to a downloadable audio stream.
    let resolver: AudioStreamResolving
    /// Resolves a YouTube playlist ID to its constituent videos.
    let playlistResolver: PlaylistResolving
    /// Resolves a Spotify playlist/album to its tracklist (metadata only).
    let spotifyResolver: SpotifyPlaylistResolving
    /// Finds a YouTube video for a Spotify-sourced track (title + artist → video ID).
    let searcher: YouTubeSearching
    /// Resolves a video's real title/channel (replaces bare-ID placeholders).
    let metadataResolver: VideoMetadataResolving
    /// Downloads a resolved stream into the on-disk audio cache.
    let downloader: AudioFileDownloading

    /// Caps simultaneous resolve+download+analyse work (network-bound).
    private let ingestLimiter = ConcurrencyLimiter(limit: 3)
    /// Caps simultaneous stem separations to one — each is CPU/RAM-heavy, so they queue.
    let stemLimiter = ConcurrencyLimiter(limit: 1)

    /// Production wiring — the app constructs the queue with no arguments. The parameterized
    /// initializer stays internal for dependency-injected tests within the module.
    public convenience init() { self.init(resolver: YouTubeStreamResolver()) }

    init(
        resolver: AudioStreamResolving = YouTubeStreamResolver(),
        playlistResolver: PlaylistResolving = YouTubePlaylistResolver(),
        spotifyResolver: SpotifyPlaylistResolving = SpotifyPlaylistResolver(),
        searcher: YouTubeSearching = YouTubeSearchResolver(),
        metadataResolver: VideoMetadataResolving = YouTubeOEmbedResolver(),
        downloader: AudioFileDownloading = AudioDownloader()
    ) {
        self.resolver = resolver
        self.playlistResolver = playlistResolver
        self.spotifyResolver = spotifyResolver
        self.searcher = searcher
        self.metadataResolver = metadataResolver
        self.downloader = downloader
    }

    /// Marks `track` as `.pending` and kicks off its preparation in the background.
    ///
    /// Safe to call from the UI: it persists the pending state immediately so the row's
    /// badge updates, then detaches the resolve/download work into its own `Task`.
    public func enqueue(_ track: Track, in context: ModelContext) {
        track.prepState = .pending
        try? context.save()
        Task { await process(track, in: context) }
    }

    /// Resumes preparation for a persisted library at launch: re-enqueues tracks that were
    /// interrupted mid-ingest (e.g. the app was killed partway through a large import) or whose
    /// downloaded audio went missing, and finishes stem separation for tracks that have audio but
    /// no stems yet. `.failed` tracks are left as-is for an explicit retry.
    public func resumePreparation(in context: ModelContext) {
        guard let tracks = try? context.fetch(FetchDescriptor<Track>()) else { return }
        for track in tracks {
            // Demo tracks have no source and play synthesized audio — there is nothing to ingest
            // or resume. Without this guard they'd be re-enqueued (they have no audio file), fail
            // for lack of a source, and show up as retry-able failures. Heal any that already did.
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
                    enqueue(track, in: context)          // file lost/evicted → re-fetch end to end
                } else {
                    // Stems are demand-driven from the play queue (`ensureStems`) — never
                    // separated library-wide at launch. Just true-up links vs the disk.
                    reconcileStemLinks(track, in: context)
                    backfillTrackDetails(track, in: context)
                }
            case .pending, .preparing:
                enqueue(track, in: context)              // interrupted before finishing → pick back up
            case .failed:
                break
            }
        }
    }

    // MARK: - Source sync

    /// Playlists currently syncing (drives spinners and disables sync buttons).
    public internal(set) var syncingPlaylistIDs: Set<UUID> = []

    /// In-memory failure backoff per playlist: `lastSyncedAt` only advances on success, so
    /// without this a persistently-failing source (deleted remotely, sustained rate limit)
    /// would re-fetch on every minute tick forever. Exponential, capped; cleared by the next
    /// success. Manual sync deliberately bypasses it.
    var syncBackoff: [UUID: (notBefore: Date, failures: Int)] = [:]

    /// Coordination hook: sync deletes tracks removed remotely, and the live `Player` must drop
    /// them from its queue BEFORE the models die. Wired to `Player.handleDeleted` at startup.
    public var onTracksDeleted: ((Set<UUID>) -> Void)?

    /// Coordination hook: fires after a sync actually changed a playlist's membership/order,
    /// with the playlist's id and its fresh play order — the app mirrors it into the live
    /// queue. Never fires for no-op syncs. Wired in RootView at startup.
    public var onPlaylistSynced: ((UUID, [Track]) -> Void)?

    /// How stale a playlist may get before an auto-sync pass refreshes it. Sync is **polling**
    /// (a foreground minute tick + manual): push would need server infrastructure neither
    /// YouTube nor Spotify offers a client-only app. Near-live mirroring, so one tick period —
    /// minus fetch latency: `lastSyncedAt` stamps at fetch *completion*, and a full 60s
    /// threshold would make every other tick read "fresh" (120s effective cadence).
    static let autoSyncStaleness: TimeInterval = 55

    /// Runs the resolve → download → analyse → ready pipeline for one track, updating `prepState`
    /// at each stage. Any failure (missing video ID, resolve, or download error) lands the
    /// track in `.failed`; the UI surfaces that as a retry-able badge rather than a crash.
    private func process(_ track: Track, in context: ModelContext) async {
        track.prepState = .preparing
        try? context.save()

        // A track needs either a direct video ID (YouTube) or a search query (Spotify-sourced).
        guard track.youtubeVideoID != nil || track.searchQuery != nil else {
            track.prepState = .failed
            try? context.save()
            return
        }

        // Gate the network/CPU-heavy stage so a playlist import doesn't run all tracks at once.
        await ingestLimiter.acquire()
        var prepared = false
        do {
            // Resolve the video ID: use the known one, or find it on YouTube from the search query.
            let id: String
            if let known = track.youtubeVideoID {
                id = known
            } else if let query = track.searchQuery, let found = try await searcher.firstVideoID(query: query) {
                id = found
                if track.modelContext != nil { track.youtubeVideoID = found }
            } else {
                throw IngestError.noPlayableStream
            }

            let resolved = try await resolver.resolveAudio(videoID: id)
            let fileURL = try await downloader.downloadAudio(resolved)
            // The track could have been deleted while we were off the main actor; don't write to
            // (or resurrect) a dead model.
            if track.modelContext != nil {
                track.localRelativePath = AudioCache.relativePath(for: fileURL)

                // Real duration for the row (bare-ID adds start at 0, which renders as "0:00").
                if track.durationSeconds <= 0, let file = try? AVAudioFile(forReading: fileURL) {
                    track.durationSeconds = Double(file.length) / file.processingFormat.sampleRate
                }

                // NOTE: the real title/channel (oEmbed) is deliberately NOT fetched here — it
                // would block readiness and hold an ingest slot on a slow endpoint even though
                // the audio is already playable. It runs post-ready via backfillTrackDetails.

                // Analyse tempo + key off the main actor (full-track FFTs). Non-fatal: if analysis
                // fails the track still plays, just without BPM/key metadata.
                if let analysis = try? await Task.detached(priority: .utility, operation: {
                    try TrackAnalyzer.analyze(fileURL: fileURL)
                }).value, track.modelContext != nil {
                    track.bpm = analysis.bpm > 0 ? analysis.bpm : nil
                    track.beatTimes = analysis.beatTimes
                    track.keyName = analysis.key?.displayName
                    track.camelotCode = analysis.camelot?.code
                    track.loudnessLUFS = analysis.lufs
                    track.analysisVersion = TrackAnalyzer.analysisVersion
                }
                prepared = true
            }
        } catch {
            // Keep the Error — stems/sync already log failures; ingest was silent and left
            // `.failed` badges with nothing to diagnose in Console.
            let label = track.youtubeVideoID ?? track.searchQuery ?? track.title
            Logger.ingest.error(
                "prep failed for \(label, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            prepared = false
        }
        await ingestLimiter.release()

        // Don't touch a track that was deleted while we worked.
        if track.modelContext != nil {
            track.prepState = prepared ? .ready : .failed
        }
        try? context.save()

        // Display metadata is an optional enhancement — start it in the background AFTER the
        // track is playable. Stems are NOT separated here: separation is demand-driven from the
        // play queue (`ensureStems`) — eagerly separating whole imports burned CPU-hours and
        // filled disks. Already-cached stems (re-adds) are linked instantly, though.
        if track.modelContext != nil, track.prepState == .ready {
            reconcileStemLinks(track, in: context)
            backfillTrackDetails(track, in: context)
        }
    }

    /// Whether the track still shows the "YouTube Video (abc123)" placeholder from a bare-ID add.
    private static func hasPlaceholderMetadata(_ track: Track) -> Bool {
        track.youtubeVideoID != nil && track.title.hasPrefix("YouTube Video (")
    }

    /// Best-effort, fire-and-forget healing of a ready track's display details:
    /// - `durationSeconds` from the local audio file when the model still says 0 ("0:00" rows),
    /// - audible bounds for gapless transitions,
    /// - real title/channel via oEmbed when the bare-ID placeholder is still showing,
    /// - re-analysis when `TrackAnalyzer.analysisVersion` has moved.
    ///
    /// Runs post-`.ready` (never blocks playability) from both the ingest pipeline and
    /// `resumePreparation`. Every heavy step is gated by `ingestLimiter` so a large library's
    /// launch backfill can't fan out into dozens of simultaneous file opens / PCM decodes /
    /// oEmbed requests (which hitch launch and thrash memory).
    private func backfillTrackDetails(_ track: Track, in context: ModelContext) {
        let needsTitle = Self.hasPlaceholderMetadata(track)
        let needsDuration = track.durationSeconds <= 0 && track.localRelativePath != nil
        let needsSilenceScan = track.audibleEndSeconds == nil && track.localRelativePath != nil
        let needsReanalysis = track.localRelativePath != nil
            && (track.analysisVersion ?? 0) < TrackAnalyzer.analysisVersion
        guard needsTitle || needsDuration || needsSilenceScan || needsReanalysis else { return }

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
            if needsTitle, let id = track.youtubeVideoID {
                await ingestLimiter.acquire()
                let meta = try? await metadataResolver.metadata(videoID: id)
                await ingestLimiter.release()
                if let meta, track.modelContext != nil {
                    track.title = meta.title
                    if let author = meta.author, !author.isEmpty { track.artist = author }
                }
            }
            guard track.modelContext != nil else { return }
            try? context.save()
        }
    }

    // MARK: Stems (demand-driven)

    /// Stem keys for the current play-queue neighborhood — protected from cache eviction.
    var protectedStemKeys: Set<String> = []
    /// Stem keys (YouTube video IDs) whose separation is currently running. Keyed like the
    /// cache — by video, not Track row — so the same video in two playlists can't run two
    /// concurrent separations that rewrite the same output files.
    var stemsInFlight: Set<String> = []
    /// Separation is held until this moment — armed on the session's FIRST stem demand
    /// (i.e. when playback starts). Pressing play spins up the audio engine, UI, artwork, and
    /// (first run) the model download all at once; the ORT session-load + first-window peak is
    /// the app's largest allocation and must not stack on that ramp.
    var separationAllowedAt: Date?
    /// At most one pending post-hold retry (ensureStems also re-fires on every track change).
    var stemsRetryScheduled = false


}
