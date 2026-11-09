import Foundation

/// Host / size gates for audio stream downloads. Resolved googlevideo URLs are untrusted
/// input from YouTubeKit — never fetch an arbitrary HTTPS URL into the audio cache.
public enum MediaDownloadPolicy {
    /// Hard cap on a single track download (~250 MB). Hostile Content-Range totals must not
    /// fill device storage; real music streams are far smaller.
    public static let maxAudioBytes = 250 * 1024 * 1024

    /// Whether `host` is a YouTube media / thumbnail host we are willing to GET.
    public static func isAllowedStreamHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "googlevideo.com" || h.hasSuffix(".googlevideo.com") { return true }
        if h == "youtube.com" || h.hasSuffix(".youtube.com") { return true }
        if h == "youtu.be" { return true }
        if h == "ytimg.com" || h.hasSuffix(".ytimg.com") { return true }
        if h.hasSuffix(".googleusercontent.com") { return true }
        return false
    }

    /// HTTPS + allowlisted host. Rejects redirects to other schemes at the policy layer;
    /// callers should still prefer not following cross-host redirects when possible.
    public static func isAllowedStreamURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return isAllowedStreamHost(host)
    }
}
