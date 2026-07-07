import XCTest
@testable import ContinuityCore

final class SpotifyPlaylistTests: XCTestCase {

    /// Faithful trim of a Spotify embed page's `__NEXT_DATA__`: an entity carrying `name` +
    /// `trackList`, each track with `title`, `subtitle` (artist), `duration` (ms), `entityType`.
    private let embedHTML = """
    <html><body>
    <script id="__NEXT_DATA__" type="application/json">
    {"props":{"pageProps":{"state":{"data":{"entity":{
      "name":"Today's Top Hits",
      "uri":"spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",
      "trackList":[
        {"uri":"spotify:track:aaa","title":"hate that i made you love me","subtitle":"Ariana Grande","duration":197949,"entityType":"track"},
        {"uri":"spotify:track:bbb","title":"Die With A Smile","subtitle":"Lady Gaga, Bruno Mars","duration":251668,"entityType":"track"},
        {"uri":"spotify:episode:ccc","title":"Some Podcast","subtitle":"A Host","duration":600000,"entityType":"episode"}
      ]
    }}}}}}
    </script>
    </body></html>
    """

    func testParsesTracksAndName() {
        let contents = SpotifyPlaylist.parse(html: embedHTML)
        XCTAssertEqual(contents.name, "Today's Top Hits")
        // The podcast episode is skipped; only the two tracks remain.
        XCTAssertEqual(contents.tracks.count, 2)

        XCTAssertEqual(contents.tracks[0].title, "hate that i made you love me")
        XCTAssertEqual(contents.tracks[0].artist, "Ariana Grande")
        XCTAssertEqual(contents.tracks[0].durationSeconds, 198)          // 197949 ms rounded

        XCTAssertEqual(contents.tracks[1].title, "Die With A Smile")
        XCTAssertEqual(contents.tracks[1].artist, "Lady Gaga, Bruno Mars")
        XCTAssertEqual(contents.tracks[1].youtubeSearchQuery, "Die With A Smile Lady Gaga, Bruno Mars")
    }

    func testReturnsEmptyWithoutNextData() {
        XCTAssertTrue(SpotifyPlaylist.parse(html: "<html>no data</html>").isEmpty)
    }
}
