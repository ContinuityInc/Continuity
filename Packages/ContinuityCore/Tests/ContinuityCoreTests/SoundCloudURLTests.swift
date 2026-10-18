import XCTest
@testable import ContinuityCore

final class SoundCloudURLTests: XCTestCase {

    func testParsesSetURL() {
        let link = SoundCloudURL.parse("https://soundcloud.com/fredagain/sets/actual-life-3?si=abc&utm_source=clipboard")
        XCTAssertEqual(link, SoundCloudLink(kind: .playlist, path: "fredagain/sets/actual-life-3"))
        XCTAssertEqual(link?.permalinkURL?.absoluteString, "https://soundcloud.com/fredagain/sets/actual-life-3")
        XCTAssertEqual(link?.sourceID, "fredagain/sets/actual-life-3")
    }

    func testParsesTrackURLAndMobileHost() {
        XCTAssertEqual(
            SoundCloudURL.parse("m.soundcloud.com/fredagain/marea-we-ve-lost-dancing"),
            SoundCloudLink(kind: .track, path: "fredagain/marea-we-ve-lost-dancing")
        )
        // Sub-tabs of the same track page collapse to the track.
        XCTAssertEqual(
            SoundCloudURL.parse("https://www.soundcloud.com/FredAgain/Marea/comments"),
            SoundCloudLink(kind: .track, path: "fredagain/marea")
        )
    }

    func testKeepsPrivateShareToken() {
        XCTAssertEqual(
            SoundCloudURL.parse("https://soundcloud.com/user-1/sets/secret-mix/s-AbC12xYz"),
            SoundCloudLink(kind: .playlist, path: "user-1/sets/secret-mix/s-AbC12xYz")
        )
        XCTAssertEqual(
            SoundCloudURL.parse("https://soundcloud.com/user-1/demo/s-qq1"),
            SoundCloudLink(kind: .track, path: "user-1/demo/s-qq1")
        )
    }

    func testParsesShortLink() {
        let link = SoundCloudURL.parse("https://on.soundcloud.com/Xy9Zk")
        XCTAssertEqual(link?.kind, .shortLink)
        XCTAssertEqual(link?.permalinkURL?.absoluteString, "https://on.soundcloud.com/Xy9Zk")   // codes are case-sensitive
        XCTAssertNil(SoundCloudURL.parse("https://on.soundcloud.com/"))
    }

    func testRejectsProfilesSectionsAndOtherHosts() {
        XCTAssertNil(SoundCloudURL.parse("https://soundcloud.com/fredagain"))                 // profile
        XCTAssertNil(SoundCloudURL.parse("https://soundcloud.com/fredagain/sets"))            // all sets tab
        XCTAssertNil(SoundCloudURL.parse("https://soundcloud.com/fredagain/likes"))           // likes tab
        XCTAssertNil(SoundCloudURL.parse("https://soundcloud.com/fredagain/tracks"))          // tracks tab
        XCTAssertNil(SoundCloudURL.parse("https://soundcloud.com/discover/sets/charts-top:all-music"))
        XCTAssertNil(SoundCloudURL.parse("https://soundcloud.com/you/likes"))
        XCTAssertNil(SoundCloudURL.parse("https://api.soundcloud.com/playlists/123"))
        XCTAssertNil(SoundCloudURL.parse("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M"))
        XCTAssertNil(SoundCloudURL.parse("https://soundcloud.com/fredagain/sets/bad slug"))
        XCTAssertNil(SoundCloudURL.parse(""))
    }
}
