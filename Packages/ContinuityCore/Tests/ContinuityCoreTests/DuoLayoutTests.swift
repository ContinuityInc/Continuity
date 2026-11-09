import XCTest
@testable import ContinuityCore

/// Pins measured-size Duo geometry so fold/unfold and right-edge status bar never regress to
/// idiom / `UIScreen` / size-class heuristics. Each case is a real window shape (inner display,
/// outer tent landscape, portrait phone) or a garbage resize frame during a live fold.
final class DuoLayoutTests: XCTestCase {
    func testExtraTopChromeOnlyWhenInsetIsShort() {
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: 59), 0)
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: 0), 24)
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: 12), 12)
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: .nan), 24)
    }

    func testExtraTopChromeCollapsedAndNegativeInsets() {
        // Duo inner: status bar on the RIGHT → top inset ≈ 0; chevron needs the full minimum.
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: 0.4), 23.6, accuracy: 1e-9)
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: DuoLayout.minimumTopChrome), 0)
        // Negative / −inf insets behave like zero (never shrink chrome below the minimum).
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: -12), 24)
        // ±inf / NaN are non-finite → safe full minimum (never trust a garbage inset).
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: -.infinity), 24)
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: .infinity), 24)
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: 10, minimum: .nan), 24)
        XCTAssertEqual(DuoLayout.extraTopChrome(topInset: 10, minimum: -.infinity), 24)
    }

    func testPageHeightAddsVerticalInsets() {
        // GeometryReader inside safe area + ScrollView that ignores it (MainPagerView).
        XCTAssertEqual(
            DuoLayout.pageHeight(safeAreaHeight: 669, topInset: 59, bottomInset: 34),
            762,
            accuracy: 1e-9
        )
        // Duo inner: collapsed top, home indicator still present.
        XCTAssertEqual(
            DuoLayout.pageHeight(safeAreaHeight: 669, topInset: 0, bottomInset: 21),
            690,
            accuracy: 1e-9
        )
        // Outer-display tent landscape: short top, side status is horizontal — vertical still adds.
        XCTAssertEqual(
            DuoLayout.pageHeight(safeAreaHeight: 360, topInset: 0, bottomInset: 21),
            381,
            accuracy: 1e-9
        )
    }

    func testPageHeightSanitizesGarbage() {
        XCTAssertEqual(DuoLayout.pageHeight(safeAreaHeight: .nan, topInset: 59, bottomInset: 34), 0)
        XCTAssertEqual(DuoLayout.pageHeight(safeAreaHeight: .infinity, topInset: 0, bottomInset: 0), 0)
        XCTAssertEqual(DuoLayout.pageHeight(safeAreaHeight: 400, topInset: .nan, bottomInset: 20), 420)
        XCTAssertEqual(DuoLayout.pageHeight(safeAreaHeight: 400, topInset: 20, bottomInset: .infinity), 420)
        XCTAssertEqual(DuoLayout.pageHeight(safeAreaHeight: 400, topInset: -10, bottomInset: -5), 400)
        XCTAssertEqual(DuoLayout.pageHeight(safeAreaHeight: 0, topInset: 0, bottomInset: 0), 0)
        XCTAssertEqual(DuoLayout.pageHeight(safeAreaHeight: -100, topInset: 59, bottomInset: 34), 0)
    }

    func testFoldMidXAccountsForAsymmetricInsets() {
        // Duo unfolded landscape: content 867, trailing status 84, leading 0 → mid at 475.5.
        let mid = DuoLayout.foldContentMidX(contentWidth: 867, leadingInset: 0, trailingInset: 84)
        XCTAssertEqual(mid!, 475.5, accuracy: 0.01)
        let right = DuoLayout.rightPaneWidth(contentWidth: 867, leadingInset: 0, trailingInset: 84)
        XCTAssertEqual(right!, 391.5, accuracy: 0.01)
    }

    func testFoldMidXWithSymmetricAndLeadingHeavyInsets() {
        // Symmetric insets: fold sits at content mid.
        XCTAssertEqual(
            DuoLayout.foldContentMidX(contentWidth: 800, leadingInset: 40, trailingInset: 40)!,
            400,
            accuracy: 1e-9
        )
        // Leading-heavy (mirrored / RTL-ish window): mid shifts left in content space.
        // full = 900 + 100 + 20 = 1020, mid panel = 510, content midX = 510 - 100 = 410.
        XCTAssertEqual(
            DuoLayout.foldContentMidX(contentWidth: 900, leadingInset: 100, trailingInset: 20)!,
            410,
            accuracy: 1e-9
        )
        let right = DuoLayout.rightPaneWidth(contentWidth: 900, leadingInset: 100, trailingInset: 20)
        XCTAssertEqual(right!, 490, accuracy: 1e-9)
    }

    func testFoldMidXNilOnGarbageAndEdgePlacement() {
        // Geometric mid still exists on a phone-width window; callers gate with usesFoldAwareGrid.
        let phoneMid = DuoLayout.foldContentMidX(contentWidth: 390, leadingInset: 0, trailingInset: 0)
        XCTAssertEqual(phoneMid!, 195, accuracy: 0.01)
        XCTAssertNil(DuoLayout.foldContentMidX(contentWidth: .nan, leadingInset: 0, trailingInset: 0))
        XCTAssertNil(DuoLayout.foldContentMidX(contentWidth: 0, leadingInset: 0, trailingInset: 0))
        XCTAssertNil(DuoLayout.foldContentMidX(contentWidth: -.infinity, leadingInset: 0, trailingInset: 0))
        // Mid lands on / past the content edge when leading inset swallows the panel mid.
        // full = 100 + 200 + 0 = 300, mid = 150, content midX = 150 - 200 = −50 → nil.
        XCTAssertNil(DuoLayout.foldContentMidX(contentWidth: 100, leadingInset: 200, trailingInset: 0))
        // full = 100 + 0 + 200 = 300, mid = 150, content midX = 150 → past contentWidth → nil.
        XCTAssertNil(DuoLayout.foldContentMidX(contentWidth: 100, leadingInset: 0, trailingInset: 200))
        XCTAssertNil(DuoLayout.foldContentMidX(contentWidth: 800, leadingInset: .nan, trailingInset: 0))
        XCTAssertNil(DuoLayout.rightPaneWidth(contentWidth: .nan, leadingInset: 0, trailingInset: 0))
    }

    func testUsesFoldAwareGrid() {
        XCTAssertTrue(DuoLayout.usesFoldAwareGrid(width: 867, height: 669))
        XCTAssertFalse(DuoLayout.usesFoldAwareGrid(width: 402, height: 874))
        XCTAssertFalse(DuoLayout.usesFoldAwareGrid(width: 900, height: 1200)) // tall
        XCTAssertFalse(DuoLayout.usesFoldAwareGrid(width: .nan, height: 669))
    }

    func testUsesFoldAwareGridThresholdsAndTentLandscape() {
        // Exact min width + near-square aspect → fold-aware.
        XCTAssertTrue(DuoLayout.usesFoldAwareGrid(width: DuoLayout.foldAwareGridMinWidth, height: 700))
        // Just under the width floor keeps the adaptive grid even if wide-ish.
        XCTAssertFalse(DuoLayout.usesFoldAwareGrid(width: DuoLayout.foldAwareGridMinWidth - 1, height: 600))
        // Aspect floor: width >= height * 0.85. At height 1000, need width ≥ 850.
        XCTAssertTrue(DuoLayout.usesFoldAwareGrid(width: 850, height: 1000))
        XCTAssertFalse(DuoLayout.usesFoldAwareGrid(width: 849, height: 1000))
        // Outer-display tent landscape: phone-wide rotated — no hinge, never fold-aware.
        XCTAssertFalse(DuoLayout.usesFoldAwareGrid(width: 874, height: 402))
        XCTAssertFalse(DuoLayout.usesFoldAwareGrid(width: 956, height: 440))
        // Aspect ceiling: height must be ≥ width * 0.55 (max ~1.82∶1).
        XCTAssertTrue(DuoLayout.usesFoldAwareGrid(width: 1000, height: 550))
        XCTAssertFalse(DuoLayout.usesFoldAwareGrid(width: 1000, height: 549))
        XCTAssertFalse(DuoLayout.usesFoldAwareGrid(width: 900, height: .nan))
        XCTAssertFalse(DuoLayout.usesFoldAwareGrid(width: .infinity, height: 669))
    }

    func testFoldAwareColumnCountIsEvenAndPositive() {
        let result = DuoLayout.foldAwareColumnCount(
            viewportWidth: 867, viewportHeight: 669, leadingInset: 0, trailingInset: 84
        )
        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result!.perSide, 1)
        XCTAssertGreaterThan(result!.gutter, 0)
        // Phone-shaped window: no fold-aware grid.
        XCTAssertNil(DuoLayout.foldAwareColumnCount(
            viewportWidth: 402, viewportHeight: 874, leadingInset: 0, trailingInset: 0
        ))
        // A tall *content* height must not be passed here — but if the viewport itself is
        // tall (outer display / portrait mirroring), keep the adaptive grid.
        XCTAssertNil(DuoLayout.foldAwareColumnCount(
            viewportWidth: 867, viewportHeight: 1200, leadingInset: 0, trailingInset: 84
        ))
    }

    func testFoldAwareColumnCountRefusesTinyHalvesAndGarbage() {
        // Wide near-square but half panes too narrow for one card + gutter.
        XCTAssertNil(DuoLayout.foldAwareColumnCount(
            viewportWidth: 700, viewportHeight: 700, leadingInset: 0, trailingInset: 0,
            minimum: 400, spacing: 16
        ))
        XCTAssertNil(DuoLayout.foldAwareColumnCount(
            viewportWidth: 867, viewportHeight: 669, leadingInset: 0, trailingInset: 84,
            minimum: .nan, spacing: 16
        ))
        XCTAssertNil(DuoLayout.foldAwareColumnCount(
            viewportWidth: 867, viewportHeight: 669, leadingInset: 0, trailingInset: 84,
            minimum: 0, spacing: 16
        ))
        XCTAssertNil(DuoLayout.foldAwareColumnCount(
            viewportWidth: 867, viewportHeight: 669, leadingInset: 0, trailingInset: 84,
            minimum: 150, spacing: -.infinity
        ))
        // Tent landscape: width can look "Duo-ish" but height is phone-short → nil.
        XCTAssertNil(DuoLayout.foldAwareColumnCount(
            viewportWidth: 874, viewportHeight: 402, leadingInset: 59, trailingInset: 59
        ))
    }

    func testFoldAwareColumnCountGutterAndBalanceWithInsets() {
        let result = try! XCTUnwrap(DuoLayout.foldAwareColumnCount(
            viewportWidth: 867, viewportHeight: 669, leadingInset: 0, trailingInset: 84
        ))
        // Gutter = spacing + 8 with the default library spacing.
        XCTAssertEqual(result.gutter, DuoLayout.libraryCardSpacing + 8, accuracy: 1e-9)
        // Both panes must fit `perSide` cards; shorter side is the limiter.
        let mid = DuoLayout.foldContentMidX(contentWidth: 867, leadingInset: 0, trailingInset: 84)!
        let half = min(mid, 867 - mid)
        let usable = half - result.gutter / 2
        let expected = max(1, Int((usable + DuoLayout.libraryCardSpacing) / (DuoLayout.libraryCardMinimum + DuoLayout.libraryCardSpacing)))
        XCTAssertEqual(result.perSide, expected)
    }

    func testRoundedSizeDropsSubpointsAndSanitizes() {
        let r = DuoLayout.roundedSize(width: 866.4, height: 668.6)
        XCTAssertEqual(r.width, 866)
        XCTAssertEqual(r.height, 669)
        let bad = DuoLayout.roundedSize(width: .nan, height: .infinity)
        XCTAssertEqual(bad.width, 0)
        XCTAssertEqual(bad.height, 0)
        let negInf = DuoLayout.roundedSize(width: -.infinity, height: -12.4)
        XCTAssertEqual(negInf.width, 0)
        XCTAssertEqual(negInf.height, -12)
    }
}
