import Foundation
import ContinuityCore
import os

private let soundcloudLog = Logger(subsystem: "com.continuity.app", category: "soundcloud")

/// Resolves a SoundCloud set/track link **without an account** by fetching the public page and
/// handing its `__sc_hydration` blob to `ContinuityCore.SoundCloudPlaylist`.
///
/// **Metadata only** — like the Spotify embed path, the caller re-sources each song's audio from
/// YouTube. The page hydrates only the first ~5 tracks of a set; the remaining ids are fetched from
/// `api-v2.soundcloud.com/tracks`, which needs the site's `client_id`. That key lives inside the
/// web app's JavaScript bundles, so it is discovered by scanning them (newest chunk first) and
/// cached for the process. All of this is **fragile** by nature; the parsing is unit-tested in
/// ContinuityCore and this type only does networking + error mapping.
final class SoundCloudPlaylistResolver: SoundCloudResolving {

    /// Upper bound on imported tracks, matching the YouTube resolver.
    private static let maxTracks = 500

    /// Discovered `client_id`, shared across resolves. Actor-isolated so concurrent imports
    /// don't each scan the bundles.
    private actor ClientIDCache {
        private var value: String?
        func get() -> String? { value }
        func set(_ id: String?) { value = id }
    }
    private let clientIDCache = ClientIDCache()

    init() {}

    func resolve(_ link: SoundCloudLink) async throws -> ResolvedServiceLink {
        guard var pageURL = link.permalinkURL else { throw IngestError.invalidURL }

        var kind = link.kind
        if kind == .shortLink {
            // One redirect hop tells us what the share link points at.
            let destination = try await Retry.run { try await self.followRedirect(pageURL) }
            guard let resolved = SoundCloudURL.parse(destination.absoluteString), resolved.kind != .shortLink,
                  let url = resolved.permalinkURL else {
                throw IngestError.sourceUnavailable
            }
            pageURL = url
            kind = resolved.kind
        }
        // Sync identity: the canonical permalink path (post-redirect for short links).
        let sourcePath = SoundCloudURL.parse(pageURL.absoluteString)?.path ?? link.path

        do {
            return try await Retry.run {
                let html = try await self.fetchHTML(pageURL)
                switch kind {
                case .track:
                    guard let track = SoundCloudPlaylist.parseTrack(html: html) else {
                        soundcloudLog.error("reached \(link.path, privacy: .public) but found no track hydration")
                        throw IngestError.sourceUnavailable
                    }
                    return .track(ServiceTrack(track))
                case .playlist, .shortLink:
                    guard let contents = SoundCloudPlaylist.parsePlaylist(html: html), !contents.isEmpty else {
                        soundcloudLog.error("reached \(link.path, privacy: .public) but parsed 0 tracks (private/empty or shape change)")
                        throw IngestError.sourceUnavailable
                    }
                    let tracks = await self.hydrateStubs(contents, pageHTML: html)
                    let summary = ServicePlaylistSummary(
                        service: .soundcloud,
                        sourceID: sourcePath,
                        kind: contents.isAlbum ? .album : .playlist,
                        name: contents.title ?? "SoundCloud Set",
                        trackCount: tracks.count
                    )
                    return .playlist(ServicePlaylistContents(summary: summary, tracks: tracks.map(ServiceTrack.init)))
                }
            }
        } catch {
            soundcloudLog.error("resolve \(link.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - Stub hydration

    /// Fetches the tracks the page only stubbed. Best-effort: if the `client_id` can't be found
    /// or a batch fails, the hydrated prefix is still returned — a partial set beats none.
    private func hydrateStubs(_ contents: SoundCloudPlaylistContents, pageHTML: String) async -> [SoundCloudTrack] {
        let pending = Array(contents.pendingTrackIDs.prefix(Self.maxTracks))
        guard !pending.isEmpty, let clientID = await discoverClientID(pageHTML: pageHTML) else {
            return Array(contents.assembled(with: []).prefix(Self.maxTracks))
        }

        var fetched: [SoundCloudTrack] = []
        var start = 0
        while start < pending.count {
            let batch = Array(pending[start..<min(start + SoundCloudPlaylist.tracksBatchSize, pending.count)])
            start += batch.count
            guard let url = SoundCloudPlaylist.tracksRequestURL(ids: batch, clientID: clientID) else { break }
            do {
                let data = try await fetchData(url, accept: "application/json")
                fetched += SoundCloudPlaylist.parseTracksResponse(data)
            } catch let error as IngestError where error.isUnauthorizedScrape {
                // The key rotated under us — forget it so the next resolve rediscovers.
                await clientIDCache.set(nil)
                break
            } catch {
                break
            }
        }
        return Array(contents.assembled(with: fetched).prefix(Self.maxTracks))
    }

    /// The web app's `client_id`, from cache or by scanning the page's JS bundles (last first —
    /// the key sits in one of the later chunks).
    private func discoverClientID(pageHTML: String) async -> String? {
        if let cached = await clientIDCache.get() { return cached }
        for url in SoundCloudPlaylist.scriptURLs(html: pageHTML).reversed() {
            guard let data = try? await fetchData(url, accept: "*/*"),
                  let script = String(data: data, encoding: .utf8),
                  let id = SoundCloudPlaylist.clientID(inScript: script) else { continue }
            await clientIDCache.set(id)
            return id
        }
        soundcloudLog.error("no client_id found in \(SoundCloudPlaylist.scriptURLs(html: pageHTML).count) bundles")
        return nil
    }

    // MARK: - Networking

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private func fetchHTML(_ url: URL) async throws -> String {
        let data = try await fetchData(url, accept: "text/html")
        guard let html = String(data: data, encoding: .utf8) else {
            throw IngestError.decodeFailed("SoundCloud page was not valid UTF-8")
        }
        return html
    }

    /// GETs a URL, mapping the outcome to a retryability-aware `IngestError`.
    private func fetchData(_ url: URL, accept: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(accept, forHTTPHeaderField: "Accept")

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
            case 401, 403: throw IngestError.resolveFailed("SoundCloud HTTP \(http.statusCode)")
            case 404: throw IngestError.sourceUnavailable
            case 429: throw IngestError.rateLimited
            case 500..<600: throw IngestError.network("SoundCloud HTTP \(http.statusCode)")
            default: throw IngestError.resolveFailed("SoundCloud HTTP \(http.statusCode)")
            }
        }
        return data
    }

    /// Resolves an `on.soundcloud.com` short link by taking the redirect target without
    /// following it (a plain GET would land on the page and lose the canonical URL).
    private func followRedirect(_ url: URL) async throws -> URL {
        final class NoRedirect: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
                completionHandler(nil)
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request, delegate: NoRedirect())
        } catch {
            throw IngestError.network(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else { throw IngestError.resolveFailed("short link: no HTTP response") }
        if let location = http.value(forHTTPHeaderField: "Location"), let target = URL(string: location, relativeTo: url) {
            return target.absoluteURL
        }
        // Some hosts answer 200 with the destination already applied.
        if (200..<300).contains(http.statusCode), let final = http.url, final != url { return final }
        throw IngestError.sourceUnavailable
    }
}

private extension IngestError {
    /// A 401/403 from api-v2 means the scraped `client_id` is stale, not that the set is gone.
    var isUnauthorizedScrape: Bool {
        if case .resolveFailed(let reason) = self { return reason.contains("401") || reason.contains("403") }
        return false
    }
}
