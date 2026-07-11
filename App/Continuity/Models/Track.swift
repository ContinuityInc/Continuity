import Foundation
import SwiftData

/// Where a track is in the ingest/preparation pipeline. In M0 everything is `.ready`
/// (synthesised audio); from M1 on this reflects download → analyse → separate progress
/// and drives the per-track UI badges and transition fallbacks.
enum PrepState: String, Codable, Sendable {
    case pending, preparing, ready, failed
}

@Model
final class Track {
    var id: UUID
    var title: String
    var artist: String
    /// Nominal track length in seconds (in M0 the synth loops; this drives the clock + auto-advance).
    var durationSeconds: Double
    /// SF Symbol used for placeholder artwork until real art exists.
    var artworkSymbol: String
    /// Seed that deterministically drives both the placeholder gradient and the M0 synth tone.
    var gradientSeed: Int
    /// Position within its playlist.
    var sortIndex: Int
    private var prepStateRaw: String

    // MARK: Source (M1) — nil for the M0 synth samples
    /// The YouTube video ID this track was ingested from. For Spotify-sourced tracks this starts
    /// nil and is filled in by a YouTube search (see `searchQuery`) during preparation.
    var youtubeVideoID: String?
    /// For tracks without a known video ID (e.g. imported from Spotify), the text query used to
    /// find the song on YouTube, e.g. "Blinding Lights The Weeknd".
    var searchQuery: String?
    /// The original URL the user supplied.
    var sourceURLString: String?
    /// Path, relative to the audio cache directory, of the downloaded/decoded file once `.ready`.
    var localRelativePath: String?

    // MARK: Analysis (M3) — populated by TrackAnalyzer after the file is downloaded
    /// Detected tempo in beats per minute.
    var bpm: Double?
    /// Human-readable detected key (e.g. "C Major").
    var keyName: String?
    /// Camelot wheel code (e.g. "8B") for harmonic mixing.
    var camelotCode: String?
    /// Beat onset times (seconds) — the beat grid used for beat-aligned transitions.
    var beatTimes: [Double] = []

    // MARK: Stems (M4) — populated by stem separation after the track is ready
    /// Path (relative to the stem cache) of the isolated-vocals file, once separated.
    var vocalsRelativePath: String?
    /// Path (relative to the stem cache) of the accompaniment file, once separated.
    var accompanimentRelativePath: String?
    /// Whether both stems are available for vocal-aware transitions.
    var hasStems: Bool { vocalsRelativePath != nil && accompanimentRelativePath != nil }

    /// A seeded demo track (no real source) — it plays synthesized tones, not real audio. Used to
    /// label the placeholder sample library so it isn't mistaken for real playback.
    var isDemo: Bool { youtubeVideoID == nil && searchQuery == nil }

    /// Inverse side of the Playlist ↔ Track relationship.
    var playlist: Playlist?

    var prepState: PrepState {
        get { PrepState(rawValue: prepStateRaw) ?? .pending }
        set { prepStateRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        durationSeconds: Double,
        artworkSymbol: String = "music.note",
        gradientSeed: Int,
        sortIndex: Int,
        prepState: PrepState = .ready,
        youtubeVideoID: String? = nil,
        searchQuery: String? = nil,
        sourceURLString: String? = nil,
        localRelativePath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.durationSeconds = durationSeconds
        self.artworkSymbol = artworkSymbol
        self.gradientSeed = gradientSeed
        self.sortIndex = sortIndex
        self.prepStateRaw = prepState.rawValue
        self.youtubeVideoID = youtubeVideoID
        self.searchQuery = searchQuery
        self.sourceURLString = sourceURLString
        self.localRelativePath = localRelativePath
    }
}
