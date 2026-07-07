import Foundation
import ContinuityCore

/// Resolves a Spotify playlist/album ID to its tracklist by fetching Spotify's **embed** page
/// (`open.spotify.com/embed/{kind}/{id}`) and handing the HTML to `ContinuityCore.SpotifyPlaylist`.
///
/// Spotify audio is DRM-protected and unusable by our engine, so this pulls **metadata only**
/// (title + artist per track); the caller re-sources each song's audio from YouTube. The embed
/// page needs no credentials but is **fragile** (Spotify can change the `__NEXT_DATA__` shape) —
/// parsing lives in unit-tested ContinuityCore; this type only does networking + error mapping.
///
/// **Coverage note:** the embed page lists ~50 tracks; longer playlists would need pagination.
final class SpotifyPlaylistResolver: SpotifyPlaylistResolving {

    init() {}

    func resolvePlaylist(_ link: SpotifyLink) async throws -> ResolvedSpotifyPlaylist {
        guard let url = URL(string: "https://open.spotify.com/embed/\(link.kind.rawValue)/\(link.id)") else {
            throw IngestError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw IngestError.resolveFailed(String(describing: error))
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw IngestError.resolveFailed("Spotify embed HTTP \(http.statusCode)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw IngestError.decodeFailed("Spotify embed page was not valid UTF-8")
        }

        let contents = SpotifyPlaylist.parse(html: html)
        guard !contents.tracks.isEmpty else {
            throw IngestError.resolveFailed("no tracks found (private, empty, or unavailable)")
        }

        return ResolvedSpotifyPlaylist(link: link, name: contents.name, tracks: contents.tracks)
    }
}
