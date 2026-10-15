import Foundation

/// Normalizes a user-entered title/artist edit before it lands on a `Track`.
///
/// Rows, the lock screen and search all render these strings verbatim, so stray whitespace or
/// a blank title would otherwise persist forever. Pure Foundation so the rules are pinned by
/// Linux tests rather than rediscovered on device.
public enum TrackRename {
    /// Artist shown when the user clears the field — matches what imports use for an unknown one.
    public static let unknownArtist = "Unknown Artist"

    public struct Edit: Equatable, Sendable {
        public var title: String
        public var artist: String

        public init(title: String, artist: String) {
            self.title = title
            self.artist = artist
        }
    }

    /// Trims both fields and collapses internal whitespace runs. Returns `nil` when the title
    /// is blank — a track must keep a visible name; a blank artist falls back to `unknownArtist`.
    public static func normalized(title: String, artist: String) -> Edit? {
        let cleanTitle = collapsedWhitespace(title)
        guard !cleanTitle.isEmpty else { return nil }
        let cleanArtist = collapsedWhitespace(artist)
        return Edit(title: cleanTitle, artist: cleanArtist.isEmpty ? unknownArtist : cleanArtist)
    }

    /// Whether applying `edit` to a track currently showing `title`/`artist` changes anything.
    public static func isChange(_ edit: Edit, fromTitle title: String, artist: String) -> Bool {
        edit.title != title || edit.artist != artist
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }
}
