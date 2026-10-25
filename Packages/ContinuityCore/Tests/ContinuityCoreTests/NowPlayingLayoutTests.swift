import XCTest
@testable import ContinuityCore

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

    func testArtworkSides() {
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.column, width: 402, height: 874), 280)
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.column, width: 700, height: 1000), 360)
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.column, width: .nan, height: 800), 280)
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.sideBySide, width: 900, height: 900), 420)
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.sideBySide, width: 900, height: 560), 372)
        XCTAssertEqual(NowPlayingLayout.artworkMaxSide(.sideBySide, width: 900, height: .nan), 280)
    }
}
