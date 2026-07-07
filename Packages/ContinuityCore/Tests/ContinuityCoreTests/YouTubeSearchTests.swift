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
}
