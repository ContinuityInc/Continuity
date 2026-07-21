import Foundation

/// A song we know only by its metadata, because its own service won't give us audio — Spotify
/// and Apple Music are both DRM-locked. The pipeline re-sources the recording from YouTube via
/// `youtubeSearchQuery`, which is therefore also the track's local identity for playlist sync.
public protocol MetadataSourcedTrack: Sendable {
    var title: String { get }
    var artist: String? { get }
    var durationSeconds: Int? { get }
    var youtubeSearchQuery: String { get }
}

extension SpotifyTrack: MetadataSourcedTrack {}
extension AppleMusicTrack: MetadataSourcedTrack {}
