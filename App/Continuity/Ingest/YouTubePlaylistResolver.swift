import Foundation
import ContinuityCore

/// Resolves a YouTube playlist ID to its list of videos by fetching the public
/// `youtube.com/playlist?list=…` page and handing the HTML to `ContinuityCore.YouTubePlaylist`
/// for parsing.
///
/// YouTubeKit only resolves single videos (no playlist support), so we scrape the playlist
/// page directly. As with the stream resolver, this is **fragile** — YouTube can change the
/// embedded `ytInitialData` shape at any time — so resolve failures are expected, recoverable
/// runtime errors. All parsing lives in (unit-tested) ContinuityCore; this type only does the
/// networking and translates errors into `IngestError`.
///
/// **Coverage note:** the first page load lists up to ~100 videos. Longer playlists paginate
/// via continuation tokens, which we don't yet follow — sufficient for albums/typical playlists,
/// a later refinement for very long ones.
final class YouTubePlaylistResolver: PlaylistResolving {

    init() {}

    func resolvePlaylist(playlistID: String) async throws -> ResolvedPlaylist {
        guard var components = URLComponents(string: "https://www.youtube.com/playlist") else {
            throw IngestError.invalidURL
        }
        // `hl=en` keeps labels/parsing predictable regardless of the device locale.
        components.queryItems = [
            URLQueryItem(name: "list", value: playlistID),
            URLQueryItem(name: "hl", value: "en"),
        ]
        guard let url = components.url else { throw IngestError.invalidURL }

        var request = URLRequest(url: url)
        // A desktop UA returns the full `ytInitialData` blob we parse; the consent cookie skips
        // the EU interstitial that would otherwise replace the page with a consent form.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("CONSENT=YES+1", forHTTPHeaderField: "Cookie")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw IngestError.resolveFailed(String(describing: error))
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw IngestError.resolveFailed("playlist page HTTP \(http.statusCode)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw IngestError.decodeFailed("playlist page was not valid UTF-8")
        }

        let contents = YouTubePlaylist.parse(html: html)
        guard !contents.items.isEmpty else {
            throw IngestError.resolveFailed("no videos found in playlist (private, empty, or unavailable)")
        }

        return ResolvedPlaylist(playlistID: playlistID, title: contents.title, items: contents.items)
    }
}
