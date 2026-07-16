import Foundation
import SwiftData

/// Where an imported playlist's tracklist lives remotely, for re-fetching on sync.
public enum PlaylistSource: String, Codable, Sendable {
    case youtube
    case spotifyPlaylist
    case spotifyAlbum
}

/// A playlist or album. For M0 both concepts are represented by this one model; the
/// library surfaces them as a simple grid of cards.
@Model
public final class Playlist {
    public var id: UUID
    public var title: String
    public var subtitle: String
    public var artworkSymbol: String
    public var gradientSeed: Int
    public var createdAt: Date
    /// When the playlist's contents last changed; nil for rows created before this field existed.
    public var updatedAt: Date?

    // MARK: Source sync (playlists imported from YouTube/Spotify)
    /// The remote service this playlist mirrors; nil for local/demo playlists.
    private var sourceKindRaw: String?
    /// The remote playlist/album ID at `sourceKind`.
    public var sourceID: String?
    /// Opt-out: source-backed playlists refresh from the remote automatically unless disabled.
    public var autoSyncEnabled: Bool = true
    /// When this playlist last successfully synced with its source.
    public var lastSyncedAt: Date?

    public var sourceKind: PlaylistSource? {
        get { sourceKindRaw.flatMap(PlaylistSource.init(rawValue:)) }
        set { sourceKindRaw = newValue?.rawValue }
    }
    /// Whether this playlist can be re-fetched from a remote source (and thus synced).
    public var isSourceBacked: Bool { sourceKind != nil && sourceID != nil }

    /// Owning side of the relationship; deleting a playlist deletes its tracks.
    @Relationship(deleteRule: .cascade, inverse: \Track.playlist)
    public var tracks: [Track]

    public init(
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

    /// Stamps a content change (tracks added/removed/reordered) so the library can sort by recency.
    public func touch() { updatedAt = Date() }

    /// Tracks in playback order.
    public var orderedTracks: [Track] {
        tracks.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// True when every track is a synthesized demo (the seeded sample albums).
    public var isDemo: Bool { !tracks.isEmpty && tracks.allSatisfy(\.isDemo) }

    /// Cover art for the playlist card: the first track that has real artwork.
    public var artworkURL: URL? {
        orderedTracks.lazy.compactMap(\.artworkURL).first
    }
}
