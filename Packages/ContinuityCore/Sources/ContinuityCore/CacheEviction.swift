import Foundation

/// Pure LRU eviction policy for a keyed, size-budgeted cache (used by the stem cache, where one
/// key owns multiple files). Given what's on disk, a byte budget, and keys that must survive,
/// decides which keys to evict — oldest first — until the total fits.
public enum CacheEviction {

    /// One cache key's on-disk footprint.
    public struct Entry: Equatable, Sendable {
        public let key: String
        public let bytes: Int64
        /// Last time this key's content was used (max over its files).
        public let lastUsed: Date

        public init(key: String, bytes: Int64, lastUsed: Date) {
            self.key = key
            self.bytes = bytes
            self.lastUsed = lastUsed
        }
    }

    /// Keys to delete so the remaining total fits `budgetBytes`, least-recently-used first.
    /// `protected` keys are never evicted — even if the protected set alone exceeds the budget
    /// (the cache may transiently overshoot rather than break tracks the player needs next).
    public static func keysToEvict(
        entries: [Entry],
        budgetBytes: Int64,
        protected: Set<String> = []
    ) -> [String] {
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > budgetBytes else { return [] }

        var evicted: [String] = []
        for entry in entries.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            if total <= budgetBytes { break }
            guard !protected.contains(entry.key) else { continue }
            evicted.append(entry.key)
            total -= entry.bytes
        }
        return evicted
    }
}
