import Foundation

/// One song read out of the user's Apple Music / iTunes library. There is **no audio here** —
/// Apple Music catalog items are DRM-protected and unusable by our engine — only the metadata we
/// need to re-source the song from YouTube (title + artist), exactly like the Spotify path.
public struct AppleMusicTrack: Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var durationSeconds: Int?

    public init(title: String, artist: String? = nil, durationSeconds: Int? = nil) {
        self.title = title
        self.artist = artist
        self.durationSeconds = durationSeconds
    }

    /// Query used to find this song on YouTube, e.g. "Blinding Lights The Weeknd".
    ///
    /// Apple Music titles carry release-edition noise ("Song (Remastered 2011)",
    /// "Song - 2009 Remaster") that YouTube titles almost never repeat, so it's stripped first —
    /// leaving it in reliably pushes the real upload out of the top search result.
    public var youtubeSearchQuery: String {
        [AppleMusicLibrary.normalizedTitle(title), artist].compactMap { $0 }.joined(separator: " ")
    }
}

/// The contents of one Apple Music library playlist: its songs (in order) and its name.
public struct AppleMusicPlaylistContents: Equatable, Sendable, Identifiable {
    /// `MPMediaPlaylist.persistentID` rendered as a string — the sync identity.
    public var persistentID: String
    public var name: String?
    public var tracks: [AppleMusicTrack]

    public var id: String { persistentID }
    public var isEmpty: Bool { tracks.isEmpty }

    public init(persistentID: String, name: String? = nil, tracks: [AppleMusicTrack]) {
        self.persistentID = persistentID
        self.name = name
        self.tracks = tracks
    }
}

/// Pure normalization of Apple Music library metadata. **No MediaPlayer, no networking** — the
/// Ingest layer reads `MPMediaItem`s and hands plain values in, so this stays Linux-testable.
public enum AppleMusicLibrary {

    /// Edition/marketing qualifiers that identify a *release variant*, not a different song.
    /// Matched case-insensitively as a substring of one parenthetical or trailing-dash segment.
    private static let editionNoise = [
        "remaster",         // "Remastered", "2009 Remaster", "Remastered Version"
        "deluxe",
        "bonus track",
        "expanded edition",
        "anniversary edition",
        "special edition",
        "explicit",
        "clean version",
        "album version",
        "single version",
        "digital remaster"
    ]

    /// Strips release-edition noise from a song title, leaving everything meaningful intact.
    ///
    /// Removes `(…)`/`[…]` groups and trailing ` - …` segments that are *only* edition
    /// qualifiers. Segments that carry real identity — `(feat. …)`, `(Live)`, `(Acoustic)`,
    /// remix credits — are kept, because YouTube uploads name them too and dropping them would
    /// match the wrong recording.
    public static func normalizedTitle(_ title: String) -> String {
        var result = removeBracketedNoise(in: title)
        result = removeTrailingDashNoise(in: result)
        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never hand back an empty query: a title that is *entirely* noise stays as it was.
        return cleaned.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    /// Whether a segment's text is purely an edition qualifier.
    private static func isEditionNoise(_ segment: String) -> Bool {
        let lowered = segment.lowercased()
        return editionNoise.contains { lowered.contains($0) }
    }

    /// Drops `(…)` and `[…]` groups whose contents are edition noise. Scans manually rather than
    /// via regex so unbalanced brackets in a messy tag degrade to "leave it alone".
    private static func removeBracketedNoise(in title: String) -> String {
        var result = ""
        var segment = ""
        var closing: Character?

        for character in title {
            if let expected = closing {
                if character == expected {
                    if !isEditionNoise(segment) {
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
        // Unbalanced opener — restore the tail verbatim rather than silently truncating.
        if let expected = closing {
            result.append(expected == ")" ? "(" : "[")
            result.append(segment)
        }
        return collapsingSpaces(result)
    }

    /// Drops trailing ` - Remastered 2011`-style segments (Apple Music's preferred form).
    /// Only the trailing segments are considered, so "Marquee Moon - Remastered" loses the
    /// qualifier while "Sgt. Pepper - Reprise" keeps its dash.
    private static func removeTrailingDashNoise(in title: String) -> String {
        var parts = title.components(separatedBy: " - ")
        while parts.count > 1, let last = parts.last, isEditionNoise(last) {
            parts.removeLast()
        }
        return parts.joined(separator: " - ")
    }

    private static func collapsingSpaces(_ value: String) -> String {
        value.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
