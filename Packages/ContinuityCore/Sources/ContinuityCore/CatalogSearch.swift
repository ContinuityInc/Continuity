import Foundation

/// Pure query planning, response parsing, and ranking for Apple's **iTunes Search / Lookup**
/// catalog (metadata only — Continuity still re-sources audio on YouTube).
///
/// Why this lives in Core: the public Search endpoint quietly stopped returning
/// `trackExplicitness == "explicit"` rows (only `cleaned` / `notExplicit`), while
/// `/lookup?id=<artistId>&entity=song|album` still does. Coverage for explicit tracks
/// therefore depends on a small, testable merge of search hits + artist-lookup upgrades —
/// not on MusicKit (which would need the MusicKit App Service and break cloud signing).
public enum CatalogSearch {

    // MARK: - Explicitness

    public enum Explicitness: String, Equatable, Sendable, CaseIterable {
        case explicit
        case cleaned
        case notExplicit
        case unknown

        init(apiValue: String?) {
            switch apiValue {
            case "explicit": self = .explicit
            case "cleaned": self = .cleaned
            case "notExplicit": self = .notExplicit
            default: self = .unknown
            }
        }

        /// Higher is better when two hits are the same song/album. Explicit wins so the
        /// YouTube query gets the uncensored title and the row the user actually wants.
        var preference: Int {
            switch self {
            case .explicit: return 3
            case .notExplicit: return 2
            case .unknown: return 1
            case .cleaned: return 0
            }
        }
    }

    public enum Kind: String, Equatable, Sendable {
        case song
        case album
        case artist
    }

    /// One normalized catalog row after parsing. Networking stays in Ingest; this is the
    /// shape ranking / dedupe operate on.
    public struct Hit: Equatable, Sendable {
        public var id: Int
        public var kind: Kind
        public var title: String
        public var artist: String
        public var album: String?
        public var artistID: Int?
        public var durationMilliseconds: Double?
        public var trackCount: Int?
        public var artworkURLString: String?
        public var releaseDate: String?
        public var explicitness: Explicitness

        public init(
            id: Int,
            kind: Kind,
            title: String,
            artist: String,
            album: String? = nil,
            artistID: Int? = nil,
            durationMilliseconds: Double? = nil,
            trackCount: Int? = nil,
            artworkURLString: String? = nil,
            releaseDate: String? = nil,
            explicitness: Explicitness = .unknown
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.artist = artist
            self.album = album
            self.artistID = artistID
            self.durationMilliseconds = durationMilliseconds
            self.trackCount = trackCount
            self.artworkURLString = artworkURLString
            self.releaseDate = releaseDate
            self.explicitness = explicitness
        }

        public var releaseYear: Int? {
            releaseDate.flatMap { Int($0.prefix(4)) }
        }

        /// Stable key for clean/explicit variants of the same recording.
        public var identityKey: String {
            CatalogSearch.identityKey(title: title, artist: artist)
        }
    }

    // MARK: - Query planning

