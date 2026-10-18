import ContinuityCore
import Foundation
import os

private let apiLog = Logger(subsystem: "com.continuity.app", category: "serviceapi")

/// Authenticated GETs shared by the three API clients: bearer header, status → `IngestError`
/// mapping (401 → `.unauthorized` so the queue can refresh-and-retry, 429 → `.rateLimited`,
/// 5xx → `.network`), and the shared `Retry` gate for transient failures.
enum ServiceHTTP {
    static func get(_ url: URL, token: String) async throws -> Data {
        try await Retry.run {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw IngestError.network(String(describing: error))
            }
            guard let http = response as? HTTPURLResponse else { return data }
            switch http.statusCode {
            case 200..<300: return data
            case 401: throw IngestError.unauthorized
            case 403, 404: throw IngestError.sourceUnavailable
            case 429: throw IngestError.rateLimited
            case 500..<600: throw IngestError.network("\(url.host ?? "api") HTTP \(http.statusCode)")
            default:
                apiLog.error("\(url.absoluteString, privacy: .public) HTTP \(http.statusCode)")
                throw IngestError.resolveFailed("\(url.host ?? "api") HTTP \(http.statusCode)")
            }
        }
    }

    /// Follows `next` URLs until exhausted or `maxItems` is reached.
    static func collectPages<Item: Sendable & Equatable>(
        first: URL,
        token: String,
        maxItems: Int,
        parse: (Data) -> ServicePage<Item>
    ) async throws -> [Item] {
        var items: [Item] = []
        var next: URL? = first
        var seen: Set<URL> = []
        while let url = next, items.count < maxItems, seen.insert(url).inserted {
            let page = parse(try await get(url, token: token))
            items += page.items
            next = page.nextPageURL
        }
        return Array(items.prefix(maxItems))
    }
}

/// Upper bound on tracks read from one API collection. Liked-songs libraries run to thousands;
/// the ingest pipeline processes them lazily, but a library import is still bounded.
let connectedLibraryMaxTracks = 1_000

// MARK: - Spotify

/// Spotify Web API over a connected account. Full-length, private and collaborative playlists,
/// albums, Liked Songs, and single tracks — none of which the anonymous embed page can give.
struct SpotifyAPIClient: ConnectedLibraryReading {
    let service = MusicService.spotify

    func playlists(token: String) async throws -> [ServicePlaylistSummary] {
        let liked = ServicePlaylistSummary(service: .spotify, sourceID: SpotifyAPI.likedSongsID, kind: .likes, name: "Liked Songs")
        let mine = try await ServiceHTTP.collectPages(
            first: SpotifyAPI.myPlaylistsURL, token: token, maxItems: 500, parse: SpotifyAPI.parsePlaylistsPage
        )
        return [liked] + mine
    }

    func contents(of summary: ServicePlaylistSummary, token: String) async throws -> ServicePlaylistContents {
        let first: URL
        switch summary.kind {
        case .likes: first = SpotifyAPI.likedTracksURL
        case .album: first = SpotifyAPI.albumTracksURL(id: summary.sourceID)
        case .playlist: first = SpotifyAPI.playlistTracksURL(id: summary.sourceID)
        }
        let tracks = try await ServiceHTTP.collectPages(
            first: first, token: token, maxItems: connectedLibraryMaxTracks, parse: SpotifyAPI.parseTracksPage
        )
        return ServicePlaylistContents(summary: summary, tracks: tracks)
    }

    func resolveLink(_ raw: String, token: String) async throws -> ResolvedServiceLink? {
        guard let link = SpotifyURL.parse(raw) else { return nil }
        switch link.kind {
        case .track:
            guard let track = SpotifyAPI.parseTrack(try await ServiceHTTP.get(SpotifyAPI.trackURL(id: link.id), token: token)) else {
                throw IngestError.sourceUnavailable
            }
            return .track(track)
        case .playlist, .album:
            let summaryURL = link.kind == .album ? SpotifyAPI.albumURL(id: link.id) : SpotifyAPI.playlistURL(id: link.id)
            guard var summary = SpotifyAPI.parsePlaylistSummary(try await ServiceHTTP.get(summaryURL, token: token)) else {
                throw IngestError.sourceUnavailable
            }
            summary.kind = link.kind == .album ? .album : .playlist
            let contents = try await self.contents(of: summary, token: token)
            guard !contents.isEmpty else { throw IngestError.sourceUnavailable }
            return .playlist(contents)
        }
    }
}

// MARK: - YouTube

/// YouTube Data API v3 over a connected Google account: the user's own playlists (private too),
/// Liked videos, and any playlist by id without scraping. Items carry video ids, so imported
/// tracks ingest directly.
struct YouTubeDataAPIClient: ConnectedLibraryReading {
    let service = MusicService.youtube

    func playlists(token: String) async throws -> [ServicePlaylistSummary] {
        var items: [ServicePlaylistSummary] = [YouTubeDataAPI.likedVideosSummary]
        var pageToken: String?
        repeat {
            let page = YouTubeDataAPI.parsePlaylistsPage(
                try await ServiceHTTP.get(YouTubeDataAPI.myPlaylistsURL(pageToken: pageToken), token: token)
            )
            items += page.items.filter { $0.kind != .likes }
            pageToken = page.nextPageToken
        } while pageToken != nil && items.count < 500
        return items
    }

