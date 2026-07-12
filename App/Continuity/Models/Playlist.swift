import Foundation
import SwiftData

/// Where an imported playlist's tracklist lives remotely, for re-fetching on sync.
enum PlaylistSource: String, Codable, Sendable {
    case youtube
    case spotifyPlaylist
    case spotifyAlbum
}

/// A playlist or album. For M0 both concepts are represented by this one model; the
/// library surfaces them as a simple grid of cards.
@Model
final class Playlist {
    var id: UUID
    var title: String
    var subtitle: String
    var artworkSymbol: String
    var gradientSeed: Int
    var createdAt: Date

    // MARK: Source sync (playlists imported from YouTube/Spotify)
    /// The remote service this playlist mirrors; nil for local/demo playlists.
    private var sourceKindRaw: String?
    /// The remote playlist/album ID at `sourceKind`.
    var sourceID: String?
    /// Opt-out: source-backed playlists refresh from the remote automatically unless disabled.
    var autoSyncEnabled: Bool = true
    /// When this playlist last successfully synced with its source.
    var lastSyncedAt: Date?

    var sourceKind: PlaylistSource? {
        get { sourceKindRaw.flatMap(PlaylistSource.init(rawValue:)) }
        set { sourceKindRaw = newValue?.rawValue }
    }
    /// Whether this playlist can be re-fetched from a remote source (and thus synced).
    var isSourceBacked: Bool { sourceKind != nil && sourceID != nil }

    /// Owning side of the relationship; deleting a playlist deletes its tracks.
    @Relationship(deleteRule: .cascade, inverse: \Track.playlist)
    var tracks: [Track]

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        artworkSymbol: String = "music.note.list",
        gradientSeed: Int,
        createdAt: Date = Date(),
        tracks: [Track] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkSymbol = artworkSymbol
        self.gradientSeed = gradientSeed
        self.createdAt = createdAt
        self.tracks = tracks
    }

    /// Tracks in playback order.
    var orderedTracks: [Track] {
        tracks.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// True when every track is a synthesized demo (the seeded sample albums).
    var isDemo: Bool { !tracks.isEmpty && tracks.allSatisfy(\.isDemo) }

    /// Cover art for the playlist card: the first track that has real artwork.
    var artworkURL: URL? {
        orderedTracks.lazy.compactMap(\.artworkURL).first
    }
}
