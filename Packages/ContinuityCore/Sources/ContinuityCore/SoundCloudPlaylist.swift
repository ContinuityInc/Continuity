import Foundation

/// One track parsed out of a SoundCloud set or page. **No audio here** — SoundCloud streams are
/// gated behind a scraped client key and the platform's terms, so like Spotify and Apple Music we
/// keep the metadata and re-source the recording from YouTube via `youtubeSearchQuery`.
public struct SoundCloudTrack: Equatable, Sendable {
    /// SoundCloud's numeric track id.
    public var id: Int
    public var title: String
    /// `publisher_metadata.artist` when the uploader filled it in, else the uploader's username.
    public var artist: String?
    public var durationSeconds: Int?
    public var permalinkURL: String?

    public init(id: Int, title: String, artist: String? = nil, durationSeconds: Int? = nil, permalinkURL: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.durationSeconds = durationSeconds
        self.permalinkURL = permalinkURL
    }

    /// Query used to find this recording on YouTube.
    ///
    /// SoundCloud titles usually already carry the artist ("Fred again.. - Marea") and often a
    /// promo tag ("[Free Download]", "(Out Now)") that YouTube titles never repeat, so the tag is
    /// stripped and the uploader is only appended when the title doesn't already name them —
    /// uploaders are frequently labels/channels, and doubling up buries the real upload.
    public var youtubeSearchQuery: String {
        let cleaned = SoundCloudPlaylist.normalizedTitle(title)
        guard let artist, !artist.isEmpty else { return cleaned }
        if cleaned.localizedCaseInsensitiveContains(artist) || cleaned.contains(" - ") {
            return cleaned
        }
        return "\(cleaned) \(artist)"
    }
}

/// The parsed contents of a SoundCloud set (playlist or album) page.
///
/// SoundCloud hydrates only the first few tracks of a set into the page; the rest appear as
/// `{id, kind: "track"}` stubs the resolver must fetch separately. `trackIDs` is the full order,
/// `hydratedTracks` what the page already contained, and `assembled(with:)` merges fetched stubs
/// back into position.
public struct SoundCloudPlaylistContents: Equatable, Sendable {
    public var title: String?
    public var isAlbum: Bool
    /// Every track id in set order, hydrated or not.
    public var trackIDs: [Int]
    /// Tracks the page carried in full, in set order.
    public var hydratedTracks: [SoundCloudTrack]

    public init(title: String? = nil, isAlbum: Bool = false, trackIDs: [Int], hydratedTracks: [SoundCloudTrack]) {
        self.title = title
        self.isAlbum = isAlbum
        self.trackIDs = trackIDs
        self.hydratedTracks = hydratedTracks
    }

    public var isEmpty: Bool { trackIDs.isEmpty }

    /// Ids the page only stubbed — what still has to be fetched from the API.
    public var pendingTrackIDs: [Int] {
        let have = Set(hydratedTracks.map(\.id))
        return trackIDs.filter { !have.contains($0) }
    }

    /// Hydrated + separately fetched tracks in set order. Ids nobody could resolve (deleted,
    /// geo-blocked) are dropped rather than left as placeholders.
    public func assembled(with fetched: [SoundCloudTrack]) -> [SoundCloudTrack] {
        var byID: [Int: SoundCloudTrack] = [:]
        for track in hydratedTracks { byID[track.id] = track }
        for track in fetched where byID[track.id] == nil { byID[track.id] = track }
        return trackIDs.compactMap { byID[$0] }
    }
}

/// Pure extraction of SoundCloud page data. SoundCloud renders a `window.__sc_hydration = [...]`
/// JSON array into each page; the `"playlist"` (set page) or `"sound"` (track page) entry holds
/// the entity. The remaining stubs are fetched from `api-v2.soundcloud.com/tracks?ids=…`, which
/// needs a `client_id` that only exists inside the site's JavaScript bundles — `scriptURLs` +
/// `clientID(inScript:)` recover it the way the web app does.
///
/// **No networking** — the Ingest layer fetches and hands strings/Data in. Fragile by nature
/// (SoundCloud can reshape its hydration), so every shape is pinned by unit tests.
public enum SoundCloudPlaylist {

