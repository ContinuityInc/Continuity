import XCTest
@testable import ContinuityCore

final class YouTubeURLTests: XCTestCase {

    func testStandardWatchURL() {
        XCTAssertEqual(YouTubeURL.videoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testShortURL() {
        XCTAssertEqual(YouTubeURL.videoID(from: "https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testShortURLWithQuery() {
        let link = YouTubeURL.parse("https://youtu.be/dQw4w9WgXcQ?t=42&list=PLabcdef12345")
        XCTAssertEqual(link?.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(link?.playlistID, "PLabcdef12345")
    }

    func testShortsURL() {
        XCTAssertEqual(YouTubeURL.videoID(from: "https://www.youtube.com/shorts/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testEmbedURL() {
        XCTAssertEqual(YouTubeURL.videoID(from: "https://www.youtube.com/embed/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testMusicSubdomain() {
        XCTAssertEqual(YouTubeURL.videoID(from: "https://music.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testNoSchemeIsAccepted() {
        XCTAssertEqual(YouTubeURL.videoID(from: "youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testBareVideoID() {
        let link = YouTubeURL.parse("dQw4w9WgXcQ")
        XCTAssertEqual(link?.videoID, "dQw4w9WgXcQ")
        XCTAssertNil(link?.playlistID)
    }

    func testWatchWithPlaylist() {
        let link = YouTubeURL.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLtesting1234567")
        XCTAssertEqual(link?.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(link?.playlistID, "PLtesting1234567")
    }

    func testPlaylistOnlyURL() {
        let link = YouTubeURL.parse("https://www.youtube.com/playlist?list=PLtesting1234567")
        XCTAssertNil(link?.videoID)
        XCTAssertEqual(link?.playlistID, "PLtesting1234567")
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(YouTubeURL.parse("not a url"))
        XCTAssertNil(YouTubeURL.parse("https://example.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(YouTubeURL.parse(""))
        XCTAssertNil(YouTubeURL.parse("https://www.youtube.com"))
    }

    func testInvalidVideoIDLengthRejected() {
        // 10 chars, not 11.
        XCTAssertNil(YouTubeURL.videoID(from: "https://youtu.be/shortid123"))
        XCTAssertFalse(YouTubeURL.isValidVideoID("tooLongVideoIDxx"))
        XCTAssertTrue(YouTubeURL.isValidVideoID("abc-_123XYZ"))
    }
}
