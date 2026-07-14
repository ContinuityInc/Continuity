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
/// Long playlists are followed page-by-page via InnerTube continuation tokens (the same
/// `youtubei/v1/browse` calls the web player makes), capped at `maxTracks`. A mid-pagination
/// failure returns the pages fetched so far — partial import beats none.
final class YouTubePlaylistResolver: PlaylistResolving {

    /// Upper bound on imported tracks: bounds memory/ingest work for pathological playlists
    /// (each page is ~100 videos, so this is ~5 continuation calls at most).
    private static let maxTracks = 500

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

        // Retry the first-page fetch+parse on transient failures; a 200-with-no-videos is treated
        // as genuinely private/empty (not retried). Continuations below stay best-effort.
        let (html, contents) = try await Retry.run { () -> (String, YouTubePlaylistContents) in
            let html = try await self.fetchPlaylistHTML(url)
            let contents = YouTubePlaylist.parse(html: html)
            guard !contents.items.isEmpty else { throw IngestError.sourceUnavailable }
            return (html, contents)
        }

        var items = contents.items
        var seen = Set(items.map(\.videoID))

        // Follow continuations for playlists longer than one page. Best-effort: any failure just
        // ends pagination with what we have.
        if var token = contents.continuationToken,
           let config = YouTubePlaylist.innerTubeConfig(html: html) {
            while items.count < Self.maxTracks {
                guard let page = try? await fetchContinuation(token: token, config: config),
                      !page.items.isEmpty else { break }
                for item in page.items where !seen.contains(item.videoID) {
                    seen.insert(item.videoID)
                    items.append(item)
                }
                guard let next = page.continuationToken else { break }
                token = next
            }
        }

        return ResolvedPlaylist(
            playlistID: playlistID,
            title: contents.title,
            items: Array(items.prefix(Self.maxTracks))
        )
    }

    /// GETs the playlist page, mapping the outcome to a retryability-aware `IngestError`.
    private func fetchPlaylistHTML(_ url: URL) async throws -> String {
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
            throw IngestError.network(String(describing: error))
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 429: throw IngestError.rateLimited
            case 500..<600: throw IngestError.network("playlist page HTTP \(http.statusCode)")
            default: throw IngestError.resolveFailed("playlist page HTTP \(http.statusCode)")
            }
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw IngestError.decodeFailed("playlist page was not valid UTF-8")
        }
        return html
    }

    /// One `youtubei/v1/browse` continuation call, parsed by ContinuityCore.
    private func fetchContinuation(
        token: String,
        config: InnerTubeConfig
    ) async throws -> (items: [YouTubePlaylistItem], continuationToken: String?) {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?key=\(config.apiKey)") else {
            throw IngestError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": config.clientVersion, "hl": "en"]],
            "continuation": token,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw IngestError.resolveFailed("continuation HTTP \(http.statusCode)")
        }
        return YouTubePlaylist.parseContinuationResponse(data)
    }
}
