import XCTest
@testable import ContinuityCore

final class CacheEvictionTests: XCTestCase {

    private func entry(_ key: String, mb: Int64, age: TimeInterval) -> CacheEviction.Entry {
        CacheEviction.Entry(key: key, bytes: mb * 1_000_000,
                            lastUsed: Date(timeIntervalSince1970: 1_000_000 - age))
    }

    func testNoEvictionUnderBudget() {
        let entries = [entry("a", mb: 10, age: 100), entry("b", mb: 20, age: 0)]
        XCTAssertEqual(CacheEviction.keysToEvict(entries: entries, budgetBytes: 50_000_000), [])
    }

    func testEvictsOldestFirstUntilUnderBudget() {
        let entries = [
            entry("newest", mb: 40, age: 0),
            entry("oldest", mb: 40, age: 300),
            entry("middle", mb: 40, age: 100),
        ]
        // Total 120 MB, budget 80 MB → evict just the oldest.
        XCTAssertEqual(CacheEviction.keysToEvict(entries: entries, budgetBytes: 80_000_000), ["oldest"])
        // Budget 50 MB → evict oldest then middle.
        XCTAssertEqual(CacheEviction.keysToEvict(entries: entries, budgetBytes: 50_000_000),
                       ["oldest", "middle"])
    }

    func testProtectedKeysSurviveEvenWhenOldest() {
        let entries = [
            entry("playing", mb: 60, age: 500),   // oldest but protected
            entry("idle", mb: 60, age: 10),
        ]
        let evicted = CacheEviction.keysToEvict(entries: entries, budgetBytes: 70_000_000,
                                                protected: ["playing"])
        XCTAssertEqual(evicted, ["idle"])
    }

    func testProtectedSetMayOvershootBudget() {
        // Everything protected and over budget → evict nothing (never break the play queue).
        let entries = [entry("a", mb: 100, age: 50), entry("b", mb: 100, age: 10)]
        let evicted = CacheEviction.keysToEvict(entries: entries, budgetBytes: 50_000_000,
                                                protected: ["a", "b"])
        XCTAssertEqual(evicted, [])
    }

    func testEmptyEntries() {
        XCTAssertEqual(CacheEviction.keysToEvict(entries: [], budgetBytes: 1), [])
    }
}
