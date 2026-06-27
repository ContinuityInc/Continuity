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
    /// The YouTube video ID this track was ingested from.
    var youtubeVideoID: String?
    /// The original URL the user supplied.
    var sourceURLString: String?
    /// Path, relative to the audio cache directory, of the downloaded/decoded file once `.ready`.
    var localRelativePath: String?

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
        self.sourceURLString = sourceURLString
        self.localRelativePath = localRelativePath
    }
}
