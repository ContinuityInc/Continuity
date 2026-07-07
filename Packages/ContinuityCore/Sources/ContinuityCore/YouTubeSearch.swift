import Foundation

/// Pure extraction of the top video result from a YouTube search results page
/// (`youtube.com/results?search_query=…`). Used to re-source a Spotify track as YouTube audio.
///
/// YouTube embeds results as `ytInitialData`; the ranked list lives in an ordered array under
/// `twoColumnSearchResultsRenderer`. We read the first `videoRenderer` (or new-style
/// `lockupViewModel`) in rank order, falling back to the first one found anywhere if YouTube
/// changes the path. **No networking** — the app layer fetches the HTML; pinned by unit tests.
public enum YouTubeSearch {

    /// The video ID of the top result, or nil if none is found.
    public static func firstVideoID(html: String) -> String? {
        guard let json = YouTubePlaylist.extractBracedObject(in: html, afterMarker: "ytInitialData"),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return rankedFirstVideoID(root) ?? anyVideoID(root)
    }

    /// Walks the ordered results arrays and returns the first video's ID (rank-correct).
    private static func rankedFirstVideoID(_ root: Any) -> String? {
        guard let sections = JSONNav.array(root, [
            "contents", "twoColumnSearchResultsRenderer", "primaryContents", "sectionListRenderer", "contents",
        ]) else { return nil }

        for section in sections {
            guard let items = JSONNav.array(section, ["itemSectionRenderer", "contents"]) else { continue }
            for item in items {
                if let id = videoID(fromItem: item) { return id }
            }
        }
        return nil
    }

    /// Fallback: first video-bearing renderer found anywhere in the tree.
    private static func anyVideoID(_ root: Any) -> String? {
        var result: String?
        JSONNav.walk(root) { dict in
            guard result == nil else { return }
            if let id = videoID(fromItem: dict) { result = id }
        }
        return result
    }

    /// Extracts a valid 11-char video ID from a `videoRenderer` or (video) `lockupViewModel` item.
    private static func videoID(fromItem item: Any) -> String? {
        guard let dict = item as? [String: Any] else { return nil }
        if let renderer = dict["videoRenderer"] as? [String: Any],
           let id = renderer["videoId"] as? String,
           YouTubeURL.isValidVideoID(id) {
            return id
        }
        if let lockup = dict["lockupViewModel"] as? [String: Any] {
            if let type = lockup["contentType"] as? String, !type.contains("VIDEO") { return nil }
            if let id = lockup["contentId"] as? String, YouTubeURL.isValidVideoID(id) { return id }
        }
        return nil
    }
}
