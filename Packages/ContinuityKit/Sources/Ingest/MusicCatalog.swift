import ContinuityCore
import Foundation

/// A song hit from the music catalog search.
public struct CatalogSong: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let artist: String
    public let album: String?
    public let durationSeconds: Double
    public let artworkURL: URL?
    /// RIAA-style advisory from the catalog row (`explicit` / `cleaned` / `notExplicit`).
    public let isExplicit: Bool

    /// The text used to source this song's audio on YouTube (same shape the Spotify
    /// import uses — "title artist").
    public var youtubeSearchQuery: String { "\(title) \(artist)" }

    public init(
        id: Int,
        title: String,
        artist: String,
        album: String?,
        durationSeconds: Double,
        artworkURL: URL?,
        isExplicit: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.artworkURL = artworkURL
        self.isExplicit = isExplicit
    }
}

/// An album hit from the music catalog search.
public struct CatalogAlbum: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let artist: String
    public let trackCount: Int
    public let releaseYear: Int?
    public let artworkURL: URL?
    public let isExplicit: Bool

    public init(
        id: Int,
        title: String,
        artist: String,
        trackCount: Int,
        releaseYear: Int?,
        artworkURL: URL?,
        isExplicit: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.trackCount = trackCount
        self.releaseYear = releaseYear
        self.artworkURL = artworkURL
        self.isExplicit = isExplicit
    }
}

/// Client for the iTunes Search / Lookup API — Apple's commercial music catalog, freely
/// queryable with no API key. Metadata only; Continuity still re-sources audio on YouTube.
///
/// **Explicit coverage:** the public `/search` endpoint currently returns `cleaned` /
/// `notExplicit` song rows even with `explicit=Yes`. `/lookup?id=<artistId>&entity=song|album`
/// still returns `explicit` siblings. This client fans out a few query variants, then upgrades
/// top artists via lookup and merges through `CatalogSearch` (ContinuityCore). MusicKit would
/// also see explicit catalog rows but needs the MusicKit App Service — that capability mismatches
/// cloud signing for TestFlight, so we stay on the HTTP affiliate API.
///
/// Stateless and Sendable: each call is GETs returning decoded results; errors map to
/// the shared `IngestError` cases so the UI reuses the existing user-facing messages.
public struct MusicCatalog: Sendable {

    public init() {}

