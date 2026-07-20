import Foundation
import SwiftData

/// Where a track is in the ingest/preparation pipeline. In M0 everything is `.ready`
/// (synthesised audio); from M1 on this reflects download → analyse → separate progress
/// and drives the per-track UI badges and transition fallbacks.
public enum PrepState: String, Codable, Sendable {
    case pending, preparing, ready, failed
}

@Model
public final class Track {
    public var id: UUID
    public var title: String
    public var artist: String
    /// Nominal track length in seconds (in M0 the synth loops; this drives the clock + auto-advance).
    public var durationSeconds: Double
    /// SF Symbol used for placeholder artwork until real art exists.
    public var artworkSymbol: String
    /// Seed that deterministically drives both the placeholder gradient and the M0 synth tone.
    public var gradientSeed: Int
    /// Position within its playlist.
    public var sortIndex: Int
    private var prepStateRaw: String

    // MARK: Source (M1) — nil for the M0 synth samples
    /// The YouTube video ID this track was ingested from. For Spotify-sourced tracks this starts
    /// nil and is filled in by a YouTube search (see `searchQuery`) during preparation.
    public var youtubeVideoID: String?
    /// For tracks without a known video ID (e.g. imported from Spotify), the text query used to
    /// find the song on YouTube, e.g. "Blinding Lights The Weeknd".
    public var searchQuery: String?
    /// The original URL the user supplied.
    public var sourceURLString: String?
    /// Path, relative to the audio cache directory, of the downloaded/decoded file once `.ready`.
    public var localRelativePath: String?

    // MARK: Analysis (M3) — populated by TrackAnalyzer after the file is downloaded
    /// Detected tempo in beats per minute.
    public var bpm: Double?
    /// Human-readable detected key (e.g. "C Major").
    public var keyName: String?
    /// Camelot wheel code (e.g. "8B") for harmonic mixing.
    public var camelotCode: String?
    /// Beat onset times (seconds) — the beat grid used for beat-aligned transitions.
    public var beatTimes: [Double] = []
    /// Integrated loudness (LUFS) of the downmixed track, for loudness leveling across blends.
    public var loudnessLUFS: Double?
    /// `TrackAnalyzer.analysisVersion` that produced the fields above; below-current (or nil)
    /// triggers a launch-time re-analysis so analyzer fixes reach existing tracks.
    public var analysisVersion: Int?

    // MARK: Gapless (M5) — audible bounds from the silence scan, nil until scanned
    /// Time (s) of the first audible audio — leading silence ends here.
    public var audibleStartSeconds: Double?
    /// Time (s) just after the last audible audio — trailing silence starts here.
    public var audibleEndSeconds: Double?

    // MARK: Stems (M4) — populated by stem separation after the track is ready
    /// Path (relative to the stem cache) of the isolated-vocals file, once separated.
    public var vocalsRelativePath: String?
    /// Path (relative to the stem cache) of the accompaniment file, once separated.
    public var accompanimentRelativePath: String?
    /// Whether both stems are available for vocal-aware transitions.
    public var hasStems: Bool { vocalsRelativePath != nil && accompanimentRelativePath != nil }

    /// A seeded demo track (no real source) — it plays synthesized tones, not real audio. Used to
    /// label the placeholder sample library so it isn't mistaken for real playback.
    public var isDemo: Bool {
        youtubeVideoID == nil && searchQuery == nil && localRelativePath == nil
    }

    /// Stable key for the stem cache (and other per-source on-disk caches). Legacy
    /// YouTube-sourced tracks keep their video ID (existing stems stay linked); locally
    /// imported tracks use their own UUID.
    public var stemKey: String { youtubeVideoID ?? id.uuidString }

    /// Real cover art for YouTube-sourced tracks: the video's thumbnail, served from YouTube's
    /// deterministic thumbnail CDN (no API call needed). nil for demo tracks → gradient artwork.
    public var artworkURL: URL? {
        youtubeVideoID.flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/hqdefault.jpg") }
    }

    /// Inverse side of the Playlist ↔ Track relationship.
    public var playlist: Playlist?

    public var prepState: PrepState {
        get { PrepState(rawValue: prepStateRaw) ?? .pending }
        set { prepStateRaw = newValue.rawValue }
    }

    public init(
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
