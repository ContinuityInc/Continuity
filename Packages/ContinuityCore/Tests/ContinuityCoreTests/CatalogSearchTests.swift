import XCTest
@testable import ContinuityCore

final class CatalogSearchTests: XCTestCase {

    // MARK: Query planning

    func testQueryVariantsIncludeStrippedAndSplitForms() {
        let variants = CatalogSearch.queryVariants(from: "HUMBLE. - Kendrick Lamar (Clean)")
        XCTAssertEqual(variants.first, "HUMBLE. - Kendrick Lamar (Clean)")
        XCTAssertTrue(variants.contains("HUMBLE. - Kendrick Lamar"))
        XCTAssertTrue(variants.contains { $0.localizedCaseInsensitiveContains("Kendrick Lamar") && $0.localizedCaseInsensitiveContains("HUMBLE") })
        XCTAssertLessThanOrEqual(variants.count, 4)
    }

    func testQueryVariantsDedupesAndIgnoresWhitespace() {
        XCTAssertEqual(CatalogSearch.queryVariants(from: "   "), [])
        XCTAssertEqual(CatalogSearch.queryVariants(from: "drake"), ["drake"])
    }

    func testStripExplicitMarkers() {
        XCTAssertEqual(CatalogSearch.stripExplicitMarkers("WAP (Explicit)"), "WAP")
        XCTAssertEqual(CatalogSearch.stripExplicitMarkers("WAP [Clean]"), "WAP")
        XCTAssertEqual(CatalogSearch.stripExplicitMarkers("Song - Explicit"), "Song")
    }

    // MARK: Parsing

    func testParseSongAndAlbumAndArtist() {
        let song = CatalogSearch.parseHit([
            "wrapperType": "track",
            "kind": "song",
            "trackId": 1440882165,
            "trackName": "HUMBLE.",
            "artistName": "Kendrick Lamar",
            "artistId": 368183298,
            "collectionName": "DAMN.",
            "trackTimeMillis": 177000,
            "trackExplicitness": "cleaned",
            "artworkUrl100": "https://example.com/100x100bb.jpg",
            "releaseDate": "2017-03-30T12:00:00Z",
        ])
        XCTAssertEqual(song?.kind, .song)
        XCTAssertEqual(song?.explicitness, .cleaned)
        XCTAssertEqual(song?.artistID, 368183298)
        XCTAssertEqual(song?.durationMilliseconds, 177000)

        let album = CatalogSearch.parseHit([
            "wrapperType": "collection",
            "collectionId": 1440881047,
            "collectionName": "DAMN.",
            "artistName": "Kendrick Lamar",
            "artistId": 368183298,
            "trackCount": 14,
            "collectionExplicitness": "explicit",
            "releaseDate": "2017-04-14T07:00:00Z",
        ])
        XCTAssertEqual(album?.kind, .album)
        XCTAssertEqual(album?.explicitness, .explicit)
        XCTAssertEqual(album?.trackCount, 14)

        let artist = CatalogSearch.parseHit([
            "wrapperType": "artist",
            "artistType": "Artist",
            "artistId": 368183298,
            "artistName": "Kendrick Lamar",
        ])
        XCTAssertEqual(artist?.kind, .artist)
        XCTAssertEqual(artist?.id, 368183298)
    }

