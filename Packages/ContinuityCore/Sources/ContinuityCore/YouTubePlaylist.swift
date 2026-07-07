import Foundation

/// One video entry parsed out of a YouTube playlist page.
public struct YouTubePlaylistItem: Equatable, Sendable {
    public var videoID: String
    public var title: String?
    public var author: String?
    public var lengthSeconds: Int?

    public init(videoID: String, title: String? = nil, author: String? = nil, lengthSeconds: Int? = nil) {
        self.videoID = videoID
        self.title = title
        self.author = author
        self.lengthSeconds = lengthSeconds
    }
}

/// The parsed contents of a YouTube playlist page: its videos (in order) and, when present,
/// the playlist's own title.
public struct YouTubePlaylistContents: Equatable, Sendable {
    public var title: String?
    public var items: [YouTubePlaylistItem]

    public init(title: String? = nil, items: [YouTubePlaylistItem]) {
        self.title = title
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
}

/// Pure extraction of a playlist's videos from the HTML of a `youtube.com/playlist?list=…`
/// page. YouTube embeds the data as a `ytInitialData = {…}` JSON blob inside a `<script>` tag;
/// this locates that object, parses it, and walks it for video entries.
///
/// As of 2026 the page ships videos as **`lockupViewModel`** nodes (`contentId` = video ID,
/// `lockupMetadataViewModel` = title/author, a duration badge for length). We also still parse
/// the older **`playlistVideoRenderer`** shape so the app keeps working if YouTube serves it
/// (e.g. via a different client/surface). Entries from either shape are merged in document order
/// and de-duplicated by video ID.
///
/// **No networking** — the app layer fetches the HTML and hands it here. Keeping the brittle
/// scraping in ContinuityCore means every shape we depend on is pinned by unit tests. Treat this
/// as fragile: YouTube can change the embedded shape at any time (as it did with lockups).
///
/// **Coverage note:** the first page load lists up to ~100 videos; longer playlists paginate via
/// continuation tokens we don't yet follow — enough for albums/typical playlists.
public enum YouTubePlaylist {

    /// Parses the HTML of a playlist page into its (de-duplicated, ordered) videos + title.
    /// Returns empty contents if no `ytInitialData` / no video entries are found.
    public static func parse(html: String) -> YouTubePlaylistContents {
        guard let json = extractBracedObject(in: html, afterMarker: "ytInitialData"),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return YouTubePlaylistContents(items: [])
        }

        var seen = Set<String>()
        var items: [YouTubePlaylistItem] = []
        func consider(_ item: YouTubePlaylistItem?) {
            guard let item, YouTubeURL.isValidVideoID(item.videoID), !seen.contains(item.videoID) else { return }
            seen.insert(item.videoID)
            items.append(item)
        }

        walkDicts(root) { dict in
            if let lockup = dict["lockupViewModel"] as? [String: Any] {
                consider(lockupItem(lockup))
            }
            if let legacy = dict["playlistVideoRenderer"] as? [String: Any] {
                consider(legacyItem(legacy))
            }
        }

        return YouTubePlaylistContents(title: extractTitle(root), items: items)
    }

    // MARK: - JSON extraction from HTML

