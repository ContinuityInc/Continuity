import XCTest
@testable import ContinuityCore

final class DuoLayoutTests: XCTestCase {
    func testExtraTopChromeOnlyWhenInsetIsShort() {
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: 59), 0)
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: 0), 24)
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: 12), 12)
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: .nan), 24)
    }

    func testFoldMidXAccountsForAsymmetricInsets() {
        // Duo unfolded landscape: content 867, trailing status 84, leading 0 → mid at 475.5.
        let mid = DuoLayout.foldContentMidX(contentWidth: 867, leadingInset: 0, trailingInset: 84)
        XCTAssertEqual(mid!, 475.5, accuracy: 0.01)
        let right = DuoLayout.rightPaneWidth(contentWidth: 867, leadingInset: 0, trailingInset: 84)
        XCTAssertEqual(right!, 391.5, accuracy: 0.01)
    }

    func testFoldMidXNilOnGarbage() {
        // Geometric mid still exists on a phone-width window; callers gate with usesFoldAwareGrid.
        let phoneMid = DuoLayout.foldContentMidX(contentWidth: 390, leadingInset: 0, trailingInset: 0)
        XCTAssertEqual(phoneMid!, 195, accuracy: 0.01)
        XCTAssertNil(DuoLayout.foldContentMidX(contentWidth: .nan, leadingInset: 0, trailingInset: 0))
        XCTAssertNil(DuoLayout.foldContentMidX(contentWidth: 0, leadingInset: 0, trailingInset: 0))
    }

    func testUsesFoldAwareGrid() {
        XCTAssertTrue(DuoLayout.usesFoldAwareGrid(width: 867, height: 669))
        XCTAssertFalse(DuoLayout.usesFoldAwareGrid(width: 402, height: 874))
        XCTAssertFalse(DuoLayout.usesFoldAwareGrid(width: 900, height: 1200)) // tall
        XCTAssertFalse(DuoLayout.usesFoldAwareGrid(width: .nan, height: 669))
    }

    func testFoldAwareColumnCountIsEvenAndPositive() {
        let result = DuoLayout.foldAwareColumnCount(
            contentWidth: 867, contentHeight: 669, leadingInset: 0, trailingInset: 84
        )
        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result!.perSide, 1)
        XCTAssertGreaterThan(result!.gutter, 0)
        // Phone-shaped window: no fold-aware grid.
        XCTAssertNil(DuoLayout.foldAwareColumnCount(
            contentWidth: 402, contentHeight: 874, leadingInset: 0, trailingInset: 0
        ))
    }

    func testRoundedSizeDropsSubpointsAndSanitizes() {
        let r = DuoLayout.roundedSize(width: 866.4, height: 668.6)
        XCTAssertEqual(r.width, 866)
        XCTAssertEqual(r.height, 669)
        let bad = DuoLayout.roundedSize(width: .nan, height: .infinity)
        XCTAssertEqual(bad.width, 0)
        XCTAssertEqual(bad.height, 0)
    }
}
