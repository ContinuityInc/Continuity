import Foundation

/// A SoundCloud link we can act on. SoundCloud addresses things by **permalink path**
/// (`user/sets/playlist-slug`, `user/track-slug`) rather than by an opaque ID, so the path is the
/// identity we keep; `permalinkURL` rebuilds the canonical page URL from it.
public struct SoundCloudLink: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// `soundcloud.com/{user}/{slug}` — one upload.
        case track
        /// `soundcloud.com/{user}/sets/{slug}` — a playlist or album (both are "sets").
        case playlist
        /// `on.soundcloud.com/{code}` — a share short-link that only an HTTP redirect can
        /// classify. The resolver follows it and re-parses the destination.
        case shortLink
    }

    public var kind: Kind
    /// Canonical permalink path without leading slash — `user/sets/slug` or `user/slug`, keeping
    /// a private-share `s-XXXX` secret-token segment when present. For `.shortLink` this is the
    /// full short URL.
    public var path: String

    public init(kind: Kind, path: String) {
        self.kind = kind
        self.path = path
    }

    /// The canonical `https://soundcloud.com/…` page URL (or the short URL itself).
    public var permalinkURL: URL? {
        switch kind {
        case .shortLink: return URL(string: path)
        case .track, .playlist: return URL(string: "https://soundcloud.com/" + path)
        }
    }

    /// Stable identity for sync: the permalink path (secret token included, since a private set
    /// is only reachable with it).
    public var sourceID: String { path }
}

/// Pure parsing of SoundCloud links into a `(kind, permalink path)` pair. No networking.
///
/// Accepts `soundcloud.com`, `www.`/`m.` subdomains and the `on.soundcloud.com` short host,
/// with or without a scheme, ignoring tracking query items (`?si=…`, `utm_*`). Non-content
/// pages (`/discover`, `/you/likes`, a user's `/tracks` tab …) are rejected so a pasted profile
/// link doesn't masquerade as a track. Locked down by unit tests.
public enum SoundCloudURL {

    /// Top-level paths that are app sections, not user profiles.
    private static let reservedRoots: Set<String> = [
        "discover", "search", "you", "stream", "upload", "settings", "pages", "charts", "mobile",
        "tags", "people", "terms-of-use", "jobs", "imprint", "popular", "logout", "login", "signin",
        "messages", "notifications", "feed", "dashboard", "premium", "pro", "go", "help", "legal",
        "oembed", "apps", "groups", "explore", "resolve", "stations", "tracks", "playlists",
        "creators", "artists", "for-artists", "download", "mobile-apps", "about", "blog",
    ]

    /// Second segments under a profile that are profile tabs, not uploads.
    private static let profileTabs: Set<String> = [
        "tracks", "albums", "sets", "reposts", "likes", "followers", "following", "comments",
        "popular-tracks", "toptracks", "spotlight", "stats", "playlists", "all",
    ]

    /// Parses a raw string. Returns nil if it isn't a recognisable SoundCloud track/set link.
    public static func parse(_ raw: String) -> SoundCloudLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let comps = URLComponents(string: normalized),
              let host = comps.host?.lowercased() else { return nil }

        let rawSegments = comps.path.split(separator: "/").map(String.init)
        let segments = rawSegments.map { $0.lowercased() }

        if host == "on.soundcloud.com" {
            // Share short-links: one opaque, case-sensitive code. Only the redirect knows what
            // it points at.
            guard let code = rawSegments.first, rawSegments.count == 1, isValidSlug(code) else { return nil }
            return SoundCloudLink(kind: .shortLink, path: "https://on.soundcloud.com/\(code)")
        }

        guard host == "soundcloud.com" || host.hasSuffix(".soundcloud.com") else { return nil }
        // `api.soundcloud.com/...` are API resources (numeric IDs), not pages we can scrape.
        if host.hasPrefix("api") { return nil }

        guard let user = segments.first, segments.count >= 2, isValidSlug(user),
              !reservedRoots.contains(user) else { return nil }

        if segments[1] == "sets" {
            guard segments.count >= 3, isValidSlug(segments[2]) else { return nil }
            var path = "\(user)/sets/\(segments[2])"
            if let secret = secretToken(rawSegments.dropFirst(3).first) { path += "/\(secret)" }
            return SoundCloudLink(kind: .playlist, path: path)
        }

        let slug = segments[1]
        guard isValidSlug(slug), !profileTabs.contains(slug) else { return nil }
        var path = "\(user)/\(slug)"
        if let secret = secretToken(rawSegments.dropFirst(2).first) { path += "/\(secret)" }
        return SoundCloudLink(kind: .track, path: path)
    }

    /// Private-share tokens look like `s-AbC12` and are case-sensitive; anything else after a
    /// slug (`/comments`, `/recommended`) is a sub-tab of the same page and is dropped.
    private static func secretToken(_ segment: String?) -> String? {
        guard let segment, segment.lowercased().hasPrefix("s-"), segment.count > 2, isValidSlug(segment) else { return nil }
        return segment
    }

    /// SoundCloud permalinks are lowercase `[a-z0-9_-]`; we compare case-insensitively so a
    /// capitalised paste still matches.
    public static func isValidSlug(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 255 && s.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
        }
    }
}