    /// Searches songs and albums for a free-text term. Empty/whitespace terms return empty
    /// results. Runs query variants + artist-lookup upgrades concurrently, then ranks/dedupes.
    public func search(_ term: String, limit: Int = 25) async throws -> (songs: [CatalogSong], albums: [CatalogAlbum]) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], []) }

        let variants = CatalogSearch.queryVariants(from: trimmed)
        // Primary variant gets full song+album pulls; extra variants are song-only to keep
        // the interactive search budget bounded (~6–8 GETs typical).
        let primary = variants[0]
        let extra = Array(variants.dropFirst())

        async let primarySongs = fetchHits(term: primary, entity: "song", limit: max(limit, 40))
        async let primaryAlbums = fetchHits(term: primary, entity: "album", limit: max(limit, 25))
        async let variantSongBatches = fetchSongVariants(extra)

        let (songsSeed, albumsSeed, extras) = try await (primarySongs, primaryAlbums, variantSongBatches)

        // Artist lookup is what actually surfaces explicit rows the Search endpoint omits.
        let upgradeIDs = CatalogSearch.artistIDsForUpgrade(
            from: songsSeed + extras.flatMap { $0 } + albumsSeed,
            limit: 3
        )
        let lookupBatches = try await lookupArtistCatalog(artistIDs: upgradeIDs)

        let rankedSongs = CatalogSearch.rankSongs(
            query: trimmed,
            batches: [songsSeed] + extras + [lookupBatches.songs],
            limit: limit
        )
        let rankedAlbums = CatalogSearch.rankAlbums(
            query: trimmed,
            batches: [albumsSeed, lookupBatches.albums],
            limit: limit
        )

        return (
            rankedSongs.map(CatalogSong.init(hit:)),
            rankedAlbums.map(CatalogAlbum.init(hit:))
        )
    }

    /// The full tracklist of an album (for importing it as a playlist), in track order.
    /// When the album id points at a cleaned collection, prefers the explicit sibling from
    /// the artist's album list so imported songs carry uncensored titles.
    public func albumSongs(albumID: Int) async throws -> [CatalogSong] {
        let resolvedID = try await preferredAlbumID(for: albumID)
        let results = try await fetch(
            path: "/lookup",
            query: CatalogSearch.lookupQueryItems(id: resolvedID, entity: "song", limit: 200)
        )
        // The lookup echoes the album itself as the first result — songs only, keep API order.
        return results
            .filter { $0.kind == .song }
            .map(CatalogSong.init(hit:))
    }

    // MARK: Networking

    private func fetchHits(term: String, entity: String, limit: Int) async throws -> [CatalogSearch.Hit] {
        try await fetch(
            path: "/search",
            query: CatalogSearch.searchQueryItems(term: term, entity: entity, limit: limit)
        )
    }

    private func fetchSongVariants(_ variants: [String]) async throws -> [[CatalogSearch.Hit]] {
        guard !variants.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, [CatalogSearch.Hit]).self) { group in
            for (index, variant) in variants.enumerated() {
                group.addTask {
                    (index, try await self.fetchHits(term: variant, entity: "song", limit: 25))
                }
            }
            var pairs: [(Int, [CatalogSearch.Hit])] = []
            for try await pair in group { pairs.append(pair) }
            return pairs.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func lookupArtistCatalog(artistIDs: [Int]) async throws -> (songs: [CatalogSearch.Hit], albums: [CatalogSearch.Hit]) {
        guard !artistIDs.isEmpty else { return ([], []) }
        var songBatches: [[CatalogSearch.Hit]] = []
        var albumBatches: [[CatalogSearch.Hit]] = []
        songBatches.reserveCapacity(artistIDs.count)
        albumBatches.reserveCapacity(artistIDs.count)

        try await withThrowingTaskGroup(of: (songs: [CatalogSearch.Hit], albums: [CatalogSearch.Hit]).self) { group in
            for id in artistIDs {
                group.addTask {
                    async let songs = self.fetch(
                        path: "/lookup",
                        query: CatalogSearch.lookupQueryItems(id: id, entity: "song", limit: 100)
                    )
                    async let albums = self.fetch(
                        path: "/lookup",
                        query: CatalogSearch.lookupQueryItems(id: id, entity: "album", limit: 50)
                    )
                    return try await (songs, albums)
                }
            }
            for try await batch in group {
                songBatches.append(batch.songs)
                albumBatches.append(batch.albums)
            }
        }
        return (songBatches.flatMap { $0 }, albumBatches.flatMap { $0 })
    }

    /// If `albumID` is a cleaned collection, swap to the artist's explicit album of the same name.
    private func preferredAlbumID(for albumID: Int) async throws -> Int {
        let echoed = try await fetch(
            path: "/lookup",
            query: CatalogSearch.lookupQueryItems(id: albumID, entity: "album", limit: 1)
        )
        guard let album = echoed.first(where: { $0.kind == .album }) else { return albumID }
        if album.explicitness == .explicit { return album.id }
        guard let artistID = album.artistID else { return albumID }
        let artistAlbums = try await fetch(
            path: "/lookup",
            query: CatalogSearch.lookupQueryItems(id: artistID, entity: "album", limit: 100)
        )
        return CatalogSearch.preferredAlbumID(among: artistAlbums, matching: album)
    }

    private func fetch(path: String, query: [URLQueryItem]) async throws -> [CatalogSearch.Hit] {
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
        let hits = CatalogSearch.parseResponse(data)
        // Decode failure used to throw when the payload wasn't our Codable shape. The Core
        // parser returns [] for unreadable JSON; treat a 200 with zero parseable rows as OK
        // (genuine empty result) — only throw when the body isn't JSON at all.
        if hits.isEmpty,
           (try? JSONSerialization.jsonObject(with: data)) == nil {
            throw IngestError.decodeFailed("catalog response: invalid JSON")
        }
        return hits
    }
}

// MARK: - Mapping

private extension CatalogSong {
    init(hit: CatalogSearch.Hit) {
        let art = hit.artworkURLString
            .map { $0.replacingOccurrences(of: "100x100", with: "600x600") }
            .flatMap(URL.init(string:))
        self.init(
            id: hit.id,
            title: hit.title,
            artist: hit.artist,
            album: hit.album,
            durationSeconds: (hit.durationMilliseconds ?? 0) / 1000,
            artworkURL: art,
            isExplicit: hit.explicitness == .explicit
        )
    }
}

private extension CatalogAlbum {
    init(hit: CatalogSearch.Hit) {
        let art = hit.artworkURLString
            .map { $0.replacingOccurrences(of: "100x100", with: "600x600") }
            .flatMap(URL.init(string:))
        self.init(
            id: hit.id,
            title: hit.title,
            artist: hit.artist,
            trackCount: hit.trackCount ?? 0,
            releaseYear: hit.releaseYear,
            artworkURL: art,
            isExplicit: hit.explicitness == .explicit
        )
    }
}
