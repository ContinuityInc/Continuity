import AVFoundation
import Foundation
import SwiftData
import ContinuityCore
import os

extension Logger {
    /// Stem-separation pipeline logging (subsystem matches the bundle id for easy filtering).
    static let stems = Logger(subsystem: "com.continuity.app", category: "stems")
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
                    if !track.hasStems {
                        separateStems(track, in: context) // audio is fine; finish the optional stems
                    }
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

        // Stems and display metadata are optional enhancements — start them in the background
        // AFTER the track is playable. The track plays meanwhile.
        if track.modelContext != nil, track.prepState == .ready {
            separateStems(track, in: context)
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
        guard needsTitle || needsDuration else { return }

        Task {
            guard track.modelContext != nil else { return }
            if needsDuration, let relativePath = track.localRelativePath,
               let file = try? AVAudioFile(forReading: AudioCache.url(forRelativePath: relativePath)) {
                track.durationSeconds = Double(file.length) / file.processingFormat.sampleRate
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

    /// Separates the track into vocals + accompaniment stems (very slow, off the main actor),
    /// caching them and pointing the track at them. Best-effort: failure just means no vocal-aware
    /// transition for this track. Serialised via `stemLimiter` so a playlist's tracks separate one
    /// at a time rather than thrashing CPU/RAM.
    private func separateStems(_ track: Track, in context: ModelContext) {
        guard let key = track.youtubeVideoID, let relativePath = track.localRelativePath else { return }

        // Already separated (e.g. a re-add) — just link the track to the cached stems.
        if StemCache.hasStems(key: key) {
            track.vocalsRelativePath = StemCache.relativePath(for: StemCache.vocalsURL(key: key))
            track.accompanimentRelativePath = StemCache.relativePath(for: StemCache.accompanimentURL(key: key))
            try? context.save()
            return
        }

        let inputURL = AudioCache.url(forRelativePath: relativePath)
        let vocalsOut = StemCache.vocalsURL(key: key)
        let accompanimentOut = StemCache.accompanimentURL(key: key)
        let limiter = stemLimiter

        Task.detached(priority: .utility) {
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
        }
    }
}
