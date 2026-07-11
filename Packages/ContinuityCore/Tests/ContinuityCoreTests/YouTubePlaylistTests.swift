import XCTest
@testable import ContinuityCore

final class YouTubePlaylistTests: XCTestCase {

    /// A trimmed-down but structurally faithful `ytInitialData` blob: a playlist title plus two
    /// `playlistVideoRenderer` entries, wrapped in a <script> tag the way the real page ships it.
    /// The second entry's title deliberately contains a `{` to exercise the brace scanner's
    /// string handling.
    private let sampleHTML = """
    <!DOCTYPE html><html><head><title>x</title></head><body>
    <script nonce="abc">var ytInitialData = {
      "metadata": { "playlistMetadataRenderer": { "title": "Dangerous Summer" } },
      "contents": { "items": [
        { "playlistVideoRenderer": {
            "videoId": "7ccyYIfoRPg",
            "title": { "runs": [ { "text": "COM\\u00cb N GO" } ] },
            "shortBylineText": { "runs": [ { "text": "Yeat" } ] },
            "lengthSeconds": "212",
            "lengthText": { "simpleText": "3:32" }
        } },
        { "playlistVideoRenderer": {
            "videoId": "dQw4w9WgXcQ",
            "title": { "simpleText": "Brace { In Title" },
            "shortBylineText": { "runs": [ { "text": "Rick Astley" } ] },
            "lengthText": { "simpleText": "3:33" }
        } }
      ] }
    };</script>
    </body></html>
    """

    /// The 2026 `lockupViewModel` shape: videoId in `contentId`, title/author in
    /// `lockupMetadataViewModel`, and the duration as a clock-formatted overlay badge `text`.
    private let lockupHTML = """
    <script>var ytInitialData = {
      "metadata": { "playlistMetadataRenderer": { "title": "Top Hits" } },
      "contents": { "items": [
        { "lockupViewModel": {
            "contentId": "kPa7bsKwL-c",
            "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
            "contentImage": { "thumbnailViewModel": { "overlays": [ { "thumbnailBottomOverlayViewModel": {
              "badges": [ { "thumbnailBadgeViewModel": { "text": "4:13", "badgeStyle": "DEFAULT" } } ]
            } } ] } },
            "metadata": { "lockupMetadataViewModel": {
              "title": { "content": "Die With A Smile" },
              "metadata": { "contentMetadataViewModel": { "metadataRows": [
                { "metadataParts": [ { "text": { "content": "Lady Gaga" } } ] },
                { "metadataParts": [ { "text": { "content": "1.7B views" } }, { "text": { "content": "1 year ago" } } ] }
              ] } }
            } }
        } },
        { "lockupViewModel": {
            "contentId": "OTHERPLAYLST",
            "contentType": "LOCKUP_CONTENT_TYPE_PLAYLIST",
            "metadata": { "lockupMetadataViewModel": { "title": { "content": "A nested playlist, skip me" } } }
        } }
      ] }
    };</script>
    """

    func testParsesLockupShape() {
        let contents = YouTubePlaylist.parse(html: lockupHTML)
        XCTAssertEqual(contents.title, "Top Hits")
        // The nested-playlist lockup is skipped; only the video remains.
        XCTAssertEqual(contents.items.count, 1)

        let item = contents.items[0]
        XCTAssertEqual(item.videoID, "kPa7bsKwL-c")
        XCTAssertEqual(item.title, "Die With A Smile")
        XCTAssertEqual(item.author, "Lady Gaga")           // first metadata row, not "1.7B views"
        XCTAssertEqual(item.lengthSeconds, 253)             // "4:13"
    }

    func testIsClock() {
        XCTAssertTrue(YouTubePlaylist.isClock("4:13"))
        XCTAssertTrue(YouTubePlaylist.isClock("1:02:03"))
        XCTAssertFalse(YouTubePlaylist.isClock("1.7B views"))
        XCTAssertFalse(YouTubePlaylist.isClock("4:1"))      // seconds must be two digits
        XCTAssertFalse(YouTubePlaylist.isClock("12"))
    }

