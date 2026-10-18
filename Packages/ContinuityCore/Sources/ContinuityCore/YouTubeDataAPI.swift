import Foundation

/// Pure request-building and response-parsing for the **YouTube Data API v3** (the signed-in
/// path). A connected Google account lists the user's own playlists (private ones included) and
/// their Liked videos, and reads any playlist by id without scraping `ytInitialData`. Items carry
/// real video ids, so these tracks ingest directly — no YouTube search step.
public enum YouTubeDataAPI {
    public static let base = URL(string: "https://www.googleapis.com/youtube/v3")!
    /// YouTube's fixed id for the signed-in user's Liked videos.
    public static let likedVideosPlaylistID = "LL"
    public static let pageSize = 50

    // MARK: Requests

    public static func myPlaylistsURL(pageToken: String? = nil) -> URL {
        var query = ["part": "snippet,contentDetails", "mine": "true", "maxResults": "\(pageSize)"]
        if let pageToken { query["pageToken"] = pageToken }
        return base.appendingPathComponent("playlists").appendingQuery(query)
    }

    public static func playlistURL(id: String) -> URL {
        base.appendingPathComponent("playlists").appendingQuery(["part": "snippet,contentDetails", "id": id])
    }

    public static func playlistItemsURL(playlistID: String, pageToken: String? = nil) -> URL {
        var query = ["part": "snippet,contentDetails", "playlistId": playlistID, "maxResults": "\(pageSize)"]
        if let pageToken { query["pageToken"] = pageToken }
        return base.appendingPathComponent("playlistItems").appendingQuery(query)
    }

    public static func videosURL(ids: [String]) -> URL {
        base.appendingPathComponent("videos").appendingQuery(["part": "snippet,contentDetails", "id": ids.joined(separator: ",")])
    }

    /// The Liked-videos entry shown alongside the user's playlists (the API doesn't list it).
    public static var likedVideosSummary: ServicePlaylistSummary {
        ServicePlaylistSummary(service: .youtube, sourceID: likedVideosPlaylistID, kind: .likes, name: "Liked videos")
    }

    // MARK: Responses

    /// `GET /playlists?mine=true` page → summaries + `nextPageToken`.
    public static func parsePlaylistsPage(_ data: Data) -> ServicePage<ServicePlaylistSummary> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ServicePage(items: []) }
        let items = ((root["items"] as? [Any]) ?? []).compactMap { entry -> ServicePlaylistSummary? in
            guard let dict = entry as? [String: Any], let id = dict["id"] as? String,
                  let title = JSONNav.string(dict, ["snippet", "title"]) else { return nil }
            return ServicePlaylistSummary(
                service: .youtube,
                sourceID: id,
                kind: id == likedVideosPlaylistID ? .likes : .playlist,
                name: title,
                ownerName: JSONNav.string(dict, ["snippet", "channelTitle"]),
                trackCount: (JSONNav.dict(dict, ["contentDetails"])?["itemCount"] as? NSNumber)?.intValue
            )
        }
        return ServicePage(items: items, nextPageToken: root["nextPageToken"] as? String)
    }

    /// `GET /playlistItems` page → playable items + `nextPageToken`. Deleted/private videos
    /// (YouTube keeps the row with a placeholder title and no owner) are dropped.
    public static func parsePlaylistItemsPage(_ data: Data) -> ServicePage<ServiceTrack> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ServicePage(items: []) }
        var seen = Set<String>()
        let items = ((root["items"] as? [Any]) ?? []).compactMap { entry -> ServiceTrack? in
            guard let dict = entry as? [String: Any],
                  let videoID = JSONNav.string(dict, ["contentDetails", "videoId"]) ?? JSONNav.string(dict, ["snippet", "resourceId", "videoId"]),
                  YouTubeURL.isValidVideoID(videoID), seen.insert(videoID).inserted else { return nil }
            let title = JSONNav.string(dict, ["snippet", "title"])
            if title == "Deleted video" || title == "Private video" { return nil }
            let author = JSONNav.string(dict, ["snippet", "videoOwnerChannelTitle"])
            let length = (JSONNav.string(dict, ["contentDetails", "duration"])).flatMap(parseISO8601Duration)
            return ServiceTrack(YouTubePlaylistItem(videoID: videoID, title: title, author: author, lengthSeconds: length))
        }
        return ServicePage(items: items, nextPageToken: root["nextPageToken"] as? String)
    }

    /// `GET /videos?id=…` → durations by video id (playlistItems carries none).
    public static func parseVideoDurations(_ data: Data) -> [String: Int] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: Int] = [:]
        for case let dict as [String: Any] in (root["items"] as? [Any]) ?? [] {
            guard let id = dict["id"] as? String,
                  let iso = JSONNav.string(dict, ["contentDetails", "duration"]),
                  let seconds = parseISO8601Duration(iso) else { continue }
            result[id] = seconds
        }
        return result
    }

    /// `PT1H2M3S` → seconds. Only the H/M/S designators YouTube emits.
    public static func parseISO8601Duration(_ value: String) -> Int? {
        guard value.hasPrefix("PT") else { return value == "P0D" ? 0 : nil }
        var total = 0
        var number = ""
        for character in value.dropFirst(2) {
            if character.isNumber {
                number.append(character)
                continue
            }
            guard let n = Int(number) else { return nil }
            switch character {
            case "H": total += n * 3600
            case "M": total += n * 60
            case "S": total += n
            default: return nil
            }
            number = ""
        }
        return number.isEmpty ? total : nil
    }
}
