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
/// still returns `explicit` siblings. Interactive typing stays on the two primary Search
/// GETs; query variants + artist-lookup upgrades run only on submit / settle, as
/// best-effort extras that never discard primary hits. Lookups are cached per `artistID`
/// for the session. MusicKit would also see explicit rows but needs the MusicKit App
/// Service — that capability mismatches cloud signing for TestFlight, so we stay on the
/// HTTP affiliate API.
///
/// One instance owns the session lookup cache (the search model holds it). Errors on the
/// primary song/album Search map to shared `IngestError` cases for the UI.
public final class MusicCatalog: Sendable {

    private let artistCache = ArtistLookupCache()

    public init() {}

    /// Searches songs and albums for a free-text term.
    ///
    /// - Parameters:
    ///   - upgrade: When `false` (debounced typing), only the two primary Search GETs run —
    ///     same cost as before. When `true` (submit / settle), also fans out best-effort
    ///     query variants and artist lookups, then re-ranks through `CatalogSearch`.
    public func search(
        _ term: String,
        limit: Int = 25,
        upgrade: Bool = false
    ) async throws -> (songs: [CatalogSong], albums: [CatalogAlbum]) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], []) }

        let variants = CatalogSearch.queryVariants(from: trimmed)
        let primary = variants.first ?? trimmed

        async let primarySongs = fetchHits(term: primary, entity: "song", limit: max(limit, 40))
        async let primaryAlbums = fetchHits(term: primary, entity: "album", limit: max(limit, 25))
        let (songsSeed, albumsSeed) = try await (primarySongs, primaryAlbums)

        guard upgrade else {
            let rankedSongs = CatalogSearch.rankSongs(query: trimmed, batches: [songsSeed], limit: limit)
            let rankedAlbums = CatalogSearch.rankAlbums(query: trimmed, batches: [albumsSeed], limit: limit)
            return (rankedSongs.map(CatalogSong.init(hit:)), rankedAlbums.map(CatalogAlbum.init(hit:)))
        }

        // Variants + artist lookup are optional coverage; a 403/timeout must not erase primary.
        let extras = await fetchSongVariantsBestEffort(Array(variants.dropFirst()))
        let upgradeIDs = CatalogSearch.artistIDsForUpgrade(
            from: songsSeed + extras.flatMap { $0 } + albumsSeed,
            limit: 3
        )
        let lookupBatches = await lookupArtistCatalogBestEffort(artistIDs: upgradeIDs)

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

    /// Best-effort variant song searches — failures become empty batches.
    private func fetchSongVariantsBestEffort(_ variants: [String]) async -> [[CatalogSearch.Hit]] {
        guard !variants.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, [CatalogSearch.Hit]).self) { group in
            for (index, variant) in variants.enumerated() {
                group.addTask {
                    let hits = (try? await self.fetchHits(term: variant, entity: "song", limit: 25)) ?? []
                    return (index, hits)
                }
            }
            var pairs: [(Int, [CatalogSearch.Hit])] = []
            for await pair in group { pairs.append(pair) }
            return pairs.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Best-effort artist song+album lookups with a per-session `artistID` cache.
    private func lookupArtistCatalogBestEffort(
        artistIDs: [Int]
    ) async -> (songs: [CatalogSearch.Hit], albums: [CatalogSearch.Hit]) {
        guard !artistIDs.isEmpty else { return ([], []) }
        var songBatches: [[CatalogSearch.Hit]] = []
        var albumBatches: [[CatalogSearch.Hit]] = []
        songBatches.reserveCapacity(artistIDs.count)
        albumBatches.reserveCapacity(artistIDs.count)

        await withTaskGroup(of: (songs: [CatalogSearch.Hit], albums: [CatalogSearch.Hit]).self) { group in
            for id in artistIDs {
                group.addTask {
                    if let cached = await self.artistCache.cached(artistID: id) {
                        return cached
                    }
                    let songs = (try? await self.fetch(
                        path: "/lookup",
                        query: CatalogSearch.lookupQueryItems(id: id, entity: "song", limit: 100)
                    )) ?? []
                    let albums = (try? await self.fetch(
                        path: "/lookup",
                        query: CatalogSearch.lookupQueryItems(id: id, entity: "album", limit: 50)
                    )) ?? []
                    // Cache even empty successful parses so we don't re-hammer a miss; a
                    // thrown fetch already collapsed to [] above and is still worth caching
                    // for this session to stay under Apple's ~20/min Search budget.
                    await self.artistCache.store(artistID: id, songs: songs, albums: albums)
                    return (songs, albums)
                }
            }
            for await batch in group {
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

        let artistAlbums: [CatalogSearch.Hit]
        if let cached = await artistCache.cached(artistID: artistID) {
            artistAlbums = cached.albums
        } else {
            let songs = (try? await fetch(
                path: "/lookup",
                query: CatalogSearch.lookupQueryItems(id: artistID, entity: "song", limit: 100)
            )) ?? []
            let albums = (try? await fetch(
                path: "/lookup",
                query: CatalogSearch.lookupQueryItems(id: artistID, entity: "album", limit: 100)
            )) ?? []
            await artistCache.store(artistID: artistID, songs: songs, albums: albums)
            artistAlbums = albums
        }
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

// MARK: - Session artist-lookup cache

/// Per-`MusicCatalog` instance cache so typing → settle → submit doesn't re-fetch the same
/// artist's song/album lists within one search session.
private actor ArtistLookupCache {
    private var songsByArtist: [Int: [CatalogSearch.Hit]] = [:]
    private var albumsByArtist: [Int: [CatalogSearch.Hit]] = [:]

    func cached(artistID: Int) -> (songs: [CatalogSearch.Hit], albums: [CatalogSearch.Hit])? {
        guard let songs = songsByArtist[artistID],
              let albums = albumsByArtist[artistID] else { return nil }
        return (songs, albums)
    }

    func store(artistID: Int, songs: [CatalogSearch.Hit], albums: [CatalogSearch.Hit]) {
        songsByArtist[artistID] = songs
        albumsByArtist[artistID] = albums
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
