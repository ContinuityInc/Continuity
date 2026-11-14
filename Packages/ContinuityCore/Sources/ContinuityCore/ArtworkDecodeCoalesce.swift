import Foundation

/// Policy for sharing one ImageIO decode across consumers of the same artwork URL
/// (Now Playing hero + backdrop palette/blur). UIKit-free so Linux CI pins the rules.
public enum ArtworkDecodeCoalesce: Sendable {

    /// Single decode size that satisfies every concurrent requester for one URL —
    /// the max of their pixel budgets. Smaller consumers reuse the larger bitmap
    /// (backdrop downscales to 160 px for blur; CIAreaAverage does not need a second pass).
    public static func sharedMaxPixel(_ budgets: [Double]) -> Double {
        budgets
            .filter { $0.isFinite && $0 > 0 }
            .max() ?? 0
    }

    /// Whether a bitmap already decoded at `cachedMaxPixel` can serve a request for
    /// `requestedMaxPixel` without another ImageIO pass.
    public static func cachedSatisfiesRequest(
        cachedMaxPixel: Double,
        requestedMaxPixel: Double
    ) -> Bool {
        guard cachedMaxPixel.isFinite, requestedMaxPixel.isFinite,
              cachedMaxPixel > 0, requestedMaxPixel > 0 else { return false }
        return cachedMaxPixel >= requestedMaxPixel
    }
}

/// YouTube thumbnail quality-tier candidates for a stored artwork URL.
///
/// Tracks persist `hqdefault`; the backdrop used to climb maxres → sd → hq on its own
/// fetch path, which double-downloaded against the hero's `hqdefault` decode. Ordering
/// lives here so both the store and the backdrop share one list, pinned by tests.
public enum ArtworkThumbnailCandidates: Sendable {

    /// Sharper tiers first when `url` is a YouTube `hqdefault` thumb; otherwise just `url`.
    /// Always ends with the original so a failed upgrade still tries the stored address.
    public static func urls(for url: URL) -> [URL] {
        var candidates: [URL] = []
        let raw = url.absoluteString
        if raw.contains("/hqdefault") {
            for tier in ["/maxresdefault", "/sddefault"] {
                if let upgraded = URL(string: raw.replacingOccurrences(of: "/hqdefault", with: tier)) {
                    candidates.append(upgraded)
                }
            }
        }
        candidates.append(url)
        return candidates
    }
}
