import Foundation

/// Pure request-building and response-parsing for the Spotify **Web API** (the signed-in path).
/// Unlike the embed-page scrape (`SpotifyPlaylist`), the API is documented and paginates, so a
/// connected account imports full-length and private playlists plus Liked Songs. The Ingest layer
/// adds the bearer token and does the networking; everything here is Linux-testable.
public enum SpotifyAPI {
    public static let base = URL(string: "https://api.spotify.com/v1")!
    /// Sentinel `sourceID` for the account's Liked Songs (no real playlist id exists).
    public static let likedSongsID = "liked-songs"
    public static let pageSize = 50

    // MARK: Requests

    public static var myPlaylistsURL: URL { base.appendingPathComponent("me/playlists").appendingQuery(["limit": "\(pageSize)"]) }
    public static var likedTracksURL: URL { base.appendingPathComponent("me/tracks").appendingQuery(["limit": "\(pageSize)"]) }

    public static func playlistURL(id: String) -> URL {
        base.appendingPathComponent("playlists/\(id)").appendingQuery(["fields": "id,name,owner(display_name),tracks(total)"])
    }
    public static func playlistTracksURL(id: String) -> URL {
        base.appendingPathComponent("playlists/\(id)/tracks").appendingQuery([
            "limit": "\(pageSize)",
            "fields": "next,items(track(name,type,is_local,duration_ms,artists(name)))",
        ])
    }
    public static func albumURL(id: String) -> URL { base.appendingPathComponent("albums/\(id)") }
    public static func albumTracksURL(id: String) -> URL {
        base.appendingPathComponent("albums/\(id)/tracks").appendingQuery(["limit": "\(pageSize)"])
    }
    public static func trackURL(id: String) -> URL { base.appendingPathComponent("tracks/\(id)") }

    // MARK: Responses

    /// `GET /me/playlists` page → summaries. Spotify can return `null` items for playlists the
    /// account lost access to; those are skipped.
    public static func parsePlaylistsPage(_ data: Data) -> ServicePage<ServicePlaylistSummary> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ServicePage(items: []) }
        let items = ((root["items"] as? [Any]) ?? []).compactMap { entry -> ServicePlaylistSummary? in
            guard let dict = entry as? [String: Any] else { return nil }
            return playlistSummary(dict)
        }
        return ServicePage(items: items, nextPageURL: (root["next"] as? String).flatMap(URL.init(string:)))
    }

    /// `GET /playlists/{id}` or `GET /albums/{id}` → one summary (name + owner/artist + total).
    public static func parsePlaylistSummary(_ data: Data) -> ServicePlaylistSummary? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return playlistSummary(dict)
    }

    /// `GET /playlists/{id}/tracks`, `/albums/{id}/tracks` or `/me/tracks` page → tracks. Handles
    /// both wrapped items (`items[].track`) and bare album tracks (`items[]` is the track).
    /// Podcast episodes and local files are skipped — there's nothing to re-source.
    public static func parseTracksPage(_ data: Data) -> ServicePage<ServiceTrack> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ServicePage(items: []) }
        let tracks = ((root["items"] as? [Any]) ?? []).compactMap { entry -> ServiceTrack? in
            guard let dict = entry as? [String: Any] else { return nil }
            let trackDict = (dict["track"] as? [String: Any]) ?? dict
            return track(trackDict)
        }
        return ServicePage(items: tracks, nextPageURL: (root["next"] as? String).flatMap(URL.init(string:)))
    }

    /// `GET /tracks/{id}` → one track.
    public static func parseTrack(_ data: Data) -> ServiceTrack? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return track(dict)
    }

    // MARK: - Private

    private static func playlistSummary(_ dict: [String: Any]) -> ServicePlaylistSummary? {
        guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
        let type = dict["type"] as? String
        let isAlbum = type == "album" || dict["album_type"] != nil
        let owner = JSONNav.string(dict, ["owner", "display_name"])
            ?? (dict["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ")
        let total = ((dict["tracks"] as? [String: Any])?["total"] as? NSNumber)?.intValue
            ?? (dict["total_tracks"] as? NSNumber)?.intValue
        return ServicePlaylistSummary(
            service: .spotify,
            sourceID: id,
            kind: isAlbum ? .album : .playlist,
            name: name,
            ownerName: owner.flatMap { $0.isEmpty ? nil : $0 },
            trackCount: total
        )
    }

    private static func track(_ dict: [String: Any]) -> ServiceTrack? {
        if let type = dict["type"] as? String, type != "track" { return nil }
        if dict["is_local"] as? Bool == true { return nil }
        guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
        let artists = (dict["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let artist = artists.isEmpty ? nil : artists.joined(separator: ", ")
        let ms = (dict["duration_ms"] as? NSNumber)?.doubleValue
        let spotify = SpotifyTrack(title: name, artist: artist, durationSeconds: ms.map { Int(($0 / 1000).rounded()) })
        return ServiceTrack(spotify)
    }
}

extension URL {
    /// Appends query items (replacing none — callers build each URL once).
    func appendingQuery(_ items: [String: String]) -> URL {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        var existing = comps.queryItems ?? []
        for (name, value) in items.sorted(by: { $0.key < $1.key }) {
            existing.append(URLQueryItem(name: name, value: value))
        }
        comps.queryItems = existing
        return comps.url ?? self
    }
}
