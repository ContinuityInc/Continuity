import AVFoundation
import Foundation
import SwiftData
import ContinuityCore
import os

extension Logger {
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
final class PreparationQueue {
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
    private let stemLimiter = ConcurrencyLimiter(limit: 1)

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
    func enqueue(_ track: Track, in context: ModelContext) {
        track.prepState = .pending
        try? context.save()
        Task { await process(track, in: context) }
    }

    /// Resumes preparation for a persisted library at launch: re-enqueues tracks that were
    /// interrupted mid-ingest (e.g. the app was killed partway through a large import) or whose
    /// downloaded audio went missing, and finishes stem separation for tracks that have audio but
    /// no stems yet. `.failed` tracks are left as-is for an explicit retry.
    func resumePreparation(in context: ModelContext) {
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

    /// Resolves a YouTube playlist, creates a matching library `Playlist` with one placeholder
    /// `Track` per video, and enqueues every track for ingestion. The page fetch runs off the
    /// main actor inside the awaited resolver; the model writes happen here on the main actor.
    ///
    /// Throws if the playlist can't be resolved (private/empty/unavailable or a YouTube change),
    /// so the caller can surface an inline error. Returns the created playlist on success.
    @discardableResult
    func importPlaylist(playlistID: String, fallbackTitle: String? = nil, in context: ModelContext) async throws -> Playlist {
        let resolved = try await playlistResolver.resolvePlaylist(playlistID: playlistID)

        let title = resolved.title?.isEmpty == false ? resolved.title! : (fallbackTitle ?? "YouTube Playlist")
        // Deterministic-ish gradient seed from the playlist ID so the card has a stable colour.
        let seed = resolved.playlistID.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 90 + 10

        let playlist = Playlist(
            title: title,
            subtitle: "From YouTube · \(resolved.items.count) tracks",
            artworkSymbol: "music.note.list",
            gradientSeed: seed
        )
        playlist.sourceKind = .youtube
        playlist.sourceID = resolved.playlistID
        playlist.lastSyncedAt = Date()
        context.insert(playlist)

        for (index, item) in resolved.items.enumerated() {
            let track = Track(
                title: item.title ?? "YouTube Video (\(item.videoID.prefix(6)))",
                artist: item.author ?? "YouTube",
                durationSeconds: Double(item.lengthSeconds ?? 0),
                artworkSymbol: playlist.artworkSymbol,
                gradientSeed: seed * 100 + index,
                sortIndex: index,
                prepState: .pending,
                youtubeVideoID: item.videoID,
                sourceURLString: "https://www.youtube.com/watch?v=\(item.videoID)"
            )
            playlist.tracks.append(track)
            context.insert(track)
            enqueue(track, in: context)
        }
        try? context.save()
        return playlist
    }

    /// Imports a Spotify playlist/album: resolves its tracklist (metadata only — Spotify audio is
    /// DRM-protected and unusable by our engine), creates a matching library `Playlist`, and
    /// enqueues one `Track` per song. Each track carries a `searchQuery` instead of a video ID;
    /// the ingest pipeline resolves that to real YouTube audio (see `process`).
    ///
    /// Throws if the playlist can't be resolved so the caller can surface an inline error.
    @discardableResult
    func importSpotifyPlaylist(_ link: SpotifyLink, in context: ModelContext) async throws -> Playlist {
        let resolved = try await spotifyResolver.resolvePlaylist(link)

        let title = resolved.name?.isEmpty == false ? resolved.name! : "Spotify \(link.kind.rawValue.capitalized)"
        let seed = link.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 90 + 10

        let playlist = Playlist(
            title: title,
            subtitle: "From Spotify · \(resolved.tracks.count) tracks",
            artworkSymbol: "music.note.list",
            gradientSeed: seed
        )
        playlist.sourceKind = link.kind == .album ? .spotifyAlbum : .spotifyPlaylist
        playlist.sourceID = link.id
        playlist.lastSyncedAt = Date()
        context.insert(playlist)

        for (index, spotifyTrack) in resolved.tracks.enumerated() {
            let track = Track(
                title: spotifyTrack.title,
                artist: spotifyTrack.artist ?? "Unknown Artist",
                durationSeconds: Double(spotifyTrack.durationSeconds ?? 0),
                artworkSymbol: playlist.artworkSymbol,
                gradientSeed: seed * 100 + index,
                sortIndex: index,
                prepState: .pending,
                // No video ID yet — the pipeline finds the audio on YouTube from this query.
                searchQuery: spotifyTrack.youtubeSearchQuery
            )
            playlist.tracks.append(track)
            context.insert(track)
            enqueue(track, in: context)
        }
        try? context.save()
        return playlist
    }

    // MARK: - Source sync

    /// Playlists currently syncing (drives spinners and disables sync buttons).
    private(set) var syncingPlaylistIDs: Set<UUID> = []

    /// Coordination hook: sync deletes tracks removed remotely, and the live `Player` must drop
    /// them from its queue BEFORE the models die. Wired to `Player.handleDeleted` at startup.
    var onTracksDeleted: ((Set<UUID>) -> Void)?

    /// How stale a playlist may get before launch-time auto-sync refreshes it. Sync is **polling**
    /// (at launch + manual): push would need server infrastructure neither YouTube nor Spotify
    /// offers a client-only app.
    private static let autoSyncStaleness: TimeInterval = 6 * 60 * 60

    /// Launch-time polling pass: refreshes each source-backed playlist that has auto-sync on
    /// (the opt-out) and hasn't synced recently.
    func autoSyncIfNeeded(in context: ModelContext) {
        guard let playlists = try? context.fetch(FetchDescriptor<Playlist>()) else { return }
        for playlist in playlists where playlist.isSourceBacked && playlist.autoSyncEnabled {
            let stale = playlist.lastSyncedAt.map {
                Date().timeIntervalSince($0) > Self.autoSyncStaleness
            } ?? true
            if stale {
                Task { await syncPlaylist(playlist, in: context) }
            }
        }
    }

    /// Manual "sync everything now" — ignores staleness but still skips in-flight playlists.
    func syncAll(in context: ModelContext) {
        guard let playlists = try? context.fetch(FetchDescriptor<Playlist>()) else { return }
        for playlist in playlists where playlist.isSourceBacked {
            Task { await syncPlaylist(playlist, in: context) }
        }
    }

    /// Mirrors one playlist against its remote source: tracks added remotely are created (and
    /// ingested), tracks removed remotely are deleted locally (Player-coordinated, files cleaned
    /// share-aware), and local ordering follows the remote. Best-effort: a resolve failure leaves
    /// the local playlist untouched.
    func syncPlaylist(_ playlist: Playlist, in context: ModelContext) async {
        guard playlist.isSourceBacked, let sourceID = playlist.sourceID, let kind = playlist.sourceKind,
              !syncingPlaylistIDs.contains(playlist.id) else { return }
        syncingPlaylistIDs.insert(playlist.id)
        defer { syncingPlaylistIDs.remove(playlist.id) }

        do {
            switch kind {
            case .youtube:
                let resolved = try await playlistResolver.resolvePlaylist(playlistID: sourceID)
                guard playlist.modelContext != nil, !resolved.items.isEmpty else { return }
                applyYouTubeSync(resolved.items, to: playlist, in: context)
            case .spotifyPlaylist, .spotifyAlbum:
                let link = SpotifyLink(kind: kind == .spotifyAlbum ? .album : .playlist, id: sourceID)
                let resolved = try await spotifyResolver.resolvePlaylist(link)
                guard playlist.modelContext != nil, !resolved.tracks.isEmpty else { return }
                applySpotifySync(resolved.tracks, to: playlist, in: context)
            }
            playlist.lastSyncedAt = Date()
            try? context.save()
            Logger.sync.info("synced \(playlist.title, privacy: .public)")
        } catch {
            // The local playlist is never modified on a failed fetch; next sync retries.
            Logger.sync.error("sync failed for \(playlist.title, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Applies a fresh remote YouTube tracklist: key = video ID.
    private func applyYouTubeSync(_ remote: [YouTubePlaylistItem], to playlist: Playlist, in context: ModelContext) {
        var localByKey: [String: Track] = [:]
        for track in playlist.tracks {
            if let id = track.youtubeVideoID { localByKey[id] = track }
        }

        let remoteKeys = Set(remote.map(\.videoID))
        removeTracks(playlist.tracks.filter { track in
            guard let id = track.youtubeVideoID else { return false }
            return !remoteKeys.contains(id)
        }, in: context)

        let seed = playlist.gradientSeed
        for (index, item) in remote.enumerated() {
            if let existing = localByKey[item.videoID] {
                existing.sortIndex = index      // follow remote ordering
            } else {
                let track = Track(
                    title: item.title ?? "YouTube Video (\(item.videoID.prefix(6)))",
                    artist: item.author ?? "YouTube",
                    durationSeconds: Double(item.lengthSeconds ?? 0),
                    artworkSymbol: playlist.artworkSymbol,
                    gradientSeed: seed * 100 + index,
                    sortIndex: index,
                    prepState: .pending,
                    youtubeVideoID: item.videoID,
                    sourceURLString: "https://www.youtube.com/watch?v=\(item.videoID)"
                )
                playlist.tracks.append(track)
                context.insert(track)
                enqueue(track, in: context)
            }
        }
        playlist.subtitle = "From YouTube · \(remote.count) tracks"
    }

    /// Applies a fresh remote Spotify tracklist: key = the YouTube search query (title + artist),
    /// the identity Spotify-sourced tracks carry locally.
    private func applySpotifySync(_ remote: [SpotifyTrack], to playlist: Playlist, in context: ModelContext) {
        var localByKey: [String: Track] = [:]
        for track in playlist.tracks {
            if let query = track.searchQuery { localByKey[query] = track }
        }

        let remoteKeys = Set(remote.map(\.youtubeSearchQuery))
        removeTracks(playlist.tracks.filter { track in
            guard let query = track.searchQuery else { return false }
            return !remoteKeys.contains(query)
        }, in: context)

        let seed = playlist.gradientSeed
        for (index, item) in remote.enumerated() {
            if let existing = localByKey[item.youtubeSearchQuery] {
                existing.sortIndex = index
            } else {
                let track = Track(
                    title: item.title,
                    artist: item.artist ?? "Unknown Artist",
                    durationSeconds: Double(item.durationSeconds ?? 0),
                    artworkSymbol: playlist.artworkSymbol,
                    gradientSeed: seed * 100 + index,
                    sortIndex: index,
                    prepState: .pending,
                    searchQuery: item.youtubeSearchQuery
                )
                playlist.tracks.append(track)
                context.insert(track)
                enqueue(track, in: context)
            }
        }
        playlist.subtitle = "From Spotify · \(remote.count) tracks"
    }

    /// Deletes tracks the same way the UI does: Player first (so the live queue never holds a
    /// dead model), then the models, then share-aware file cleanup.
    private func removeTracks(_ tracks: [Track], in context: ModelContext) {
        guard !tracks.isEmpty else { return }
        onTracksDeleted?(Set(tracks.map(\.id)))
        let videoIDs = tracks.compactMap(\.youtubeVideoID)
        for track in tracks { context.delete(track) }
        LibraryCleanup.removeOrphanedFiles(videoIDs: videoIDs, in: context)
    }

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
    /// - real title/channel via oEmbed when the bare-ID placeholder is still showing.
    ///
    /// Runs post-`.ready` (never blocks playability) from both the ingest pipeline and
    /// `resumePreparation`. The network lookup is gated by `ingestLimiter` so a large library's
    /// launch backfill can't burst dozens of simultaneous oEmbed requests (which would get
    /// throttled and silently fail).
    private func backfillTrackDetails(_ track: Track, in context: ModelContext) {
        let needsTitle = Self.hasPlaceholderMetadata(track)
        let needsDuration = track.durationSeconds <= 0 && track.localRelativePath != nil
        let needsSilenceScan = track.audibleEndSeconds == nil && track.localRelativePath != nil
        let needsReanalysis = track.localRelativePath != nil
            && (track.analysisVersion ?? 0) < TrackAnalyzer.analysisVersion
        guard needsTitle || needsDuration || needsSilenceScan || needsReanalysis else { return }

        Task {
            guard track.modelContext != nil else { return }
            if needsDuration, let relativePath = track.localRelativePath,
               let file = try? AVAudioFile(forReading: AudioCache.url(forRelativePath: relativePath)) {
                track.durationSeconds = Double(file.length) / file.processingFormat.sampleRate
            }
            // Audible bounds for gapless transitions (targeted head/tail decode, off the main
            // actor — it reads ~20 MB of PCM).
            if needsSilenceScan, let relativePath = track.localRelativePath {
                let url = AudioCache.url(forRelativePath: relativePath)
                let bounds = await Task.detached(priority: .utility) {
                    SilenceScan.audibleBounds(fileURL: url)
                }.value
                if let bounds, track.modelContext != nil {
                    track.audibleStartSeconds = bounds.audibleStart
                    track.audibleEndSeconds = bounds.audibleEnd
                }
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
    private var protectedStemKeys: Set<String> = []
    /// Tracks whose separation is currently running (dedup across repeated `ensureStems` calls).
    private var stemsInFlight: Set<UUID> = []

    /// Demand-driven stem preparation for the tracks around the play position (called on every
    /// track change). Separation costs CPU-minutes and cache bytes per track, so the library is
    /// **never** separated eagerly — only the neighborhood vocal-aware transitions need next.
    /// Also refreshes the LRU clock and heals links whose files were evicted.
    func ensureStems(for tracks: [Track], in context: ModelContext) {
        protectedStemKeys = Set(tracks.compactMap(\.youtubeVideoID))
        for track in tracks {
            guard !track.isDemo, track.prepState == .ready,
                  let key = track.youtubeVideoID, track.localRelativePath != nil else { continue }
            reconcileStemLinks(track, in: context)
            if track.hasStems {
                StemCache.markUsed(key: key)   // actively played material stays cache-resident
            } else {
                separateStems(track, in: context)
            }
        }
        // Budget pass on every queue move (not just post-separation): catches overage that
        // accrued outside this code path — e.g. gigabytes of legacy float32 stems.
        let protected = protectedStemKeys
        Task.detached(priority: .utility) {
            StemCache.enforceBudget(protecting: protected)
        }
    }

    /// Brings a track's stem links in line with the disk: links cached stems that exist unlinked
    /// (e.g. a re-added video), clears links whose files were evicted so `hasStems` tells the
    /// truth and the track becomes eligible for re-separation.
    private func reconcileStemLinks(_ track: Track, in context: ModelContext) {
        guard let key = track.youtubeVideoID else { return }
        if let v = track.vocalsRelativePath, let a = track.accompanimentRelativePath,
           FileManager.default.fileExists(atPath: StemCache.url(forRelativePath: v).path),
           FileManager.default.fileExists(atPath: StemCache.url(forRelativePath: a).path) {
            return   // linked and present — nothing to do
        }
        if let v = StemCache.stemFile(key: key, kind: "vocals"),
           let a = StemCache.stemFile(key: key, kind: "accompaniment") {
            track.vocalsRelativePath = StemCache.relativePath(for: v)
            track.accompanimentRelativePath = StemCache.relativePath(for: a)
            try? context.save()
        } else if track.hasStems {
            track.vocalsRelativePath = nil
            track.accompanimentRelativePath = nil
            try? context.save()
        }
    }

    /// Separates the track into vocals + accompaniment stems (very slow, off the main actor),
    /// caching them and pointing the track at them. Best-effort: failure just means no vocal-aware
    /// transition for this track. Serialised via `stemLimiter`; after each separation the cache's
    /// byte budget is enforced (LRU eviction, protecting the play-queue neighborhood).
    private func separateStems(_ track: Track, in context: ModelContext) {
        guard let key = track.youtubeVideoID, let relativePath = track.localRelativePath,
              !stemsInFlight.contains(track.id) else { return }
        stemsInFlight.insert(track.id)

        let inputURL = AudioCache.url(forRelativePath: relativePath)
        let vocalsOut = StemCache.vocalsURL(key: key)
        let accompanimentOut = StemCache.accompanimentURL(key: key)
        let limiter = stemLimiter

        Task.detached(priority: .utility) { [weak self] in
            await limiter.acquire()
            do {
                let modelURL = try await StemModelStore.ensureModel()
                let separator = OnnxStemSeparator(modelURL: modelURL)
                _ = try separator.separate(inputURL: inputURL, vocalsOut: vocalsOut, accompanimentOut: accompanimentOut)
                await MainActor.run {
                    guard track.modelContext != nil else { return }
                    track.vocalsRelativePath = StemCache.relativePath(for: vocalsOut)
                    track.accompanimentRelativePath = StemCache.relativePath(for: accompanimentOut)
                    try? context.save()
                }
                Logger.stems.info("separated stems for \(key, privacy: .public)")
            } catch {
                // Best-effort — the track still plays without stems — but never silently: a broken
                // separator would otherwise look like "stems just never finish".
                Logger.stems.error("stem separation failed for \(key, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            await limiter.release()

            // Budget pass after every separation. Never evict the active neighborhood or the
            // key we just wrote (it may not be in the protected set if the queue moved on).
            let protected = await MainActor.run { self?.protectedStemKeys ?? [] }
            StemCache.enforceBudget(protecting: protected.union([key]))
            await MainActor.run { _ = self?.stemsInFlight.remove(track.id) }
        }
    }
}
