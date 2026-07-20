import Foundation

/// A song hit from the music catalog search.
public struct CatalogSong: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let artist: String
    public let album: String?
    public let durationSeconds: Double
    public let artworkURL: URL?

    /// The text used to source this song's audio on YouTube (same shape the Spotify
    /// import uses — "title artist").
    public var youtubeSearchQuery: String { "\(title) \(artist)" }
}

/// An album hit from the music catalog search.
public struct CatalogAlbum: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let artist: String
    public let trackCount: Int
    public let releaseYear: Int?
    public let artworkURL: URL?
}

/// Client for the iTunes Search API — Apple's full commercial music catalog (over 100 million
/// songs), freely queryable with no API key. Chosen over MusicBrainz (richer metadata but hard
/// 1 req/s rate limit and patchy artwork) for an interactive, per-keystroke search UI.
///
/// Stateless and Sendable: each call is a single GET returning decoded results; errors map to
/// the shared `IngestError` cases so the UI reuses the existing user-facing messages.
public struct MusicCatalog: Sendable {

    public init() {}

    /// Searches songs and albums for a free-text term, concurrently (two entity queries —
    /// the API has no combined mode). Empty/whitespace terms return empty results.
    public func search(_ term: String, limit: Int = 25) async throws -> (songs: [CatalogSong], albums: [CatalogAlbum]) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], []) }
        async let songResults = fetch(query: [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        async let albumResults = fetch(query: [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        let (songs, albums) = try await (songResults, albumResults)
        return (songs.compactMap(CatalogSong.init(result:)),
                albums.compactMap(CatalogAlbum.init(result:)))
    }

    /// The full tracklist of an album (for importing it as a playlist), in track order.
    public func albumSongs(albumID: Int) async throws -> [CatalogSong] {
        let results = try await fetch(path: "/lookup", query: [
            URLQueryItem(name: "id", value: String(albumID)),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "200"),
        ])
        // The lookup echoes the album itself as the first result — songs only.
        return results
            .filter { $0.wrapperType == "track" }
            .compactMap(CatalogSong.init(result:))
    }

    // MARK: Networking

    private func fetch(path: String = "/search", query: [URLQueryItem]) async throws -> [ITunesResult] {
        var components = URLComponents(string: "https://itunes.apple.com")!
        components.path = path
        components.queryItems = query
        guard let url = components.url else { throw IngestError.invalidURL }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw IngestError.network(String(describing: error))
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 403, 429: throw IngestError.rateLimited
            case 500..<600: throw IngestError.network("catalog HTTP \(http.statusCode)")
            default: throw IngestError.resolveFailed("catalog HTTP \(http.statusCode)")
            }
        }
        do {
            return try JSONDecoder().decode(ITunesResponse.self, from: data).results
        } catch {
            throw IngestError.decodeFailed("catalog response: \(error)")
        }
    }
}

// MARK: - Wire format

private struct ITunesResponse: Decodable {
    let results: [ITunesResult]
}

/// One row of the iTunes Search/Lookup response — a superset of song and album fields, all
/// optional because the two entity kinds share this shape.
private struct ITunesResult: Decodable {
    let wrapperType: String?
    let trackId: Int?
    let collectionId: Int?
    let trackName: String?
    let collectionName: String?
    let artistName: String?
    let trackTimeMillis: Double?
    let trackCount: Int?
    let artworkUrl100: String?
    let releaseDate: String?

    /// Artwork CDN URLs embed the size in the path — swap 100×100 for a crisp 600×600.
    var artworkURL: URL? {
        artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100", with: "600x600")) }
    }

    var releaseYear: Int? {
        releaseDate.flatMap { Int($0.prefix(4)) }
    }
}

private extension CatalogSong {
    init?(result: ITunesResult) {
        guard let id = result.trackId, let title = result.trackName, let artist = result.artistName else {
            return nil
        }
        self.init(
            id: id,
            title: title,
            artist: artist,
            album: result.collectionName,
            durationSeconds: (result.trackTimeMillis ?? 0) / 1000,
            artworkURL: result.artworkURL
        )
    }
}

private extension CatalogAlbum {
    init?(result: ITunesResult) {
        guard let id = result.collectionId, let title = result.collectionName,
              let artist = result.artistName else {
            return nil
        }
        self.init(
            id: id,
            title: title,
            artist: artist,
            trackCount: result.trackCount ?? 0,
            releaseYear: result.releaseYear,
            artworkURL: result.artworkURL
        )
    }
}