    /// The set entity on a `soundcloud.com/{user}/sets/{slug}` page, or nil when the page has no
    /// playlist hydration (private without token, deleted, or a shape change).
    public static func parsePlaylist(html: String) -> SoundCloudPlaylistContents? {
        guard let data = hydrationEntry(html: html, kind: "playlist") else { return nil }
        let isAlbum = (data["is_album"] as? Bool) ?? ((data["set_type"] as? String).map { !$0.isEmpty && $0 != "playlist" } ?? false)
        let rawTracks = (data["tracks"] as? [Any]) ?? []

        var ids: [Int] = []
        var hydrated: [SoundCloudTrack] = []
        var seen = Set<Int>()
        for entry in rawTracks {
            guard let dict = entry as? [String: Any], let id = integer(dict["id"]), seen.insert(id).inserted else { continue }
            ids.append(id)
            if let track = track(from: dict) { hydrated.append(track) }
        }
        return SoundCloudPlaylistContents(
            title: nonEmpty(data["title"] as? String),
            isAlbum: isAlbum,
            trackIDs: ids,
            hydratedTracks: hydrated
        )
    }

    /// The track entity on a `soundcloud.com/{user}/{slug}` page.
    public static func parseTrack(html: String) -> SoundCloudTrack? {
        guard let data = hydrationEntry(html: html, kind: "sound") else { return nil }
        return track(from: data)
    }

