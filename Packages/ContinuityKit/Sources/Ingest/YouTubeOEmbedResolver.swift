import Foundation

/// Fetches a video's real title + channel via YouTube's **oEmbed** endpoint — a stable, public,
/// documented JSON API (no key, no scraping), unlike the extraction paths used elsewhere. Used to
/// replace the "YouTube Video (abc123)" placeholder on tracks added by bare link/ID.
final class YouTubeOEmbedResolver: VideoMetadataResolving {

    private struct OEmbed: Decodable {
        let title: String
        let author_name: String?
    }

    init() {}

    func metadata(videoID: String) async throws -> VideoMetadata {
        guard var components = URLComponents(string: "https://www.youtube.com/oembed") else {
            throw IngestError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { throw IngestError.invalidURL }

        // Title backfill is best-effort, but launch/import can burst many oEmbeds — retry
        // transient failures so a blip doesn't leave the "YouTube Video (…)" placeholder stuck.
        return try await Retry.run {
            try await self.fetchMetadata(from: url)
        }
    }

    private func fetchMetadata(from url: URL) async throws -> VideoMetadata {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw IngestError.network(String(describing: error))
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 429: throw IngestError.rateLimited
            case 500..<600: throw IngestError.network("oEmbed HTTP \(http.statusCode)")
            // 401/404 usually mean private/deleted — retrying won't help.
            default: throw IngestError.resolveFailed("oEmbed HTTP \(http.statusCode)")
            }
        }

        do {
            let embed = try JSONDecoder().decode(OEmbed.self, from: data)
            return VideoMetadata(title: embed.title, author: embed.author_name)
        } catch {
            throw IngestError.decodeFailed("oEmbed: \(error)")
        }
    }
}
