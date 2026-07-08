import Foundation
import SwiftData

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
}