    /// Parses an `api-v2.soundcloud.com/tracks?ids=…` reply (a JSON array of track objects).
    /// Order is the API's, not the request's — callers reorder via `assembled(with:)`.
    public static func parseTracksResponse(_ data: Data) -> [SoundCloudTrack] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list = (root as? [Any]) ?? ((root as? [String: Any])?["collection"] as? [Any]) ?? []
        return list.compactMap { ($0 as? [String: Any]).flatMap(track(from:)) }
    }

    /// Request URL for one batch of stub ids. SoundCloud caps `ids` at 50 per call.
    public static let tracksBatchSize = 50
    public static func tracksRequestURL(ids: [Int], clientID: String) -> URL? {
        var comps = URLComponents(string: "https://api-v2.soundcloud.com/tracks")
        comps?.queryItems = [
            URLQueryItem(name: "ids", value: ids.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        return comps?.url
    }

    /// The site's JavaScript bundle URLs (`<script src="https://a-v2.sndcdn.com/assets/….js">`),
    /// in document order. The `client_id` lives in one of the later chunks, so callers scan from
    /// the end.
    public static func scriptURLs(html: String) -> [URL] {
        var urls: [URL] = []
        var searchRange = html.startIndex..<html.endIndex
        while let range = html.range(of: "<script", range: searchRange) {
            guard let tagEnd = html[range.upperBound...].firstIndex(of: ">") else { break }
            let tag = html[range.upperBound..<tagEnd]
            if let src = attribute("src", in: tag), src.contains("sndcdn.com/assets/"), src.hasSuffix(".js"),
               let url = URL(string: src) {
                urls.append(url)
            }
            searchRange = tagEnd..<html.endIndex
        }
        return urls
    }

    /// Finds the 32-character `client_id` literal inside one JavaScript bundle (`client_id:"…"`
    /// or `client_id=…`), or nil if this chunk doesn't carry it.
    public static func clientID(inScript script: String) -> String? {
        for marker in ["client_id:\"", "client_id=\"", "client_id=", "clientId:\""] {
            var searchRange = script.startIndex..<script.endIndex
            while let range = script.range(of: marker, range: searchRange) {
                let candidate = script[range.upperBound...].prefix(32)
                if candidate.count == 32, candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                    return String(candidate)
                }
                searchRange = range.upperBound..<script.endIndex
            }
        }
        return nil
    }

    /// Strips SoundCloud's promo decorations from a title: bracketed groups that are only
    /// marketing ("[Free Download]", "(OUT NOW)", "[Premiere]") and a trailing "| Free DL".
    /// Anything that identifies the recording — remix credits, "(Live)", "(feat. …)" — is kept.
    public static func normalizedTitle(_ title: String) -> String {
        var result = ""
        var segment = ""
        var closing: Character?
        for character in title {
            if let expected = closing {
                if character == expected {
                    if !isPromoNoise(segment) {
                        result.append(expected == ")" ? "(" : "[")
                        result.append(segment)
                        result.append(expected)
                    }
                    segment = ""
                    closing = nil
                } else {
                    segment.append(character)
                }
            } else if character == "(" {
                closing = ")"
            } else if character == "[" {
                closing = "]"
            } else {
                result.append(character)
            }
        }
        if let expected = closing {
            result.append(expected == ")" ? "(" : "[")
            result.append(segment)
        }
        // "Title | Free Download" / "Title *FREE DL*" tails.
        for separator in [" | ", " * "] {
            if let range = result.range(of: separator), isPromoNoise(String(result[range.upperBound...])) {
                result = String(result[..<range.lowerBound])
            }
        }
        let collapsed = result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return collapsed.isEmpty ? title.trimmingCharacters(in: .whitespaces) : collapsed
    }

    private static let promoNoise = [
        "free download", "free dl", "out now", "buy now", "premiere", "click buy", "download in description",
        "available now", "link in bio", "supported by", "forthcoming", "snippet", "preview", "teaser",
    ]

    private static func isPromoNoise(_ segment: String) -> Bool {
        let lowered = segment.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return true }
        return promoNoise.contains { lowered.contains($0) }
    }

    // MARK: - Hydration

    /// The `data` object of the hydration entry whose `hydratable` is `kind`.
    static func hydrationEntry(html: String, kind: String) -> [String: Any]? {
        guard let json = JSONNav.balancedLiteral(in: html, afterMarker: "__sc_hydration", open: "[", close: "]"),
              let data = json.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        for entry in entries {
            guard let dict = entry as? [String: Any], dict["hydratable"] as? String == kind else { continue }
            return dict["data"] as? [String: Any]
        }
        return nil
    }

    /// A full track object → `SoundCloudTrack`; nil for stubs (no title) and non-tracks.
    private static func track(from dict: [String: Any]) -> SoundCloudTrack? {
        if let kind = dict["kind"] as? String, kind != "track" { return nil }
        guard let id = integer(dict["id"]), let title = nonEmpty(dict["title"] as? String) else { return nil }
        let publisherArtist = nonEmpty(JSONNav.string(dict, ["publisher_metadata", "artist"]))
        let username = nonEmpty(JSONNav.string(dict, ["user", "username"]))
        let ms = (dict["duration"] as? NSNumber)?.doubleValue ?? (dict["full_duration"] as? NSNumber)?.doubleValue
        let seconds = ms.flatMap { $0 > 0 ? Int(($0 / 1000).rounded()) : nil }
        return SoundCloudTrack(
            id: id,
            title: title,
            artist: publisherArtist ?? username,
            durationSeconds: seconds,
            permalinkURL: dict["permalink_url"] as? String
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Value of `name="…"` / `name='…'` inside an HTML tag body.
    private static func attribute(_ name: String, in tag: Substring) -> String? {
        for quote: Character in ["\"", "'"] {
            guard let range = tag.range(of: "\(name)=\(quote)") else { continue }
            guard let end = tag[range.upperBound...].firstIndex(of: quote) else { continue }
            return String(tag[range.upperBound..<end])
        }
        return nil
    }
}
