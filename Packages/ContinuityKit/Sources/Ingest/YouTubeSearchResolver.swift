import Foundation
import ContinuityCore

/// Finds the best-matching YouTube video ID for a text query (e.g. "Blinding Lights The Weeknd")
/// by fetching `youtube.com/results?search_query=…` and handing the HTML to
/// `ContinuityCore.YouTubeSearch`.
///
/// Used to re-source Spotify tracks as YouTube audio. YouTubeKit has no search API, so we scrape
/// the results page — **fragile** like the other scrapers, so parsing lives in unit-tested
/// ContinuityCore and this type only does networking + error mapping.
final class YouTubeSearchResolver: YouTubeSearching {

    init() {}

    func firstVideoID(query: String) async throws -> String? {
        guard var components = URLComponents(string: "https://www.youtube.com/results") else {
            throw IngestError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "search_query", value: query),
            URLQueryItem(name: "hl", value: "en"),
        ]
        guard let url = components.url else { throw IngestError.invalidURL }

        // Spotify playlist imports fire many searches; a single 429/5xx/blip shouldn't fail a track.
        return try await Retry.run {
            let html = try await self.fetchSearchHTML(url)
            return YouTubeSearch.firstVideoID(html: html)
        }
    }

    /// GETs the results page, mapping the outcome to a retryability-aware `IngestError`.
    private func fetchSearchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
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
            case 500..<600: throw IngestError.network("YouTube search HTTP \(http.statusCode)")
            default: throw IngestError.resolveFailed("YouTube search HTTP \(http.statusCode)")
            }
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw IngestError.decodeFailed("YouTube search page was not valid UTF-8")
        }
        return html
    }
}
