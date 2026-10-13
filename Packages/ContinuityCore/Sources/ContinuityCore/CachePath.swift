import Foundation

/// Defense-in-depth for on-disk cache relative paths. Writers normally emit a single basename
/// (video ID + extension, UUID artwork name), but readers must not trust SwiftData / persisted
/// strings — a corrupted `..`/`/` component would otherwise resolve outside the cache directory
/// (still sandboxed, but wrong).
public enum CachePath {
    /// Allowed audio/stem container extensions (lowercase, no dot).
    public static let allowedContainers: Set<String> = [
        "m4a", "mp4", "webm", "mp3", "wav", "caf", "aiff", "aif", "aac", "mov"
    ]

    /// True when `name` is a single path component with no traversal / separator characters.
    public static func isSafeFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        if name.contains("/") || name.contains("\\") || name.contains("\0") { return false }
        // Reject Windows-style drive prefixes and hidden traversal like "....".
        if name.contains(":") { return false }
        return true
    }

    /// Lowercased alphanumeric container, or `nil` when the value is not in the allowlist.
    public static func sanitizedContainer(_ container: String) -> String? {
        let trimmed = container.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowedContainers.contains(trimmed) else { return nil }
        return trimmed
    }

    /// Prefer a known-good container; fall back to `m4a` when the source reports nonsense.
    public static func coercedContainer(_ container: String) -> String {
        sanitizedContainer(container) ?? "m4a"
    }
}
