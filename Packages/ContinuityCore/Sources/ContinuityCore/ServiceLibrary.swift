import Foundation

/// A streaming service the user can sign in to. Apple Music is deliberately not here — it's a
/// MediaPlayer permission, not an OAuth account, and lives behind `AppleMusicLibraryReading`.
public enum MusicService: String, CaseIterable, Codable, Sendable, Identifiable {
    case spotify
    case youtube
    case soundcloud

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .youtube: return "YouTube"
        case .soundcloud: return "SoundCloud"
        }
    }
}

/// One playlist/album/likes collection listed from a connected account, before import.
public struct ServicePlaylistSummary: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case playlist
        case album
        /// The account's saved/liked tracks — a virtual playlist the API exposes separately.
        case likes
    }

    public var service: MusicService
    /// Service-native identifier: Spotify base-62 id, YouTube playlist id, SoundCloud `urn`
    /// (`soundcloud:playlists:123`). For `.likes` it's a fixed sentinel per service.
    public var sourceID: String
    public var kind: Kind
    public var name: String
    public var ownerName: String?
    public var trackCount: Int?

    public var id: String { "\(service.rawValue):\(kind.rawValue):\(sourceID)" }

    public init(service: MusicService, sourceID: String, kind: Kind, name: String, ownerName: String? = nil, trackCount: Int? = nil) {
        self.service = service
        self.sourceID = sourceID
        self.kind = kind
        self.name = name
        self.ownerName = ownerName
        self.trackCount = trackCount
    }
}

/// A track from a connected account, normalised across services. YouTube items carry their
/// video id and ingest directly; everything else is metadata that the pipeline re-sources from
/// YouTube by `youtubeSearchQuery` (the same identity Spotify/Apple Music imports use for sync).
public struct ServiceTrack: Equatable, Sendable, MetadataSourcedTrack {
    public var title: String
    public var artist: String?
    public var durationSeconds: Int?
    public var youtubeVideoID: String?
    public var youtubeSearchQuery: String

    public init(title: String, artist: String? = nil, durationSeconds: Int? = nil, youtubeVideoID: String? = nil, youtubeSearchQuery: String? = nil) {
        self.title = title
        self.artist = artist
        self.durationSeconds = durationSeconds
        self.youtubeVideoID = youtubeVideoID
        self.youtubeSearchQuery = youtubeSearchQuery ?? [title, artist].compactMap { $0 }.joined(separator: " ")
    }

    public init(_ track: SpotifyTrack) {
        self.init(title: track.title, artist: track.artist, durationSeconds: track.durationSeconds, youtubeSearchQuery: track.youtubeSearchQuery)
    }

    public init(_ track: SoundCloudTrack) {
        self.init(title: track.title, artist: track.artist, durationSeconds: track.durationSeconds, youtubeSearchQuery: track.youtubeSearchQuery)
    }

    public init(_ item: YouTubePlaylistItem) {
        self.init(
            title: item.title ?? "YouTube Video (\(item.videoID.prefix(6)))",
            artist: item.author,
            durationSeconds: item.lengthSeconds,
            youtubeVideoID: item.videoID,
            youtubeSearchQuery: item.title ?? item.videoID
        )
    }

    /// The YouTube-shaped view of this track, for the video-id-keyed import/sync path.
    public var youtubePlaylistItem: YouTubePlaylistItem? {
        guard let youtubeVideoID else { return nil }
        return YouTubePlaylistItem(videoID: youtubeVideoID, title: title, author: artist, lengthSeconds: durationSeconds)
    }
}

/// One page of an API listing plus how to fetch the next one (nil when exhausted). Spotify and
/// SoundCloud hand back a full `next` URL; YouTube hands back a `pageToken` the caller appends.
public struct ServicePage<Item: Sendable & Equatable>: Equatable, Sendable {
    public var items: [Item]
    public var nextPageURL: URL?
    public var nextPageToken: String?

    public init(items: [Item], nextPageURL: URL? = nil, nextPageToken: String? = nil) {
        self.items = items
        self.nextPageURL = nextPageURL
        self.nextPageToken = nextPageToken
    }

    public var hasMore: Bool { nextPageURL != nil || nextPageToken != nil }
}

/// A fully resolved remote collection, whichever service or path (API or scrape) produced it.
public struct ServicePlaylistContents: Equatable, Sendable {
    public var summary: ServicePlaylistSummary
    public var tracks: [ServiceTrack]

    public init(summary: ServicePlaylistSummary, tracks: [ServiceTrack]) {
        self.summary = summary
        self.tracks = tracks
    }

    public var isEmpty: Bool { tracks.isEmpty }
}
