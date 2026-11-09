import Foundation

/// The IDs we can pull out of a user-supplied YouTube link.
public struct YouTubeLink: Equatable, Sendable {
    public var videoID: String?
    public var playlistID: String?

    public init(videoID: String? = nil, playlistID: String? = nil) {
        self.videoID = videoID
        self.playlistID = playlistID
    }

    public var isEmpty: Bool { videoID == nil && playlistID == nil }
}

/// Pure parsing of YouTube URLs into video / playlist IDs. No networking — this just lets the
/// app turn whatever a user pastes ("Add from YouTube") into IDs the resolver can act on.
/// Kept in ContinuityCore so every accepted/rejected URL shape is locked down by unit tests.
public enum YouTubeURL {
    private static let videoIDLength = 11

    /// Parses a raw string (full URL, short URL, or a bare 11-char video ID).
    /// Returns `nil` if nothing recognisable is found.
    public static func parse(_ raw: String) -> YouTubeLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A bare video ID pasted on its own.
        if isValidVideoID(trimmed) {
            return YouTubeLink(videoID: trimmed)
        }

        // URLComponents needs a scheme to populate host/path.
        let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let comps = URLComponents(string: normalized),
              let host = comps.host?.lowercased() else {
            return nil
        }

        let queryItems = comps.queryItems ?? []
        func queryValue(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value
        }

        var videoID: String?
        var playlistID: String?

        if let list = queryValue("list"), isValidPlaylistID(list) {
            playlistID = list
        }

        let segments = comps.path.split(separator: "/").map(String.init)

        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            if let first = segments.first, isValidVideoID(first) { videoID = first }
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com")
                    || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com") {
            if let v = queryValue("v"), isValidVideoID(v) {
                videoID = v
            } else if let idx = segments.firstIndex(where: { $0 == "shorts" || $0 == "embed" || $0 == "v" || $0 == "live" }),
                      idx + 1 < segments.count,
                      isValidVideoID(segments[idx + 1]) {
                videoID = segments[idx + 1]
            }
        } else {
            return nil
        }

        let link = YouTubeLink(videoID: videoID, playlistID: playlistID)
        return link.isEmpty ? nil : link
    }

    public static func videoID(from raw: String) -> String? { parse(raw)?.videoID }
    public static func playlistID(from raw: String) -> String? { parse(raw)?.playlistID }

    /// YouTube video IDs are exactly 11 chars of `[A-Za-z0-9_-]`.
    public static func isValidVideoID(_ s: String) -> Bool {
        s.count == videoIDLength && s.allSatisfy(isIDChar)
    }

    /// Playlist IDs vary in length (roughly 13–42) over the same alphabet.
    public static func isValidPlaylistID(_ s: String) -> Bool {
        (10...50).contains(s.count) && s.allSatisfy(isIDChar)
    }

    private static func isIDChar(_ c: Character) -> Bool {
        guard c.isASCII else { return false }
        return c.isLetter || c.isNumber || c == "-" || c == "_"
    }
}
