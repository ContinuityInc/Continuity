import XCTest
@testable import ContinuityCore

final class ArtworkDecodeCoalesceTests: XCTestCase {

    func testSharedMaxPixelTakesLargestFiniteBudget() {
        XCTAssertEqual(
            ArtworkDecodeCoalesce.sharedMaxPixel([512, 900, 150]),
            900
        )
        XCTAssertEqual(
            ArtworkDecodeCoalesce.sharedMaxPixel([
                AdaptiveQuality.backdropArtworkMaxPixel(for: .full),
                AdaptiveQuality.heroArtworkMaxPixel(for: .full),
            ]),
            AdaptiveQuality.heroArtworkMaxPixel(for: .full)
        )
    }

    func testSharedMaxPixelIgnoresNonPositiveAndNonFinite() {
        XCTAssertEqual(ArtworkDecodeCoalesce.sharedMaxPixel([]), 0)
        XCTAssertEqual(ArtworkDecodeCoalesce.sharedMaxPixel([-1, 0, .nan, .infinity]), 0)
        XCTAssertEqual(ArtworkDecodeCoalesce.sharedMaxPixel([.nan, 512, -.infinity]), 512)
    }

    func testCachedLargerDecodeSatisfiesSmallerRequest() {
        XCTAssertTrue(
            ArtworkDecodeCoalesce.cachedSatisfiesRequest(
                cachedMaxPixel: 900,
                requestedMaxPixel: 512
            )
        )
        XCTAssertTrue(
            ArtworkDecodeCoalesce.cachedSatisfiesRequest(
                cachedMaxPixel: 512,
                requestedMaxPixel: 512
            )
        )
        XCTAssertFalse(
            ArtworkDecodeCoalesce.cachedSatisfiesRequest(
                cachedMaxPixel: 512,
                requestedMaxPixel: 900
            )
        )
    }

    func testCachedSatisfiesRejectsGarbage() {
        XCTAssertFalse(
            ArtworkDecodeCoalesce.cachedSatisfiesRequest(
                cachedMaxPixel: .nan,
                requestedMaxPixel: 512
            )
        )
        XCTAssertFalse(
            ArtworkDecodeCoalesce.cachedSatisfiesRequest(
                cachedMaxPixel: 900,
                requestedMaxPixel: 0
            )
        )
    }

    func testBackdropBudgetNeverExceedsHero() {
        for tier in AdaptiveQualityTier.allCases {
            XCTAssertLessThanOrEqual(
                AdaptiveQuality.backdropArtworkMaxPixel(for: tier),
                AdaptiveQuality.heroArtworkMaxPixel(for: tier),
                "backdrop must stay ≤ hero so one hero decode can feed the palette pass"
            )
        }
    }

    func testYouTubeHqdefaultClimbsSharperTiersThenOriginal() {
        let hq = URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")!
        let urls = ArtworkThumbnailCandidates.urls(for: hq)
        XCTAssertEqual(urls.count, 3)
        XCTAssertTrue(urls[0].absoluteString.contains("/maxresdefault"))
        XCTAssertTrue(urls[1].absoluteString.contains("/sddefault"))
        XCTAssertEqual(urls[2], hq)
    }

    func testNonYouTubeURLIsSingleCandidate() {
        let cover = URL(string: "file:///tmp/cover.jpg")!
        XCTAssertEqual(ArtworkThumbnailCandidates.urls(for: cover), [cover])
    }
}
