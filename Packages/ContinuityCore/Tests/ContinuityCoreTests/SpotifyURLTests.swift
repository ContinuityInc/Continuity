import XCTest
@testable import ContinuityCore

final class SpotifyURLTests: XCTestCase {

    func testParsesWebPlaylistURL() {
        let link = SpotifyURL.parse("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc123")
        XCTAssertEqual(link, SpotifyLink(kind: .playlist, id: "37i9dQZF1DXcBWIGoYBM5M"))
    }

    func testParsesEmbedURL() {
        let link = SpotifyURL.parse("https://open.spotify.com/embed/playlist/37i9dQZF1DXcBWIGoYBM5M")
        XCTAssertEqual(link, SpotifyLink(kind: .playlist, id: "37i9dQZF1DXcBWIGoYBM5M"))
    }

    func testParsesLocalePrefixedURL() {
        let link = SpotifyURL.parse("https://open.spotify.com/intl-de/album/4aawyAB9vmqN3uQ7FjRGTy")
        XCTAssertEqual(link, SpotifyLink(kind: .album, id: "4aawyAB9vmqN3uQ7FjRGTy"))
    }

    func testParsesURI() {
        XCTAssertEqual(
            SpotifyURL.parse("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"),
            SpotifyLink(kind: .playlist, id: "37i9dQZF1DXcBWIGoYBM5M")
        )
        XCTAssertEqual(
            SpotifyURL.parse("spotify:album:4aawyAB9vmqN3uQ7FjRGTy"),
            SpotifyLink(kind: .album, id: "4aawyAB9vmqN3uQ7FjRGTy")
        )
    }

    func testRejectsTrackAndNonSpotify() {
        XCTAssertNil(SpotifyURL.parse("spotify:track:20jbSiX29FDX4oQxBXyUEi"))          // a track, not a list
        XCTAssertNil(SpotifyURL.parse("https://open.spotify.com/artist/1HY2Jd0NmPuamShAr6KMms"))
        XCTAssertNil(SpotifyURL.parse("https://example.com/playlist/37i9dQZF1DXcBWIGoYBM5M"))
        XCTAssertNil(SpotifyURL.parse("https://open.spotify.com/playlist/short"))       // bad ID
        XCTAssertNil(SpotifyURL.parse(""))
    }

    func testPlaylistIDHelper() {
        XCTAssertEqual(SpotifyURL.playlistID(from: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"), "37i9dQZF1DXcBWIGoYBM5M")
        XCTAssertNil(SpotifyURL.playlistID(from: "spotify:album:4aawyAB9vmqN3uQ7FjRGTy"))   // album, not playlist
    }
}