    /// Returns the JSON-object substring (`{ … }`) that follows `marker` in `html`, matching
    /// braces while respecting string literals so nested `{`/`}` inside values don't fool it.
    static func extractBracedObject(in html: String, afterMarker marker: String) -> String? {
        guard let markerRange = html.range(of: marker),
              let open = html[markerRange.upperBound...].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var inString = false
        var escaped = false
        var i = open
        while i < html.endIndex {
            let c = html[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(html[open...i]) }
                default: break
                }
            }
            i = html.index(after: i)
        }
        return nil
    }

    // MARK: - Item extraction (per shape)

    /// New (2026) shape: a `lockupViewModel` for one playlist video.
    private static func lockupItem(_ lockup: [String: Any]) -> YouTubePlaylistItem? {
        // Only videos have a playable ID; skip nested-playlist / other lockups.
        if let contentType = lockup["contentType"] as? String, !contentType.contains("VIDEO") { return nil }
        guard let videoID = lockup["contentId"] as? String else { return nil }

        let meta = dict(lockup, "metadata", "lockupMetadataViewModel")
        let title = string(meta, "title", "content")
        let author = lockupAuthor(meta)
        let length = firstClock(in: lockup)
        return YouTubePlaylistItem(videoID: videoID, title: title, author: author, lengthSeconds: length)
    }

    /// Author = first text part of the first metadata row (the channel/artist line).
    private static func lockupAuthor(_ meta: [String: Any]?) -> String? {
        guard let cmv = dict(meta, "metadata", "contentMetadataViewModel"),
              let rows = cmv["metadataRows"] as? [[String: Any]],
              let firstRow = rows.first,
              let parts = firstRow["metadataParts"] as? [[String: Any]] else { return nil }
        for part in parts {
            if let text = string(part, "text", "content"), !text.isEmpty { return text }
        }
        return nil
    }

    /// Legacy shape: a `playlistVideoRenderer`.
    private static func legacyItem(_ renderer: [String: Any]) -> YouTubePlaylistItem? {
        guard let videoID = renderer["videoId"] as? String else { return nil }
        return YouTubePlaylistItem(
            videoID: videoID,
            title: runsText(renderer["title"]),
            author: runsText(renderer["shortBylineText"]),
            lengthSeconds: legacyLength(renderer)
        )
    }

    private static func legacyLength(_ renderer: [String: Any]) -> Int? {
        if let raw = renderer["lengthSeconds"] as? String, let secs = Int(raw) { return secs }
        if let clock = runsText(renderer["lengthText"]) { return parseClock(clock) }
        return nil
    }

    // MARK: - JSON walking helpers

    /// Visits every dictionary node in the tree (pre-order).
    private static func walkDicts(_ node: Any, _ visit: ([String: Any]) -> Void) {
        if let dict = node as? [String: Any] {
            visit(dict)
            for value in dict.values { walkDicts(value, visit) }
        } else if let array = node as? [Any] {
            for value in array { walkDicts(value, visit) }
        }
    }

    /// First dictionary anywhere in the tree stored under `key`.
    private static func firstDict(_ node: Any, key: String) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if let match = dict[key] as? [String: Any] { return match }
            for value in dict.values {
                if let found = firstDict(value, key: key) { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let found = firstDict(value, key: key) { return found }
            }
        }
        return nil
    }

    /// Navigates a chain of dictionary keys, returning the dictionary at the end (or nil).
    private static func dict(_ node: [String: Any]?, _ keys: String...) -> [String: Any]? {
        var current = node
        for key in keys { current = current?[key] as? [String: Any] }
        return current
    }

    /// Navigates a chain of dictionary keys, returning the trailing string value (or nil).
    private static func string(_ node: [String: Any]?, _ keys: String...) -> String? {
        var current: Any? = node
        for key in keys { current = (current as? [String: Any])?[key] }
        return current as? String
    }

    /// Flattens a YouTube text node — `{ "simpleText": … }` or `{ "runs": [{ "text": … }] }` —
    /// into a plain string.
    private static func runsText(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            let text = runs.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    /// Recursively finds the first clock-formatted (`m:ss` / `h:mm:ss`) string stored under a
    /// `"text"` key — that's the duration badge inside a lockup's thumbnail overlay.
    private static func firstClock(in node: Any) -> Int? {
        if let dict = node as? [String: Any] {
            if let text = dict["text"] as? String, isClock(text), let secs = parseClock(text) { return secs }
            for value in dict.values {
                if let secs = firstClock(in: value) { return secs }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let secs = firstClock(in: value) { return secs }
            }
        }
        return nil
    }

    /// True for "m:ss" / "h:mm:ss" (each segment after the first is exactly two digits).
    static func isClock(_ text: String) -> Bool {
        let parts = text.split(separator: ":")
        guard (2...3).contains(parts.count) else { return false }
        for (index, part) in parts.enumerated() {
            if part.isEmpty || !part.allSatisfy(\.isNumber) { return false }
            if index > 0 && part.count != 2 { return false }
        }
        return true
    }

    /// Parses "m:ss" or "h:mm:ss" into total seconds.
    static func parseClock(_ text: String) -> Int? {
        let parts = text.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    /// The playlist's own title, from whichever renderer carries it in this page shape.
    private static func extractTitle(_ root: Any) -> String? {
        if let meta = firstDict(root, key: "playlistMetadataRenderer"), let t = meta["title"] as? String, !t.isEmpty {
            return t
        }
        if let header = firstDict(root, key: "playlistHeaderRenderer"), let t = runsText(header["title"]) {
            return t
        }
        if let micro = firstDict(root, key: "microformatDataRenderer"), let t = micro["title"] as? String, !t.isEmpty {
            return t
        }
        return nil
    }
}
