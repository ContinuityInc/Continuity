import XCTest
@testable import ContinuityCore

final class DurationParsingTests: XCTestCase {

    func testTypicalTrackLengths() {
        XCTAssertEqual(DurationParsing.seconds(fromMilliseconds: 197_949), 198)
        XCTAssertEqual(DurationParsing.seconds(fromMilliseconds: 1_000), 1)
        XCTAssertEqual(DurationParsing.seconds(fromMilliseconds: 240_000), 240)
    }

    func testRejectsNonPositiveAndNonFinite() {
        XCTAssertNil(DurationParsing.seconds(fromMilliseconds: 0))
        XCTAssertNil(DurationParsing.seconds(fromMilliseconds: -5_000))
        XCTAssertNil(DurationParsing.seconds(fromMilliseconds: .nan))
        XCTAssertNil(DurationParsing.seconds(fromMilliseconds: .infinity))
        XCTAssertNil(DurationParsing.seconds(fromMilliseconds: -.infinity))
    }

    /// Hostile / corrupted JSON: `1e308` is finite as Double but overflows `Int((ms/1000).rounded())`.
    func testRejectsOverflowingMillisecondsWithoutTrapping() {
        XCTAssertNil(DurationParsing.seconds(fromMilliseconds: 1e308))
        XCTAssertNil(DurationParsing.seconds(fromMilliseconds: Double(DurationParsing.maxReasonableSeconds) * 1000 + 1_000))
        XCTAssertEqual(
            DurationParsing.seconds(fromMilliseconds: Double(DurationParsing.maxReasonableSeconds) * 1000),
            DurationParsing.maxReasonableSeconds
        )
    }

    func testNSNumberConvenience() throws {
        let json = #"{"duration":251668,"bad":1.0e308,"neg":-1000}"#.data(using: .utf8)!
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(DurationParsing.seconds(fromMillisecondsNumber: dict["duration"] as? NSNumber), 252)
        XCTAssertNil(DurationParsing.seconds(fromMillisecondsNumber: dict["bad"] as? NSNumber))
        XCTAssertNil(DurationParsing.seconds(fromMillisecondsNumber: dict["neg"] as? NSNumber))
        XCTAssertNil(DurationParsing.seconds(fromMillisecondsNumber: nil))
    }

    /// End-to-end: Spotify embed parse must survive a poisoned duration field.
    func testSpotifyPlaylistSurvivesHostileDuration() {
        let html = """
        <script id="__NEXT_DATA__" type="application/json">
        {"props":{"pageProps":{"state":{"data":{"entity":{
          "name":"X",
          "trackList":[
            {"title":"ok","subtitle":"A","duration":180000,"entityType":"track"},
            {"title":"bomb","subtitle":"B","duration":1.0e308,"entityType":"track"},
            {"title":"neg","subtitle":"C","duration":-5000,"entityType":"track"}
          ]
        }}}}}}
        </script>
        """
        let contents = SpotifyPlaylist.parse(html: html)
        XCTAssertEqual(contents.tracks.map(\.title), ["ok", "bomb", "neg"])
        XCTAssertEqual(contents.tracks.map(\.durationSeconds), [180, nil, nil])
    }

    func testSoundCloudTrackSurvivesHostileDuration() {
        let html = """
        <script>window.__sc_hydration = [{"hydratable":"sound","data":{"id":1,"kind":"track","title":"X","duration":1e308,"user":{"username":"u"}}}];</script>
        """
        let track = SoundCloudPlaylist.parseTrack(html: html)
        XCTAssertEqual(track?.title, "X")
        XCTAssertNil(track?.durationSeconds)
    }
}