    func testParsesItemsInOrderWithMetadata() {
        let contents = YouTubePlaylist.parse(html: sampleHTML)
        XCTAssertEqual(contents.title, "Dangerous Summer")
        XCTAssertEqual(contents.items.count, 2)

        let first = contents.items[0]
        XCTAssertEqual(first.videoID, "7ccyYIfoRPg")
        XCTAssertEqual(first.title, "COMË N GO")
        XCTAssertEqual(first.author, "Yeat")
        XCTAssertEqual(first.lengthSeconds, 212)

        let second = contents.items[1]
        XCTAssertEqual(second.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(second.title, "Brace { In Title")   // brace inside a string didn't break scanning
        XCTAssertEqual(second.author, "Rick Astley")
        XCTAssertEqual(second.lengthSeconds, 213)           // derived from "3:33"
    }

    /// Faithful mini-fixture of the 2026 page shape: ytcfg (API key + client version) and a
    /// continuation node nested `continuationItemViewModel → continuationCommand →
    /// innertubeCommand → continuationCommand → token` alongside the video lockups.
    private let pagedHTML = """
    <script>ytcfg.set({"INNERTUBE_API_KEY":"AIzaTESTKEY123","INNERTUBE_CLIENT_VERSION":"2.20260708.00.00"});</script>
    <script>var ytInitialData = {
      "metadata": { "playlistMetadataRenderer": { "title": "Mega Mix" } },
      "contents": { "items": [
        { "lockupViewModel": {
            "contentId": "aaaaaaaaaaa", "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
            "metadata": { "lockupMetadataViewModel": { "title": { "content": "First" } } }
        } },
        { "continuationItemViewModel": {
            "trigger": "CONTINUATION_TRIGGER_ON_ITEM_SHOWN",
            "continuationCommand": { "innertubeCommand": {
              "commandMetadata": { "webCommandMetadata": { "sendPost": true, "apiUrl": "/youtubei/v1/browse" } },
              "continuationCommand": { "token": "4qmFTESTTOKEN", "request": "CONTINUATION_REQUEST_TYPE_BROWSE" }
            } }
        } }
      ] }
    };</script>
    """

    func testParsesContinuationTokenAndConfig() {
        let contents = YouTubePlaylist.parse(html: pagedHTML)
        XCTAssertEqual(contents.items.map(\.videoID), ["aaaaaaaaaaa"])
        XCTAssertEqual(contents.continuationToken, "4qmFTESTTOKEN")

        let config = YouTubePlaylist.innerTubeConfig(html: pagedHTML)
        XCTAssertEqual(config, InnerTubeConfig(apiKey: "AIzaTESTKEY123", clientVersion: "2.20260708.00.00"))
    }

    func testNoContinuationOnLastPage() {
        let contents = YouTubePlaylist.parse(html: sampleHTML)   // legacy fixture has no token
        XCTAssertNil(contents.continuationToken)
        XCTAssertNil(YouTubePlaylist.innerTubeConfig(html: sampleHTML))
    }

    /// Faithful mini-fixture of a `youtubei/v1/browse` continuation reply: more lockups inside
    /// `onResponseReceivedActions`, plus (optionally) the token for the following page.
    private func continuationJSON(withNextToken: Bool) -> Data {
        let next = withNextToken ? """
        , { "continuationItemViewModel": { "continuationCommand": { "innertubeCommand": {
            "continuationCommand": { "token": "NEXTPAGETOKEN", "request": "CONTINUATION_REQUEST_TYPE_BROWSE" }
        } } } }
        """ : ""
        return """
        { "responseContext": { "visitorData": "xyz" },
          "onResponseReceivedActions": [ { "appendContinuationItemsAction": { "continuationItems": [
            { "lockupViewModel": { "contentId": "bbbbbbbbbbb", "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
              "metadata": { "lockupMetadataViewModel": { "title": { "content": "Page Two" },
                "metadata": { "contentMetadataViewModel": { "metadataRows": [
                  { "metadataParts": [ { "text": { "content": "Artist Two" } } ] }
                ] } } } } } }
            \(next)
          ] } } ]
        }
        """.data(using: .utf8)!
    }

    func testParsesContinuationResponse() {
        let (items, token) = YouTubePlaylist.parseContinuationResponse(continuationJSON(withNextToken: true))
        XCTAssertEqual(items.map(\.videoID), ["bbbbbbbbbbb"])
        XCTAssertEqual(items[0].title, "Page Two")
        XCTAssertEqual(items[0].author, "Artist Two")
        XCTAssertEqual(token, "NEXTPAGETOKEN")
    }

    func testContinuationResponseWithoutNextTokenEndsPagination() {
        let (items, token) = YouTubePlaylist.parseContinuationResponse(continuationJSON(withNextToken: false))
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(token)
    }

    func testDeduplicatesRepeatedVideoIDs() {
        // Radio/mix playlists can repeat the same video; we keep first occurrence only.
        let html = """
        ytInitialData = {"x":[
          {"playlistVideoRenderer":{"videoId":"aaaaaaaaaaa","title":{"simpleText":"A"}}},
          {"playlistVideoRenderer":{"videoId":"aaaaaaaaaaa","title":{"simpleText":"A again"}}},
          {"playlistVideoRenderer":{"videoId":"bbbbbbbbbbb","title":{"simpleText":"B"}}}
        ]};
        """
        let contents = YouTubePlaylist.parse(html: html)
        XCTAssertEqual(contents.items.map(\.videoID), ["aaaaaaaaaaa", "bbbbbbbbbbb"])
    }

    func testSkipsInvalidVideoIDs() {
        let html = """
        ytInitialData = {"x":[
          {"playlistVideoRenderer":{"videoId":"tooshort","title":{"simpleText":"A"}}},
          {"playlistVideoRenderer":{"videoId":"ccccccccccc","title":{"simpleText":"C"}}}
        ]};
        """
        let contents = YouTubePlaylist.parse(html: html)
        XCTAssertEqual(contents.items.map(\.videoID), ["ccccccccccc"])
    }

    func testReturnsEmptyWhenNoInitialData() {
        let contents = YouTubePlaylist.parse(html: "<html><body>no data here</body></html>")
        XCTAssertTrue(contents.isEmpty)
        XCTAssertNil(contents.title)
    }

    func testParseClock() {
        XCTAssertEqual(YouTubePlaylist.parseClock("3:32"), 212)
        XCTAssertEqual(YouTubePlaylist.parseClock("1:02:03"), 3723)
        XCTAssertEqual(YouTubePlaylist.parseClock("0:09"), 9)
        XCTAssertNil(YouTubePlaylist.parseClock("not a clock"))
    }

    func testExtractBracedObjectMatchesBalancedBraces() {
        let html = #"prefix ytInitialData = {"a":{"b":"}"},"c":1} trailing junk {ignored}"#
        let json = YouTubePlaylist.extractBracedObject(in: html, afterMarker: "ytInitialData")
        XCTAssertEqual(json, #"{"a":{"b":"}"},"c":1}"#)
    }
}
