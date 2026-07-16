import XCTest
@testable import ContinuityCore

final class FlowOrderingTests: XCTestCase {

    // Stable ids so failures print something readable.
    private func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    private func item(_ n: Int, bpm: Double?, key: String?) -> FlowItem {
        FlowItem(id: id(n), bpm: bpm, camelotCode: key)
    }

    func testEmptyInput() {
        XCTAssertEqual(FlowOrdering.order([], startingAt: nil), [])
        XCTAssertEqual(FlowOrdering.order([], startingAt: UUID()), [])
    }

    func testSingleItem() {
        let items = [item(1, bpm: 120, key: "8B")]
        XCTAssertEqual(FlowOrdering.order(items, startingAt: nil), [id(1)])
        XCTAssertEqual(FlowOrdering.order(items, startingAt: id(1)), [id(1)])
    }

    func testEveryIDAppearsExactlyOnce() {
        let items = [
            item(1, bpm: 120, key: "8B"),
            item(2, bpm: nil, key: nil),
            item(3, bpm: 150, key: "3A"),
            item(4, bpm: nil, key: "11B"),
            item(5, bpm: 90, key: nil),
        ]
        let ordered = FlowOrdering.order(items, startingAt: id(3))
        XCTAssertEqual(ordered.count, items.count)
        XCTAssertEqual(Set(ordered), Set(items.map(\.id)))
    }

    func testStartIDIsHonored() {
        let items = [
            item(1, bpm: 120, key: "8B"),
            item(2, bpm: 122, key: "8A"),
            item(3, bpm: 125, key: "9A"),
        ]
        XCTAssertEqual(FlowOrdering.order(items, startingAt: id(3)).first, id(3))
    }

    func testUnknownStartIDFallsBackToFirstAnalyzedItem() {
        let items = [
            item(1, bpm: nil, key: nil),
            item(2, bpm: 120, key: "8B"),
            item(3, bpm: 122, key: "8A"),
        ]
        // Unanalyzed item 1 can't lead; the first analyzed item does.
        XCTAssertEqual(FlowOrdering.order(items, startingAt: UUID()).first, id(2))
        XCTAssertEqual(FlowOrdering.order(items, startingAt: nil).first, id(2))
    }

    func testCompatibleChainBeatsWheelJump() {
        // 8B/120 → 8A/122 → 9A/125 is the obvious harmonic path; 3A/121 is a far
        // wheel jump despite the closer tempo, so it must land last.
        let items = [
            item(1, bpm: 120, key: "8B"),
            item(2, bpm: 121, key: "3A"),
            item(3, bpm: 125, key: "9A"),
            item(4, bpm: 122, key: "8A"),
        ]
        XCTAssertEqual(FlowOrdering.order(items, startingAt: id(1)),
                       [id(1), id(4), id(3), id(2)])
    }

    func testDoubleTimePairingIsCompatible() {
        // 170 vs 85 is half-time equivalent: same key, zero effective tempo cost,
        // so it must beat the same-key track that is genuinely 10% off.
        let items = [
            item(1, bpm: 170, key: "8A"),
            item(2, bpm: 154, key: "8A"),
            item(3, bpm: 85, key: "8A"),
        ]
        XCTAssertEqual(FlowOrdering.order(items, startingAt: id(1)),
                       [id(1), id(3), id(2)])
    }

    func testUnanalyzedItemsSinkToEndInInputOrder() {
        let items = [
            item(1, bpm: nil, key: nil),
            item(2, bpm: 120, key: "8B"),
            item(3, bpm: nil, key: nil),
            item(4, bpm: 122, key: "8A"),
            item(5, bpm: nil, key: nil),
        ]
        let ordered = FlowOrdering.order(items, startingAt: nil)
        XCTAssertEqual(ordered, [id(2), id(4), id(1), id(3), id(5)])
    }

    func testMalformedKeyCountsAsUnknown() {
        // "13Q" doesn't parse; with no bpm either, the item is unanalyzed and sinks.
        let items = [
            item(1, bpm: nil, key: "13Q"),
            item(2, bpm: 120, key: "8B"),
        ]
        XCTAssertEqual(FlowOrdering.order(items, startingAt: nil), [id(2), id(1)])
    }

    func testPartiallyAnalyzedItemsStayInGreedyPass() {
        // bpm-only and key-only items still carry signal, so they are ordered
        // greedily rather than sunk.
        let items = [
            item(1, bpm: 120, key: "8B"),
            item(2, bpm: nil, key: nil),
            item(3, bpm: 121, key: nil),
            item(4, bpm: nil, key: "8A"),
        ]
        let ordered = FlowOrdering.order(items, startingAt: id(1))
        XCTAssertEqual(ordered.last, id(2))
        XCTAssertEqual(ordered.first, id(1))
    }

    func testDeterministicTieBreakByInputOrder() {
        // Items 2 and 3 are identical transitions from 1; input order decides.
        let items = [
            item(1, bpm: 120, key: "8B"),
            item(2, bpm: 120, key: "8B"),
            item(3, bpm: 120, key: "8B"),
        ]
        XCTAssertEqual(FlowOrdering.order(items, startingAt: id(1)),
                       [id(1), id(2), id(3)])
    }

    func testStartIDOnUnanalyzedItemStillLeads() {
        // The user explicitly chose it, so it leads even without analysis.
        let items = [
            item(1, bpm: 120, key: "8B"),
            item(2, bpm: nil, key: nil),
        ]
        XCTAssertEqual(FlowOrdering.order(items, startingAt: id(2)), [id(2), id(1)])
    }

    func testWheelWrapDistanceIsUsed() {
        // 12A → 1A wraps to one hop, so it beats 12A → 9A (three hops) even though
        // 9 looks numerically closer to 12 than... it isn't; the wheel wraps.
        let items = [
            item(1, bpm: 120, key: "12A"),
            item(2, bpm: 120, key: "9A"),
            item(3, bpm: 120, key: "1A"),
        ]
        XCTAssertEqual(FlowOrdering.order(items, startingAt: id(1)),
                       [id(1), id(3), id(2)])
    }
}
