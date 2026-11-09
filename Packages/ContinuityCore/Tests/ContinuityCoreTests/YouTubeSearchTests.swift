import XCTest
@testable import ContinuityCore

final class YouTubeSearchTests: XCTestCase {

    /// Faithful trim of a search page: the ranked results array under
    /// `twoColumnSearchResultsRenderer`, whose first video result should win.
    private let searchHTML = """
    <script>var ytInitialData = {
      "contents": { "twoColumnSearchResultsRenderer": { "primaryContents": { "sectionListRenderer": { "contents": [
        { "itemSectionRenderer": { "contents": [
          { "videoRenderer": { "videoId": "kPa7bsKwL-c", "title": { "runs": [ { "text": "Die With A Smile" } ] } } },
          { "videoRenderer": { "videoId": "dQw4w9WgXcQ", "title": { "runs": [ { "text": "Another result" } ] } } }
        ] } }
      ] } } } }
    };</script>
    """

    func testReturnsTopRankedVideoID() {
        XCTAssertEqual(YouTubeSearch.firstVideoID(html: searchHTML), "kPa7bsKwL-c")
    }

    func testFallsBackToAnyVideoWhenPathChanges() {
        // No twoColumnSearchResultsRenderer path — should still find a videoRenderer anywhere.
        let html = """
        ytInitialData = {"someNewShape":{"stuff":[
          {"videoRenderer":{"videoId":"ZZZZZZZZZZZ"}}
        ]}};
        """
        XCTAssertEqual(YouTubeSearch.firstVideoID(html: html), "ZZZZZZZZZZZ")
    }

    func testReturnsNilWhenNoVideos() {
        XCTAssertNil(YouTubeSearch.firstVideoID(html: "ytInitialData = {\"contents\":{}};"))
        XCTAssertNil(YouTubeSearch.firstVideoID(html: "<html>nothing</html>"))
    }

    // MARK: Page outcome
    //
    // The distinction that matters to ingest: a real-but-empty results page is permanent, while
    // a page with no `ytInitialData` is a bot wall / consent interstitial and must be retried.
    // Collapsing both into `nil` is what failed every song of a fresh Spotify import.

    func testOutcomeFindsTopRankedVideo() {
        XCTAssertEqual(YouTubeSearch.outcome(html: searchHTML), .found("kPa7bsKwL-c"))
    }

    func testOutcomeReportsNoResultsForRealButEmptyPage() {
        XCTAssertEqual(YouTubeSearch.outcome(html: "ytInitialData = {\"contents\":{}};"), .noResults)
    }

    func testOutcomeReportsUnreadableForBotWall() {
        XCTAssertEqual(YouTubeSearch.outcome(html: "<html>nothing</html>"), .unreadable)
    }

    /// The consent interstitial YouTube serves to unrecognised clients: a full HTML page, no
    /// `ytInitialData` anywhere. Must classify as retryable, not "no such song".
    func testOutcomeReportsUnreadableForConsentInterstitial() {
        let consent = """
        <!DOCTYPE html><html><head><title>Before you continue to YouTube</title></head>
        <body><form action="https://consent.youtube.com/save"><button>Accept all</button></form></body></html>
        """
        XCTAssertEqual(YouTubeSearch.outcome(html: consent), .unreadable)
    }

    /// Truncated/garbled JSON is equally unreadable — don't mistake it for an empty result set.
    func testOutcomeReportsUnreadableForMalformedInitialData() {
        XCTAssertEqual(YouTubeSearch.outcome(html: "ytInitialData = {\"contents\": [ broken"), .unreadable)
    }

    func testFirstVideoIDStaysConsistentWithOutcome() {
        for html in [searchHTML, "ytInitialData = {\"contents\":{}};", "<html>nothing</html>"] {
            switch YouTubeSearch.outcome(html: html) {
            case .found(let id): XCTAssertEqual(YouTubeSearch.firstVideoID(html: html), id)
            case .noResults, .unreadable: XCTAssertNil(YouTubeSearch.firstVideoID(html: html))
            }
        }
    }
}
