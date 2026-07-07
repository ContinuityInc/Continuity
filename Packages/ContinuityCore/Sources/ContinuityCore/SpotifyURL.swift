import Foundation

/// A Spotify link we can act on: a playlist or album, plus its base-62 ID.
public struct SpotifyLink: Equatable, Sendable {
    public enum Kind: String, Sendable { case playlist, album }
    public var kind: Kind
    public var id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// Pure parsing of Spotify playlist/album links into a `(kind, id)` pair. No networking — this
/// turns whatever a user pastes into something the resolver can fetch. Accepts the open.spotify.com
/// web links (including `/embed/…` and locale-prefixed `/intl-xx/…` paths, with or without `?si=`),
/// and the `spotify:` URI scheme. Locked down by unit tests.
public enum SpotifyURL {

    /// Parses a raw string. Returns nil if it isn't a recognisable Spotify playlist/album reference.
    public static func parse(_ raw: String) -> SpotifyLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // URI form: spotify:playlist:ID  /  spotify:album:ID  (optionally spotify:user:x:playlist:ID)
        if trimmed.lowercased().hasPrefix("spotify:") {
            let parts = trimmed.split(separator: ":").map(String.init)
            if let kindIndex = parts.firstIndex(where: { $0 == "playlist" || $0 == "album" }),
               kindIndex + 1 < parts.count,
               let kind = SpotifyLink.Kind(rawValue: parts[kindIndex]),
               isValidID(parts[kindIndex + 1]) {
                return SpotifyLink(kind: kind, id: parts[kindIndex + 1])
            }
            return nil
        }

        // URL form.
        let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let comps = URLComponents(string: normalized),
              let host = comps.host?.lowercased(),
              host == "spotify.com" || host.hasSuffix(".spotify.com") else {
            return nil
        }

        let segments = comps.path.split(separator: "/").map(String.init)
        // Find the "playlist"/"album" segment (handles /embed/playlist/ID and /intl-xx/playlist/ID).
        guard let kindIndex = segments.firstIndex(where: { $0 == "playlist" || $0 == "album" }),
              kindIndex + 1 < segments.count,
              let kind = SpotifyLink.Kind(rawValue: segments[kindIndex]),
              isValidID(segments[kindIndex + 1]) else {
            return nil
        }
        return SpotifyLink(kind: kind, id: segments[kindIndex + 1])
    }

    public static func playlistID(from raw: String) -> String? {
        guard let link = parse(raw), link.kind == .playlist else { return nil }
        return link.id
    }

    /// Spotify IDs are base-62 (`[A-Za-z0-9]`), 22 chars in practice; allow a small range for safety.
    public static func isValidID(_ s: String) -> Bool {
        (20...24).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
