import XCTest
@testable import ContinuityCore

/// Pins Now Playing arrangement thresholds to measured page size — never idiom / orientation /
/// `UIScreen`. Covers Duo inner (wide near-square), outer tent landscape, and fold-transient junk.
final class NowPlayingLayoutTests: XCTestCase {
    func testPhonesKeepTheColumn() {
        // iPhone 17 Pro Max / iPhone Duo outer display / iPhone mini, portrait.
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 440, height: 956), .column)
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 402, height: 874), .column)
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 375, height: 812), .column)
    }

    func testWideNearSquareWindowGoesSideBySide() {
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 820, height: 760), .sideBySide)
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 1100, height: 700), .sideBySide)
        // Duo inner display (approx. content after right-edge status column).
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 867, height: 669), .sideBySide)
    }

    func testTallWideWindowKeepsTheColumn() {
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 700, height: 1000), .column)
    }

    func testShortWindowKeepsTheColumn() {
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 900, height: 400), .column)
    }

    func testNonFiniteOrZeroSizeFallsBackToColumn() {
        XCTAssertEqual(NowPlayingLayout.arrangement(width: .nan, height: 800), .column)
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 900, height: .infinity), .column)
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 0, height: 0), .column)
    }

    func testArrangementExactThresholds() {
        // Width / height floors are inclusive.
        XCTAssertEqual(
            NowPlayingLayout.arrangement(
                width: NowPlayingLayout.sideBySideMinWidth,
                height: NowPlayingLayout.sideBySideMinHeight
            ),
            .sideBySide
        )
        XCTAssertEqual(
            NowPlayingLayout.arrangement(
                width: NowPlayingLayout.sideBySideMinWidth - 1,
                height: 800
            ),
            .column
        )
        XCTAssertEqual(
            NowPlayingLayout.arrangement(
                width: 900,
                height: NowPlayingLayout.sideBySideMinHeight - 1
            ),
            .column
        )
        // Aspect floor: width >= height * 0.9. At height 700, need width ≥ 630 — but width floor
        // is 640, so the binding case is height where 0.9*h == width floor… use a taller window:
        // width 640, height 711 → 640 < 711*0.9 (=639.9)? 640 >= 639.9 → sideBySide.
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 640, height: 711), .sideBySide)
        // width 640, height 712 → 640 < 640.8 → column (just shy of square-ish).
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 640, height: 712), .column)
    }

    func testOuterDisplayTentLandscapeStaysColumn() {
        // Allowed landscape pose on the outer display: wide-but-short phone window.
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 874, height: 402), .column)
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 956, height: 440), .column)
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 812, height: 375), .column)
    }

    func testNegativeAndMinusInfinityFallBackToColumn() {
        XCTAssertEqual(NowPlayingLayout.arrangement(width: -900, height: 800), .column)
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 900, height: -800), .column)
        XCTAssertEqual(NowPlayingLayout.arrangement(width: -.infinity, height: 800), .column)
        XCTAssertEqual(NowPlayingLayout.arrangement(width: 900, height: -.infinity), .column)
    }

    func testArtworkSides() {
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.column, width: 402, height: 874), 280)
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.column, width: 700, height: 1000), 360)
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.column, width: .nan, height: 800), 280)
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.sideBySide, width: 900, height: 900), 420)
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.sideBySide, width: 900, height: 560), 372)
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.sideBySide, width: 900, height: .nan), 280)
    }

    func testArtworkSideBySideClampsToFloorAndCeiling() {
        // height - chromeBand - 48 below the 280 floor → clamp up.
        // chromeBandHeight = 140; at height 520: 520 - 140 - 48 = 332.
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.sideBySide, width: 900, height: 520), 332)
        // Tiny height would undershoot the floor.
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.sideBySide, width: 900, height: 400), 280)
        // Tall window hits the 420 cap.
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.sideBySide, width: 900, height: 2000), 420)
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.sideBySide, width: 900, height: -.infinity), 280)
        // Column stays 280 under the 600pt wide threshold, including negatives.
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.column, width: 599, height: 800), 280)
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.column, width: 600, height: 800), 360)
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.column, width: -.infinity, height: 800), 280)
    }
}
