import XCTest
@testable import ContinuityCore

final class AppleMusicLibraryTests: XCTestCase {

    // MARK: Titles that must survive untouched

    func testPlainTitleIsUnchanged() {
        XCTAssertEqual(AppleMusicLibrary.normalizedTitle("Blinding Lights"), "Blinding Lights")
    }

    func testKeepsFeaturedArtistCredit() {
        XCTAssertEqual(
            AppleMusicLibrary.normalizedTitle("Sunflower (feat. Post Malone)"),
            "Sunflower (feat. Post Malone)"
        )
    }

    func testKeepsRecordingVariantsThatIdentifyADifferentTake() {
        // These name a genuinely different recording — YouTube titles carry them too.
        XCTAssertEqual(AppleMusicLibrary.normalizedTitle("Layla (Acoustic)"), "Layla (Acoustic)")
        XCTAssertEqual(AppleMusicLibrary.normalizedTitle("Alive (Live)"), "Alive (Live)")
        XCTAssertEqual(
            AppleMusicLibrary.normalizedTitle("Levels (Skrillex Remix)"),
            "Levels (Skrillex Remix)"
        )
    }

    func testKeepsDashSegmentThatIsNotEditionNoise() {
        XCTAssertEqual(
            AppleMusicLibrary.normalizedTitle("Sgt. Pepper's Lonely Hearts Club Band - Reprise"),
            "Sgt. Pepper's Lonely Hearts Club Band - Reprise"
        )
    }

    // MARK: Edition noise that must be stripped

    func testStripsParentheticalRemaster() {
        XCTAssertEqual(
            AppleMusicLibrary.normalizedTitle("Come Together (Remastered 2009)"),
            "Come Together"
        )
    }

    func testStripsBracketedRemaster() {
        XCTAssertEqual(AppleMusicLibrary.normalizedTitle("Paranoid [Remastered]"), "Paranoid")
    }

    func testStripsTrailingDashRemaster() {
        XCTAssertEqual(
            AppleMusicLibrary.normalizedTitle("Marquee Moon - 2003 Remaster"),
            "Marquee Moon"
        )
    }

    func testStripsMultipleTrailingDashSegments() {
        XCTAssertEqual(
            AppleMusicLibrary.normalizedTitle("Dreams - Deluxe Edition - Remastered"),
            "Dreams"
        )
    }

    func testStripsDeluxeAndBonusTrackMarkers() {
        XCTAssertEqual(AppleMusicLibrary.normalizedTitle("Runaway (Deluxe Edition)"), "Runaway")
        XCTAssertEqual(AppleMusicLibrary.normalizedTitle("Hey Now (Bonus Track)"), "Hey Now")
        XCTAssertEqual(AppleMusicLibrary.normalizedTitle("Rockstar (Explicit)"), "Rockstar")
    }

    func testStripsNoiseButKeepsMeaningfulSegment() {
        XCTAssertEqual(
            AppleMusicLibrary.normalizedTitle("Whole Lotta Love (Live) (Remastered)"),
            "Whole Lotta Love (Live)"
        )
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(AppleMusicLibrary.normalizedTitle("Roads (REMASTERED)"), "Roads")
    }

    // MARK: Degenerate input

    func testTitleThatIsEntirelyNoiseIsKeptVerbatim() {
        // Better a bad query than an empty one — an empty search matches nothing at all.
        XCTAssertEqual(AppleMusicLibrary.normalizedTitle("(Remastered)"), "(Remastered)")
    }

    func testUnbalancedBracketIsLeftAlone() {
        XCTAssertEqual(AppleMusicLibrary.normalizedTitle("Untitled (unclosed"), "Untitled (unclosed")
    }

    func testCollapsesWhitespaceLeftBehind() {
        XCTAssertEqual(
            AppleMusicLibrary.normalizedTitle("Karma Police  (Remastered)  "),
            "Karma Police"
        )
    }

    // MARK: Search-query assembly

    func testSearchQueryJoinsNormalizedTitleAndArtist() {
        let track = AppleMusicTrack(title: "Come Together (Remastered 2009)", artist: "The Beatles")
        XCTAssertEqual(track.youtubeSearchQuery, "Come Together The Beatles")
    }

    func testSearchQueryOmitsMissingArtist() {
        let track = AppleMusicTrack(title: "Untitled Demo")
        XCTAssertEqual(track.youtubeSearchQuery, "Untitled Demo")
    }

    func testPlaylistContentsReportsEmptiness() {
        let empty = AppleMusicPlaylistContents(persistentID: "1", name: "Empty", tracks: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.id, "1")

        let full = AppleMusicPlaylistContents(
            persistentID: "2",
            name: "Road Trip",
            tracks: [AppleMusicTrack(title: "Go", artist: "Band")]
        )
        XCTAssertFalse(full.isEmpty)
    }
}
