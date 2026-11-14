import XCTest
@testable import ContinuityCore

final class StemSeparationPolicyTests: XCTestCase {

    func testAbsoluteMaxMatchesHistoricalSeparatorCap() {
        // OnnxStemSeparator's private maxSeparationSeconds was 1_800 — keep the Core knob in lockstep.
        XCTAssertEqual(StemSeparationPolicy.absoluteMaxSeconds, 1_800)
    }

    func testDefaultEdgeCoversSmoothPresetPlusMargin() {
        XCTAssertEqual(StemSeparationPolicy.designMaxBlendSeconds, 12)
        XCTAssertEqual(StemSeparationPolicy.edgeMarginSeconds, 18)
        XCTAssertEqual(StemSeparationPolicy.defaultEdgeSeconds, 30)
        XCTAssertEqual(
            StemSeparationPolicy.edgeSeconds(blendDuration: 12),
            StemSeparationPolicy.defaultEdgeSeconds
        )
    }

    func testEdgeSecondsSanitizesNonFiniteBlendAndMargin() {
        XCTAssertEqual(
            StemSeparationPolicy.edgeSeconds(blendDuration: .nan),
            StemSeparationPolicy.defaultEdgeSeconds
        )
        XCTAssertEqual(
            StemSeparationPolicy.edgeSeconds(blendDuration: -4, margin: 10),
            StemSeparationPolicy.designMaxBlendSeconds + 10
        )
        XCTAssertEqual(
            StemSeparationPolicy.edgeSeconds(blendDuration: 8, margin: .infinity),
            8 + StemSeparationPolicy.edgeMarginSeconds
        )
    }

    func testFullPrefixCapsLongTracks() {
        let ranges = StemSeparationPolicy.separationRanges(
            trackDuration: 3_600,
            mode: .fullPrefix,
            maxSeconds: 1_800
        )
        XCTAssertEqual(ranges, [0..<1_800])
    }

    func testFullPrefixLeavesShortTracksUntouched() {
        let ranges = StemSeparationPolicy.separationRanges(
            trackDuration: 240,
            mode: .fullPrefix
        )
        XCTAssertEqual(ranges, [0..<240])
    }

    func testEdgesOnlySplitsLongTrack() {
        let ranges = StemSeparationPolicy.separationRanges(
            trackDuration: 600,
            mode: .edgesOnly,
            edgeSeconds: 30
        )
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0], 0..<30)
        XCTAssertEqual(ranges[1], 570..<600)
        let total = ranges.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        XCTAssertEqual(total, 60, accuracy: 1e-9)
    }

    func testEdgesOnlyMergesWhenTrackFitsInsideBothEdges() {
        // 50 s track with 30 s edges → head+tail overlap → single full range.
        let ranges = StemSeparationPolicy.separationRanges(
            trackDuration: 50,
            mode: .edgesOnly,
            edgeSeconds: 30
        )
        XCTAssertEqual(ranges, [0..<50])
    }

    func testEdgesOnlyMergesWhenEdgesExactlyMeet() {
        let ranges = StemSeparationPolicy.separationRanges(
            trackDuration: 60,
            mode: .edgesOnly,
            edgeSeconds: 30
        )
        XCTAssertEqual(ranges, [0..<60])
    }

    /// When edges would cover the whole track but the track exceeds `maxSeconds`, a merged
    /// prefix would drop the outro — the opposite of edgesOnly. Keep head+tail within budget.
    func testEdgesOnlyKeepsOutroWhenMergeWouldExceedBudget() {
        let ranges = StemSeparationPolicy.separationRanges(
            trackDuration: 700,
            mode: .edgesOnly,
            edgeSeconds: 400,
            maxSeconds: 600
        )
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0], 0..<300)           // cap/2
        XCTAssertEqual(ranges[1], 400..<700)         // outro edge preserved
        let total = ranges.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        XCTAssertEqual(total, 600, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(total, 600)
    }

    func testUnusableDurationYieldsEmptyRanges() {
        XCTAssertEqual(
            StemSeparationPolicy.separationRanges(trackDuration: 0, mode: .fullPrefix),
            []
        )
        XCTAssertEqual(
            StemSeparationPolicy.separationRanges(trackDuration: -1, mode: .edgesOnly),
            []
        )
        XCTAssertEqual(
            StemSeparationPolicy.separationRanges(trackDuration: .nan, mode: .fullPrefix),
            []
        )
        XCTAssertEqual(
            StemSeparationPolicy.separationRanges(trackDuration: .infinity, mode: .edgesOnly),
            []
        )
    }

    func testMaxSecondsNeverExceedsAbsoluteCap() {
        let ranges = StemSeparationPolicy.separationRanges(
            trackDuration: 10_000,
            mode: .fullPrefix,
            maxSeconds: 9_999
        )
        XCTAssertEqual(ranges, [0..<StemSeparationPolicy.absoluteMaxSeconds])
    }

    func testTierModePrefersEdgesWhenConstrained() {
        XCTAssertEqual(StemSeparationPolicy.mode(for: .full), .fullPrefix)
        XCTAssertEqual(StemSeparationPolicy.mode(for: .balanced), .fullPrefix)
        XCTAssertEqual(StemSeparationPolicy.mode(for: .constrained), .edgesOnly)
    }

    func testTierMaxSeparationTightensUnderPressure() {
        XCTAssertEqual(StemSeparationPolicy.maxSeparationSeconds(for: .full), 1_800)
        XCTAssertEqual(StemSeparationPolicy.maxSeparationSeconds(for: .balanced), 900)
        XCTAssertEqual(StemSeparationPolicy.maxSeparationSeconds(for: .constrained), 600)
        XCTAssertLessThan(
            StemSeparationPolicy.maxSeparationSeconds(for: .constrained),
            StemSeparationPolicy.maxSeparationSeconds(for: .balanced)
        )
        XCTAssertLessThanOrEqual(
            StemSeparationPolicy.maxSeparationSeconds(for: .full),
            StemSeparationPolicy.absoluteMaxSeconds
        )
    }

    func testPlanOnConstrainedLongTrackIsEdgeOnly() {
        let plan = StemSeparationPolicy.plan(
            trackDuration: 1_200,
            tier: .constrained,
            blendDuration: 8
        )
        XCTAssertEqual(plan.mode, .edgesOnly)
        let edge = StemSeparationPolicy.edgeSeconds(blendDuration: 8) // 8 + 18 = 26
        XCTAssertEqual(plan.ranges, [0..<edge, (1_200 - edge)..<1_200])
        XCTAssertEqual(plan.totalSeconds, edge * 2, accuracy: 1e-9)
        // Far less work than a full-prefix cap of 600 s on the same tier.
        XCTAssertLessThan(plan.totalSeconds, StemSeparationPolicy.maxSeparationSeconds(for: .constrained))
    }

    func testPlanOnFullTierUsesPrefixCap() {
        let plan = StemSeparationPolicy.plan(trackDuration: 3_000, tier: .full)
        XCTAssertEqual(plan.mode, .fullPrefix)
        XCTAssertEqual(plan.ranges, [0..<1_800])
        XCTAssertEqual(plan.totalSeconds, 1_800, accuracy: 1e-9)
    }

    func testPlanOnBalancedUsesShorterPrefixCap() {
        let plan = StemSeparationPolicy.plan(trackDuration: 3_000, tier: .balanced)
        XCTAssertEqual(plan.mode, .fullPrefix)
        XCTAssertEqual(plan.ranges, [0..<900])
    }
}