    func testParseResponseFixtureMergesResultsArray() {
        let data = fixtureSearchJSON.data(using: .utf8)!
        let hits = CatalogSearch.parseResponse(data)
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits.map(\.explicitness), [.cleaned, .notExplicit, .explicit])
    }

    // MARK: Ranking / explicit upgrade

    func testExplicitVariantReplacesCleanedSibling() {
        let cleaned = CatalogSearch.Hit(
            id: 1440882165, kind: .song, title: "HUMBLE.", artist: "Kendrick Lamar",
            album: "DAMN.", artistID: 368183298, explicitness: .cleaned
        )
        let explicit = CatalogSearch.Hit(
            id: 1440881684, kind: .song, title: "HUMBLE.", artist: "Kendrick Lamar",
            album: "DAMN.", artistID: 368183298, explicitness: .explicit
        )
        let karaoke = CatalogSearch.Hit(
            id: 99, kind: .song, title: "HUMBLE. (Karaoke Version)",
            artist: "Karaoke Hit Machine", explicitness: .notExplicit
        )

        let ranked = CatalogSearch.rankSongs(
            query: "HUMBLE. Kendrick",
            batches: [[cleaned, karaoke], [explicit]],
            limit: 10
        )

        XCTAssertEqual(ranked.first?.id, 1440881684)
        XCTAssertEqual(ranked.first?.explicitness, .explicit)
        // Cleaned sibling must not also appear.
        XCTAssertFalse(ranked.contains { $0.id == 1440882165 })
        // Karaoke is demoted below the real hit.
        if let karaokeIndex = ranked.firstIndex(where: { $0.id == 99 }),
           let realIndex = ranked.firstIndex(where: { $0.id == 1440881684 }) {
            XCTAssertGreaterThan(karaokeIndex, realIndex)
        }
    }

    func testIdentityKeyIgnoresFeatAndExplicitMarkers() {
        let a = CatalogSearch.identityKey(
            title: "WAP (feat. Megan Thee Stallion) (Clean)",
            artist: "Cardi B"
        )
        let b = CatalogSearch.identityKey(
            title: "WAP (feat. Megan Thee Stallion)",
            artist: "Cardi B, Megan Thee Stallion"
        )
        XCTAssertEqual(a, b)
    }

    func testArtistIDsForUpgradePreservesOrderAndDedupes() {
        let hits = [
            CatalogSearch.Hit(id: 1, kind: .song, title: "A", artist: "X", artistID: 10),
            CatalogSearch.Hit(id: 2, kind: .song, title: "B", artist: "Y", artistID: 20),
            CatalogSearch.Hit(id: 3, kind: .song, title: "C", artist: "X", artistID: 10),
            CatalogSearch.Hit(id: 4, kind: .song, title: "D", artist: "Z", artistID: 30),
        ]
        XCTAssertEqual(CatalogSearch.artistIDsForUpgrade(from: hits, limit: 2), [10, 20])
    }

    func testPreferredAlbumIDPicksExplicitCollection() {
        let cleaned = CatalogSearch.Hit(
            id: 1440881722, kind: .album, title: "DAMN.", artist: "Kendrick Lamar",
            explicitness: .cleaned
        )
        let explicit = CatalogSearch.Hit(
            id: 1440881047, kind: .album, title: "DAMN.", artist: "Kendrick Lamar",
            explicitness: .explicit
        )
        XCTAssertEqual(
            CatalogSearch.preferredAlbumID(among: [cleaned, explicit], matching: cleaned),
            1440881047
        )
    }

    func testSearchQueryItemsAlwaysAskForExplicit() {
        let items = CatalogSearch.searchQueryItems(term: "WAP", entity: "song", limit: 25)
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        XCTAssertEqual(dict["explicit"], "Yes")
        XCTAssertEqual(dict["entity"], "song")
        XCTAssertEqual(dict["media"], "music")
    }

    func testNoiseTokensDemoteKaraokeOverRealMatch() {
        let query = CatalogSearch.normalize("fucking problems asap rocky")
        let tokens = CatalogSearch.tokenSet(query)
        let real = CatalogSearch.Hit(
            id: 1, kind: .song, title: "F**kin' Problems",
            artist: "A$AP Rocky", explicitness: .cleaned
        )
        let karaoke = CatalogSearch.Hit(
            id: 2, kind: .song,
            title: "F****n' Problems (In the Style of A$AP Rocky) [Karaoke Version]",
            artist: "Karaoke Hit Machine", explicitness: .notExplicit
        )
        let realScore = CatalogSearch.relevanceScore(hit: real, normalizedQuery: query, tokens: tokens)
        let karaokeScore = CatalogSearch.relevanceScore(hit: karaoke, normalizedQuery: query, tokens: tokens)
        XCTAssertGreaterThan(realScore, karaokeScore)
    }

    // MARK: Fixtures

    /// Minimal Search-shaped payload: cleaned hit, unrelated notExplicit, and an explicit
    /// sibling that only appears on artist lookup in production.
    private let fixtureSearchJSON = """
    {
      "resultCount": 3,
      "results": [
        {
          "wrapperType": "track",
          "kind": "song",
          "trackId": 1440882165,
          "artistId": 368183298,
          "trackName": "HUMBLE.",
          "artistName": "Kendrick Lamar",
          "collectionName": "DAMN.",
          "trackExplicitness": "cleaned",
          "trackTimeMillis": 177000
        },
        {
          "wrapperType": "track",
          "kind": "song",
          "trackId": 1828811601,
          "artistId": 314333781,
          "trackName": "HUMBLE.",
          "artistName": "Twinkle Twinkle Little Rock Star",
          "collectionName": "Lullaby Versions of Kendrick Lamar",
          "trackExplicitness": "notExplicit",
          "trackTimeMillis": 180000
        },
        {
          "wrapperType": "track",
          "kind": "song",
          "trackId": 1440881684,
          "artistId": 368183298,
          "trackName": "HUMBLE.",
          "artistName": "Kendrick Lamar",
          "collectionName": "DAMN.",
          "trackExplicitness": "explicit",
          "trackTimeMillis": 177000
        }
      ]
    }
    """
}