    func contents(of summary: ServicePlaylistSummary, token: String) async throws -> ServicePlaylistContents {
        var tracks: [ServiceTrack] = []
        var pageToken: String?
        repeat {
            let page = YouTubeDataAPI.parsePlaylistItemsPage(
                try await ServiceHTTP.get(YouTubeDataAPI.playlistItemsURL(playlistID: summary.sourceID, pageToken: pageToken), token: token)
            )
            tracks += page.items
            pageToken = page.nextPageToken
        } while pageToken != nil && tracks.count < connectedLibraryMaxTracks
        tracks = Array(tracks.prefix(connectedLibraryMaxTracks))
        await fillDurations(&tracks, token: token)
        return ServicePlaylistContents(summary: summary, tracks: tracks)
    }

    func resolveLink(_ raw: String, token: String) async throws -> ResolvedServiceLink? {
        guard let link = YouTubeURL.parse(raw), let playlistID = link.playlistID else { return nil }
        let page = YouTubeDataAPI.parsePlaylistsPage(try await ServiceHTTP.get(YouTubeDataAPI.playlistURL(id: playlistID), token: token))
        // A playlist the API won't describe (another user's private list) still has readable
        // items only if it's public — fall back to a bare summary and let the item fetch decide.
        let summary = page.items.first ?? ServicePlaylistSummary(service: .youtube, sourceID: playlistID, kind: .playlist, name: "YouTube Playlist")
        let contents = try await self.contents(of: summary, token: token)
        guard !contents.isEmpty else { throw IngestError.sourceUnavailable }
        return .playlist(contents)
    }

    /// `playlistItems` omits durations; one `videos` call per 50 ids fills them in. Best-effort —
    /// rows render "0:00" until the download decodes the real length otherwise.
    private func fillDurations(_ tracks: inout [ServiceTrack], token: String) async {
        let ids = tracks.compactMap(\.youtubeVideoID)
        var durations: [String: Int] = [:]
        var start = 0
        while start < ids.count {
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            start += batch.count
            guard let data = try? await ServiceHTTP.get(YouTubeDataAPI.videosURL(ids: batch), token: token) else { break }
            durations.merge(YouTubeDataAPI.parseVideoDurations(data)) { $1 }
        }
        guard !durations.isEmpty else { return }
        for index in tracks.indices {
            if let id = tracks[index].youtubeVideoID, let seconds = durations[id] {
                tracks[index].durationSeconds = seconds
            }
        }
    }
}

// MARK: - SoundCloud

/// Official SoundCloud API over a connected account: the user's sets and likes, and `/resolve`
/// for pasted links (private sets included) — no scraped `client_id` needed.
struct SoundCloudAPIClient: ConnectedLibraryReading {
    let service = MusicService.soundcloud

    func playlists(token: String) async throws -> [ServicePlaylistSummary] {
        let likes = ServicePlaylistSummary(service: .soundcloud, sourceID: SoundCloudAPI.likesID, kind: .likes, name: "Liked Tracks")
        let mine = try await ServiceHTTP.collectPages(
            first: SoundCloudAPI.myPlaylistsURL, token: token, maxItems: 500, parse: SoundCloudAPI.parsePlaylistsPage
        )
        return [likes] + mine
    }

    func contents(of summary: ServicePlaylistSummary, token: String) async throws -> ServicePlaylistContents {
        switch summary.kind {
        case .likes:
            let tracks = try await ServiceHTTP.collectPages(
                first: SoundCloudAPI.likedTracksURL, token: token, maxItems: connectedLibraryMaxTracks, parse: SoundCloudAPI.parseTracksPage
            )
            return ServicePlaylistContents(summary: summary, tracks: tracks)
        case .playlist, .album:
            if SoundCloudAPI.isURN(summary.sourceID) {
                let tracks = try await ServiceHTTP.collectPages(
                    first: SoundCloudAPI.playlistTracksURL(urn: summary.sourceID), token: token,
                    maxItems: connectedLibraryMaxTracks, parse: SoundCloudAPI.parseTracksPage
                )
                return ServicePlaylistContents(summary: summary, tracks: tracks)
            }
            // Permalink-path identity (from a pasted link or a listed set): `/resolve` returns
            // the set with its tracks inline.
            guard case .playlist(let resolved)? = try await resolveLink("https://soundcloud.com/\(summary.sourceID)", token: token) else {
                throw IngestError.sourceUnavailable
            }
            var merged = resolved
            merged.summary.sourceID = summary.sourceID
            merged.summary.kind = summary.kind
            return merged
        }
    }

    func resolveLink(_ raw: String, token: String) async throws -> ResolvedServiceLink? {
        guard let link = SoundCloudURL.parse(raw), let permalink = link.permalinkURL else { return nil }
        let data = try await ServiceHTTP.get(SoundCloudAPI.resolveURL(permalink: permalink), token: token)
        switch SoundCloudAPI.parseResolved(data) {
        case .track(let track)?:
            return .track(track)
        case .playlist(let contents)?:
            guard !contents.isEmpty else { throw IngestError.sourceUnavailable }
            var fixed = contents
            // Keep the pasted path as identity so the anonymous scrape can sync it later.
            if link.kind != .shortLink { fixed.summary.sourceID = link.path }
            return .playlist(fixed)
        case nil:
            throw IngestError.sourceUnavailable
        }
    }
}
