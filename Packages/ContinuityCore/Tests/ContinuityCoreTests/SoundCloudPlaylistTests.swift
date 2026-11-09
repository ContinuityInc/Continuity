import XCTest
@testable import ContinuityCore

final class SoundCloudPlaylistTests: XCTestCase {

    /// Trimmed `window.__sc_hydration` from a set page: the first two tracks hydrated, the rest
    /// as `{id, kind}` stubs. Includes a `]` inside a string to exercise the balanced scan.
    private let setHTML = """
    <html><head>
    <script crossorigin src="https://a-v2.sndcdn.com/assets/0-abc123.js"></script>
    <script crossorigin src="https://a-v2.sndcdn.com/assets/50-def456.js"></script>
    <script src="https://example.com/other.js"></script>
    </head><body>
    <script>window.__sc_hydration = [{"hydratable":"anonymousId","data":"123"},{"hydratable":"features","data":{"features":["a]b"]}},{"hydratable":"playlist","data":{"id":987,"kind":"playlist","title":"Actual Life 3","is_album":true,"track_count":4,"permalink_url":"https://soundcloud.com/fredagain/sets/actual-life-3","user":{"username":"Fred again.."},"tracks":[{"id":1,"kind":"track","title":"Fred again.. - Marea (We've Lost Dancing) [Free Download]","duration":212345,"permalink_url":"https://soundcloud.com/fredagain/marea","user":{"username":"Fred again.."},"publisher_metadata":{"artist":"Fred again.., The Blessed Madonna"}},{"id":2,"kind":"track","title":"Delilah (pull me out of this)","full_duration":180000,"user":{"username":"fredagain"}},{"id":3,"kind":"track","monetization_model":"NOT_APPLICABLE","policy":"ALLOW"},{"id":4,"kind":"track","policy":"ALLOW"},{"id":1,"kind":"track","policy":"ALLOW"}]}}];</script>
    </body></html>
    """

    func testParsesSetWithStubs() throws {
        let contents = try XCTUnwrap(SoundCloudPlaylist.parsePlaylist(html: setHTML))
        XCTAssertEqual(contents.title, "Actual Life 3")
        XCTAssertTrue(contents.isAlbum)
        XCTAssertEqual(contents.trackIDs, [1, 2, 3, 4])          // duplicate id dropped
        XCTAssertEqual(contents.hydratedTracks.count, 2)
        XCTAssertEqual(contents.pendingTrackIDs, [3, 4])

        let first = contents.hydratedTracks[0]
        XCTAssertEqual(first.artist, "Fred again.., The Blessed Madonna")   // publisher metadata wins
        XCTAssertEqual(first.durationSeconds, 212)
        XCTAssertEqual(contents.hydratedTracks[1].artist, "fredagain")     // falls back to uploader
        XCTAssertEqual(contents.hydratedTracks[1].durationSeconds, 180)   // full_duration fallback
    }

    func testAssemblesFetchedStubsInSetOrder() throws {
        let contents = try XCTUnwrap(SoundCloudPlaylist.parsePlaylist(html: setHTML))
        let fetched = [
            SoundCloudTrack(id: 4, title: "Four"),
            SoundCloudTrack(id: 3, title: "Three"),
            SoundCloudTrack(id: 99, title: "Not in set"),
        ]
        XCTAssertEqual(contents.assembled(with: fetched).map(\.id), [1, 2, 3, 4])
        // An unresolved stub is dropped rather than left as a hole.
        XCTAssertEqual(contents.assembled(with: [fetched[1]]).map(\.id), [1, 2, 3])
    }

    func testParsesTrackPage() throws {
        let html = """
        <script>window.__sc_hydration = [{"hydratable":"sound","data":{"id":55,"kind":"track","title":"Night Drive","duration":300000,"user":{"username":"someone"}}}];</script>
        """
        let track = try XCTUnwrap(SoundCloudPlaylist.parseTrack(html: html))
        XCTAssertEqual(track.id, 55)
        XCTAssertEqual(track.title, "Night Drive")
        XCTAssertEqual(track.artist, "someone")
        XCTAssertEqual(track.durationSeconds, 300)
        XCTAssertNil(SoundCloudPlaylist.parsePlaylist(html: html))   // a track page has no playlist entry
    }

    func testReturnsNilWithoutHydration() {
        XCTAssertNil(SoundCloudPlaylist.parsePlaylist(html: "<html>nope</html>"))
        XCTAssertNil(SoundCloudPlaylist.parseTrack(html: "<html>nope</html>"))
    }

    func testFindsAssetScriptsAndClientID() {
        let scripts = SoundCloudPlaylist.scriptURLs(html: setHTML)
        XCTAssertEqual(scripts.map(\.absoluteString), [
            "https://a-v2.sndcdn.com/assets/0-abc123.js",
            "https://a-v2.sndcdn.com/assets/50-def456.js",
        ])
        let bundle = #"var e={client_id:"AbCdEfGhIjKlMnOpQrStUvWxYz012345",base:"x"};"#
        XCTAssertEqual(SoundCloudPlaylist.clientID(inScript: bundle), "AbCdEfGhIjKlMnOpQrStUvWxYz012345")
        XCTAssertEqual(SoundCloudPlaylist.clientID(inScript: #"?client_id=zyxwvutsrqponmlkjihgfedcba543210&app"#), "zyxwvutsrqponmlkjihgfedcba543210")
        XCTAssertNil(SoundCloudPlaylist.clientID(inScript: #"client_id:"short""#))
    }

    func testParsesAPITracksResponse() {
        let json = """
        [{"id":3,"kind":"track","title":"Three","duration":1000,"user":{"username":"u"}},
         {"id":4,"kind":"track","title":"Four","duration":2000,"user":{"username":"v"}},
         {"id":5,"kind":"playlist","title":"not a track"}]
        """
        let tracks = SoundCloudPlaylist.parseTracksResponse(Data(json.utf8))
        XCTAssertEqual(tracks.map(\.id), [3, 4])
        XCTAssertEqual(tracks[1].durationSeconds, 2)

        let url = SoundCloudPlaylist.tracksRequestURL(ids: [3, 4], clientID: "cid")
        XCTAssertEqual(url?.absoluteString, "https://api-v2.soundcloud.com/tracks?ids=3,4&client_id=cid")
    }

    func testSearchQueryStripsPromoAndAvoidsDoubleArtist() {
        XCTAssertEqual(
            SoundCloudTrack(id: 1, title: "Fred again.. - Marea (We've Lost Dancing) [Free Download]", artist: "Fred again..").youtubeSearchQuery,
            "Fred again.. - Marea (We've Lost Dancing)"
        )
        XCTAssertEqual(
            SoundCloudTrack(id: 2, title: "Delilah (pull me out of this)", artist: "Fred again..").youtubeSearchQuery,
            "Delilah (pull me out of this) Fred again.."
        )
        // "Artist - Title" already names the act; the uploading label is not appended.
        XCTAssertEqual(
            SoundCloudTrack(id: 3, title: "Bicep - Glue", artist: "Ninja Tune").youtubeSearchQuery,
            "Bicep - Glue"
        )
        XCTAssertEqual(SoundCloudPlaylist.normalizedTitle("Glue (Bicep Remix) | Free DL"), "Glue (Bicep Remix)")
        XCTAssertEqual(SoundCloudPlaylist.normalizedTitle("(OUT NOW)"), "(OUT NOW)")   // never empties a title
    }
}
