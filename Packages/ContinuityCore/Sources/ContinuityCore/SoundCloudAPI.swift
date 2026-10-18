import Foundation

/// Pure request-building and response-parsing for the official **SoundCloud API**
/// (`api.soundcloud.com`, OAuth bearer) — the signed-in path. It lists the account's playlists
/// and likes with proper pagination, and `/resolve` turns any pasted `soundcloud.com` link into
/// its resource, which spares the anonymous page scrape (`SoundCloudPlaylist`) entirely.
public enum SoundCloudAPI {
    public static let base = URL(string: "https://api.soundcloud.com")!
    /// Sentinel `sourceID` for the account's liked tracks.
    public static let likesID = "likes"
    public static let pageSize = 50

    /// What `/resolve` handed back for a link.
    public enum Resolved: Equatable, Sendable {
        case playlist(ServicePlaylistContents)
        case track(ServiceTrack)
    }

    // MARK: Requests

    public static var myPlaylistsURL: URL {
        base.appendingPathComponent("me/playlists").appendingQuery([
            "limit": "\(pageSize)", "linked_partitioning": "true", "show_tracks": "false",
        ])
    }
    public static var likedTracksURL: URL {
        base.appendingPathComponent("me/likes/tracks").appendingQuery(["limit": "\(pageSize)", "linked_partitioning": "true"])
    }
    public static func playlistURL(urn: String) -> URL {
        base.appendingPathComponent("playlists/\(urn)")
    }
    public static func playlistTracksURL(urn: String) -> URL {
        base.appendingPathComponent("playlists/\(urn)/tracks").appendingQuery(["limit": "\(pageSize)", "linked_partitioning": "true"])
    }
    public static func resolveURL(permalink: URL) -> URL {
        base.appendingPathComponent("resolve").appendingQuery(["url": permalink.absoluteString])
    }

    // MARK: Responses

    /// `GET /me/playlists` page → summaries. Accepts the `{collection, next_href}` envelope or a
    /// bare array (what the API returns without `linked_partitioning`).
    public static func parsePlaylistsPage(_ data: Data) -> ServicePage<ServicePlaylistSummary> {
        let (list, next) = envelope(data)
        let items = list.compactMap { ($0 as? [String: Any]).flatMap(playlistSummary) }
        return ServicePage(items: items, nextPageURL: next)
    }

    /// `GET /playlists/{urn}` → one summary.
    public static func parsePlaylistSummary(_ data: Data) -> ServicePlaylistSummary? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return playlistSummary(dict)
    }

    /// `GET /playlists/{urn}/tracks` or `/me/likes/tracks` page → tracks (same envelope rules).
    public static func parseTracksPage(_ data: Data) -> ServicePage<ServiceTrack> {
        let (list, next) = envelope(data)
        let tracks = list.compactMap { ($0 as? [String: Any]).flatMap(track) }
        return ServicePage(items: tracks, nextPageURL: next)
    }

    /// `GET /resolve?url=…` → the playlist (with its inline `tracks`) or the single track.
    public static func parseResolved(_ data: Data) -> Resolved? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch dict["kind"] as? String {
        case "track":
            return track(dict).map(Resolved.track)
        case "playlist":
            guard let summary = playlistSummary(dict) else { return nil }
            let tracks = ((dict["tracks"] as? [Any]) ?? []).compactMap { ($0 as? [String: Any]).flatMap(track) }
            return .playlist(ServicePlaylistContents(summary: summary, tracks: tracks))
        default:
            return nil
        }
    }

    // MARK: - Private

    /// `{collection: [...], next_href: ...}` or a bare array.
    private static func envelope(_ data: Data) -> ([Any], URL?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return ([], nil) }
        if let list = root as? [Any] { return (list, nil) }
        guard let dict = root as? [String: Any] else { return ([], nil) }
        let list = (dict["collection"] as? [Any]) ?? []
        return (list, (dict["next_href"] as? String).flatMap(URL.init(string:)))
    }

    private static func playlistSummary(_ dict: [String: Any]) -> ServicePlaylistSummary? {
        guard let title = dict["title"] as? String, !title.isEmpty else { return nil }
        guard let urn = (dict["urn"] as? String) ?? (dict["id"] as? NSNumber).map({ "soundcloud:playlists:\($0.intValue)" }) else { return nil }
        let setType = (dict["set_type"] as? String) ?? (dict["playlist_type"] as? String) ?? ""
        let isAlbum = (dict["is_album"] as? Bool) ?? (!setType.isEmpty && setType != "playlist")
        let count = (dict["track_count"] as? NSNumber)?.intValue ?? (dict["tracks"] as? [Any])?.count
        return ServicePlaylistSummary(
            service: .soundcloud,
            sourceID: urn,
            kind: isAlbum ? .album : .playlist,
            name: title,
            ownerName: JSONNav.string(dict, ["user", "username"]),
            trackCount: count
        )
    }

    private static func track(_ dict: [String: Any]) -> ServiceTrack? {
        if let kind = dict["kind"] as? String, kind != "track" { return nil }
        guard let title = dict["title"] as? String, !title.isEmpty else { return nil }
        let id = (dict["id"] as? NSNumber)?.intValue
            ?? (dict["urn"] as? String).flatMap { $0.split(separator: ":").last.flatMap { Int($0) } }
            ?? 0
        let ms = (dict["duration"] as? NSNumber)?.doubleValue
        let soundcloud = SoundCloudTrack(
            id: id,
            title: title,
            artist: JSONNav.string(dict, ["publisher_metadata", "artist"]) ?? JSONNav.string(dict, ["user", "username"]),
            durationSeconds: ms.flatMap { $0 > 0 ? Int(($0 / 1000).rounded()) : nil },
            permalinkURL: dict["permalink_url"] as? String
        )
        return ServiceTrack(soundcloud)
    }
}
