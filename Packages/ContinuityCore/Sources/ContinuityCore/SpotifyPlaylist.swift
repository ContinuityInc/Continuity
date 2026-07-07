import Foundation

/// One track parsed out of a Spotify playlist/album. There is **no audio here** — Spotify audio is
/// DRM-protected and unusable by our engine — only the metadata we need to re-source the song from
/// YouTube (title + artist).
public struct SpotifyTrack: Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var durationSeconds: Int?

    public init(title: String, artist: String? = nil, durationSeconds: Int? = nil) {
        self.title = title
        self.artist = artist
        self.durationSeconds = durationSeconds
    }

    /// Query used to find this song on YouTube, e.g. "Blinding Lights The Weeknd".
    public var youtubeSearchQuery: String {
        [title, artist].compactMap { $0 }.joined(separator: " ")
    }
}

/// The parsed contents of a Spotify playlist/album page: its tracks (in order) and its name.
public struct SpotifyPlaylistContents: Equatable, Sendable {
    public var name: String?
    public var tracks: [SpotifyTrack]

    public init(name: String? = nil, tracks: [SpotifyTrack]) {
        self.name = name
        self.tracks = tracks
    }

    public var isEmpty: Bool { tracks.isEmpty }
}

/// Pure extraction of a playlist/album's tracks from the HTML of a Spotify **embed** page
/// (`open.spotify.com/embed/playlist/{id}`), which ships the data as a `__NEXT_DATA__` JSON blob
/// containing a `trackList` (each entry has `title`, `subtitle` = artist, `duration` in ms).
///
/// **No networking** — the app layer fetches the HTML. As with the YouTube scraper this is
/// **fragile** (Spotify can change the embed shape) so it's pinned by unit tests. The embed page
/// lists ~50 tracks; longer playlists would need pagination (a later refinement).
public enum SpotifyPlaylist {

    /// Parses the HTML of a Spotify embed page into its (ordered) tracks + name.
    public static func parse(html: String) -> SpotifyPlaylistContents {
        guard let json = nextDataJSON(in: html),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return SpotifyPlaylistContents(tracks: [])
        }

        // The playlist/album entity holds `trackList` alongside its `name`/`title`.
        guard let container = JSONNav.firstDictContaining(root, key: "trackList"),
              let list = container["trackList"] as? [Any] else {
            return SpotifyPlaylistContents(tracks: [])
        }
        let name = (container["name"] as? String) ?? (container["title"] as? String)

        let tracks: [SpotifyTrack] = list.compactMap { entry in
            guard let dict = entry as? [String: Any] else { return nil }
            // Skip podcast episodes / non-track rows.
            if let type = dict["entityType"] as? String, type != "track" { return nil }
            guard let title = (dict["title"] as? String), !title.isEmpty else { return nil }

            let artist = (dict["subtitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let ms = (dict["duration"] as? NSNumber)?.doubleValue
            let seconds = ms.map { Int(($0 / 1000).rounded()) }
            return SpotifyTrack(title: title, artist: artist, durationSeconds: seconds)
        }

        return SpotifyPlaylistContents(name: name, tracks: tracks)
    }

    /// Returns the contents of the `<script id="__NEXT_DATA__" …>{ … }</script>` tag.
    static func nextDataJSON(in html: String) -> String? {
        guard let idRange = html.range(of: "id=\"__NEXT_DATA__\""),
              let tagEnd = html[idRange.upperBound...].firstIndex(of: ">") else { return nil }
        let contentStart = html.index(after: tagEnd)
        guard let closeRange = html.range(of: "</script>", range: contentStart..<html.endIndex) else { return nil }
        return String(html[contentStart..<closeRange.lowerBound])
    }
}
