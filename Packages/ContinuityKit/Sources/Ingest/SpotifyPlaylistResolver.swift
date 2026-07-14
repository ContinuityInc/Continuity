import Foundation
import ContinuityCore
import os

private let spotifyLog = Logger(subsystem: "com.continuity.app", category: "spotify")

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

        // Retry the fetch+parse on transient failures (network blips, 429, 5xx) — those shouldn't
        // read to the user as "playlist unavailable". A 200-with-no-tracks is NOT retried: it means
        // the playlist really is private/empty.
        do {
            return try await Retry.run {
                let html = try await self.fetchEmbedHTML(url)
                let contents = SpotifyPlaylist.parse(html: html)
                guard !contents.tracks.isEmpty else {
                    spotifyLog.error("reached \(link.id, privacy: .public) but parsed 0 tracks (private/empty or shape change)")
                    throw IngestError.sourceUnavailable
                }
                return ResolvedSpotifyPlaylist(link: link, name: contents.name, tracks: contents.tracks)
            }
        } catch {
            spotifyLog.error("resolve \(link.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// GETs the embed page, mapping the outcome to a retryability-aware `IngestError`.
    private func fetchEmbedHTML(_ url: URL) async throws -> String {
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
            throw IngestError.network(String(describing: error))   // connectivity/timeout → retryable
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 429: throw IngestError.rateLimited
            case 500..<600: throw IngestError.network("Spotify embed HTTP \(http.statusCode)")
            default: throw IngestError.resolveFailed("Spotify embed HTTP \(http.statusCode)")
            }
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw IngestError.decodeFailed("Spotify embed page was not valid UTF-8")
        }
        return html
    }
}