    /// Fan-out terms for one user query. Kept small (≤4) so interactive search stays snappy.
    ///
    /// - original trimmed term
    /// - without Clean/Explicit parentheticals or trailing markers
    /// - quoted "title" + artist when the query looks like `title - artist` / `title artist`
    /// - artist-first reordering when a dash/pipe separator is present
    public static func queryVariants(from term: String) -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var ordered: [String] = []
        func push(_ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty, !ordered.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) else { return }
            ordered.append(v)
        }

        push(trimmed)

        let stripped = stripExplicitMarkers(trimmed)
        push(stripped)

        if let split = splitTitleArtist(stripped) {
            push("\(split.title) \(split.artist)")
            push("\"\(split.title)\" \(split.artist)")
            // Artist-leading helps when the user typed "Kendrick HUMBLE" vs title-first.
            push("\(split.artist) \(split.title)")
        }

        return Array(ordered.prefix(4))
    }

    /// Removes `(Clean)`, `[Explicit]`, trailing "clean"/"explicit" tokens that hide the
    /// catalog's real title match.
    public static func stripExplicitMarkers(_ term: String) -> String {
        var s = term
        let patterns = [
            #"\((?i:clean|explicit|edited|radio\s*edit)\)"#,
            #"\[(?i:clean|explicit|edited|radio\s*edit)\]"#,
            #"(?i)\s+[-–—]?\s*(clean|explicit)\s*$"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
            }
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best-effort title/artist split for `Title - Artist`, `Title – Artist`, `Title | Artist`.
    public static func splitTitleArtist(_ term: String) -> (title: String, artist: String)? {
        let separators = [" - ", " – ", " — ", " | ", " / "]
        for sep in separators {
            if let range = term.range(of: sep) {
                let title = String(term[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let artist = String(term[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty, !artist.isEmpty { return (title, artist) }
            }
        }
        return nil
    }

    // MARK: - URL building (no networking)

    public static let searchBase = URL(string: "https://itunes.apple.com/search")!
    public static let lookupBase = URL(string: "https://itunes.apple.com/lookup")!

    /// Song/album search query items. Always requests explicit inclusion — the endpoint may
    /// still omit `explicit` rows; artist lookup is what upgrades them.
    public static func searchQueryItems(
        term: String,
        entity: String,
        limit: Int,
        country: String = "us"
    ) -> [URLQueryItem] {
        [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 200)))),
            URLQueryItem(name: "explicit", value: "Yes"),
            URLQueryItem(name: "country", value: country),
        ]
    }

    public static func lookupQueryItems(
        id: Int,
        entity: String,
        limit: Int,
        country: String = "us"
    ) -> [URLQueryItem] {
        [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 200)))),
            URLQueryItem(name: "country", value: country),
        ]
    }

    public static func url(base: URL, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        return components?.url
    }

    // MARK: - Parsing

    /// Decodes an iTunes Search/Lookup JSON body into hits. Tolerates missing fields —
    /// Apple's payload is a shared bag for artists, songs, and albums.
    public static func parseResponse(_ data: Data) -> [Hit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [Any] else {
            return []
        }
        return results.compactMap { entry in
            guard let dict = entry as? [String: Any] else { return nil }
            return parseHit(dict)
        }
    }

    public static func parseHit(_ dict: [String: Any]) -> Hit? {
        let wrapper = dict["wrapperType"] as? String

        // Artist-only rows from musicArtist search / artist lookup echo.
        if wrapper == "artist" {
            guard let id = intValue(dict["artistId"]),
                  let name = dict["artistName"] as? String else { return nil }
            return Hit(id: id, kind: .artist, title: name, artist: name, artistID: id)
        }

        // Albums / collections — must beat the song branch because some album echoes omit `kind`.
        if wrapper == "collection" || (dict["collectionId"] != nil && dict["trackId"] == nil) {
            guard let id = intValue(dict["collectionId"]),
                  let title = dict["collectionName"] as? String,
                  let artist = dict["artistName"] as? String else { return nil }
            return Hit(
                id: id,
                kind: .album,
                title: title,
                artist: artist,
                album: title,
                artistID: intValue(dict["artistId"]),
                trackCount: intValue(dict["trackCount"]),
                artworkURLString: dict["artworkUrl100"] as? String,
                releaseDate: dict["releaseDate"] as? String,
                explicitness: Explicitness(apiValue: dict["collectionExplicitness"] as? String)
            )
        }

        // Songs (and song-like tracks).
        guard let id = intValue(dict["trackId"]),
              let title = dict["trackName"] as? String,
              let artist = dict["artistName"] as? String else { return nil }
        return Hit(
            id: id,
            kind: .song,
            title: title,
            artist: artist,
            album: dict["collectionName"] as? String,
            artistID: intValue(dict["artistId"]),
            durationMilliseconds: doubleValue(dict["trackTimeMillis"]),
            artworkURLString: dict["artworkUrl100"] as? String,
            releaseDate: dict["releaseDate"] as? String,
            explicitness: Explicitness(apiValue: dict["trackExplicitness"] as? String)
        )
    }

    // MARK: - Ranking / merge

    /// Merges search + lookup batches into a ranked song list. Explicit variants replace
    /// cleaned siblings; karaoke/tribute noise is demoted.
    public static func rankSongs(query: String, batches: [[Hit]], limit: Int) -> [Hit] {
        rank(query: query, kind: .song, batches: batches, limit: limit)
    }

    public static func rankAlbums(query: String, batches: [[Hit]], limit: Int) -> [Hit] {
        rank(query: query, kind: .album, batches: batches, limit: limit)
    }

    /// Artist IDs worth looking up for explicit upgrades, in relevance order.
    public static func artistIDsForUpgrade(from hits: [Hit], limit: Int = 3) -> [Int] {
        var seen = Set<Int>()
        var ids: [Int] = []
        for hit in hits {
            guard let id = hit.artistID, seen.insert(id).inserted else { continue }
            ids.append(id)
            if ids.count >= limit { break }
        }
        return ids
    }

    /// Among albums with the same identity, prefer the explicit collection (for tracklist
    /// import). Returns the preferred id when an upgrade exists.
    public static func preferredAlbumID(among albums: [Hit], matching cleaned: Hit) -> Int {
        let key = cleaned.identityKey
        let siblings = albums.filter { $0.kind == .album && $0.identityKey == key }
        guard let best = siblings.max(by: { lhs, rhs in
            if lhs.explicitness.preference != rhs.explicitness.preference {
                return lhs.explicitness.preference < rhs.explicitness.preference
            }
            return lhs.id < rhs.id
        }) else {
            return cleaned.id
        }
        return best.id
    }

    private static func rank(query: String, kind: Kind, batches: [[Hit]], limit: Int) -> [Hit] {
        let normalizedQuery = normalize(query)
        let tokens = tokenSet(normalizedQuery)

        var bestByIdentity: [String: (hit: Hit, score: Int)] = [:]

        for (batchIndex, batch) in batches.enumerated() {
            for (rowIndex, raw) in batch.enumerated() where raw.kind == kind {
                let score = relevanceScore(hit: raw, normalizedQuery: normalizedQuery, tokens: tokens)
                    // Stable preference for earlier batches / earlier rows when scores tie.
                    - batchIndex
                    - rowIndex / 100
                let key = raw.identityKey
                if let existing = bestByIdentity[key] {
                    let betterExplicit = raw.explicitness.preference > existing.hit.explicitness.preference
                    let betterScore = score > existing.score
                        && raw.explicitness.preference >= existing.hit.explicitness.preference
                    if betterExplicit || betterScore {
                        bestByIdentity[key] = (raw, max(score, existing.score))
                    }
                } else {
                    bestByIdentity[key] = (raw, score)
                }
            }
        }

        let ranked = bestByIdentity.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.hit.explicitness.preference != rhs.hit.explicitness.preference {
                return lhs.hit.explicitness.preference > rhs.hit.explicitness.preference
            }
            return lhs.hit.id < rhs.hit.id
        }
        return Array(ranked.prefix(max(0, limit)).map(\.hit))
    }

    /// Relevance score — higher is better. Tuned against karaoke/cover pollution that used
    /// to crowd out the real catalog row (and its explicit sibling after lookup).
    public static func relevanceScore(hit: Hit, normalizedQuery: String, tokens: Set<String>) -> Int {
        let title = normalize(hit.title)
        let artist = normalize(hit.artist)
        let haystack = title + " " + artist

        var score = 0
        if title == normalizedQuery || haystack == normalizedQuery { score += 120 }
        if title.hasPrefix(normalizedQuery) { score += 40 }
        if haystack.contains(normalizedQuery) { score += 30 }

        if !tokens.isEmpty {
            let titleTokens = tokenSet(title)
            let artistTokens = tokenSet(artist)
            let covered = tokens.filter { titleTokens.contains($0) || artistTokens.contains($0) }.count
            score += covered * 18
            let missing = tokens.count - covered
            score -= missing * 12
        }

        score += hit.explicitness.preference * 8

        let noise = title + " " + artist + " " + (hit.album.map(normalize) ?? "")
        for word in Self.noiseTokens where noise.contains(word) {
            score -= 50
        }
        return score
    }

    public static func identityKey(title: String, artist: String) -> String {
        normalize(stripFeaturing(title)) + "|" + normalize(primaryArtist(artist))
    }

    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var s = folded.lowercased()
        s = stripExplicitMarkers(s)
        s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        // Keep letters/digits; collapse the rest so "HUMBLE." == "humble"
        s = s.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func tokenSet(_ normalized: String) -> Set<String> {
        Set(normalized.split(separator: " ").map(String.init).filter { $0.count > 1 })
    }

    public static func stripFeaturing(_ title: String) -> String {
        let patterns = [
            #"(?i)\s*\(feat\.?[^)]*\)"#,
            #"(?i)\s*\[feat\.?[^\]]*\]"#,
            #"(?i)\s+feat\.?\s+.+$"#,
            #"(?i)\s+ft\.?\s+.+$"#,
        ]
        var s = title
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func primaryArtist(_ artist: String) -> String {
        let cutChars = CharacterSet(charactersIn: ",&/")
        if let idx = artist.unicodeScalars.firstIndex(where: { cutChars.contains($0) }) {
            return String(artist[..<idx]).trimmingCharacters(in: .whitespaces)
        }
        if let range = artist.range(of: " and ", options: .caseInsensitive) {
            return String(artist[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return artist
    }

    private static let noiseTokens: [String] = [
        "karaoke", "tribute", "lullaby", "backing track", "in the style of",
        "originally performed", "instrumental version", "sleep remix", "made famous by",
    ]

    // MARK: - JSON helpers

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
}
