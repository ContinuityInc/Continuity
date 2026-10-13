import XCTest
@testable import ContinuityCore

final class AdaptiveQualityTests: XCTestCase {
    func testHighRAMCoolIsFull() {
        let tier = AdaptiveQuality.tier(
            physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
            thermalSeriousOrWorse: false,
            lowPowerMode: false
        )
        XCTAssertEqual(tier, .full)
    }

    func testMidRAMIsBalanced() {
        let tier = AdaptiveQuality.tier(
            physicalMemoryBytes: 5 * 1024 * 1024 * 1024,
            thermalSeriousOrWorse: false,
            lowPowerMode: false
        )
        XCTAssertEqual(tier, .balanced)
        XCTAssertTrue(AdaptiveQuality.prefersOpaqueChrome(for: tier))
        XCTAssertFalse(AdaptiveQuality.allowsFullTickRate(for: tier))
    }

    func testLowRAMOrThermalOrLPMIsConstrained() {
        XCTAssertEqual(
            AdaptiveQuality.tier(
                physicalMemoryBytes: 3 * 1024 * 1024 * 1024,
                thermalSeriousOrWorse: false,
                lowPowerMode: false
            ),
            .constrained
        )
        XCTAssertEqual(
            AdaptiveQuality.tier(
                physicalMemoryBytes: 12 * 1024 * 1024 * 1024,
                thermalSeriousOrWorse: true,
                lowPowerMode: false
            ),
            .constrained
        )
        XCTAssertEqual(
            AdaptiveQuality.tier(
                physicalMemoryBytes: 12 * 1024 * 1024 * 1024,
                thermalSeriousOrWorse: false,
                lowPowerMode: true
            ),
            .constrained
        )
        XCTAssertTrue(AdaptiveQuality.shouldDeferStemSeparation(for: .constrained))
        XCTAssertGreaterThan(
            AdaptiveQuality.stemRequiredStartMB(for: .constrained),
            AdaptiveQuality.stemRequiredStartMB(for: .full)
        )
        XCTAssertGreaterThan(
            AdaptiveQuality.stemHoldSeconds(for: .constrained),
            AdaptiveQuality.stemHoldSeconds(for: .full)
        )
    }

    func testArtworkBudgetsShrinkWithTier() {
        XCTAssertGreaterThan(
            AdaptiveQuality.heroArtworkMaxPixel(for: .full),
            AdaptiveQuality.heroArtworkMaxPixel(for: .constrained)
        )
        XCTAssertGreaterThanOrEqual(
            AdaptiveQuality.rowArtworkMaxPixel(for: .full),
            AdaptiveQuality.rowArtworkMaxPixel(for: .constrained)
        )
    }
}
