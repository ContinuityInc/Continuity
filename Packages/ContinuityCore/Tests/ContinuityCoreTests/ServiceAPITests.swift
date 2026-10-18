import XCTest
@testable import ContinuityCore

final class ServiceAPITests: XCTestCase {

    // MARK: Spotify

    func testSpotifyPlaylistsPage() {
        let json = """
        {"items":[
          {"id":"37i9dQZF1DXcBWIGoYBM5M","name":"Today's Top Hits","type":"playlist","owner":{"display_name":"Spotify"},"tracks":{"total":50}},
          null,
          {"id":"abc","name":"Mine","type":"playlist","owner":{"display_name":""},"tracks":{"total":3}}
        ],"next":"https://api.spotify.com/v1/me/playlists?offset=50&limit=50"}
        """
        let page = SpotifyAPI.parsePlaylistsPage(Data(json.utf8))
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0], ServicePlaylistSummary(service: .spotify, sourceID: "37i9dQZF1DXcBWIGoYBM5M", kind: .playlist, name: "Today's Top Hits", ownerName: "Spotify", trackCount: 50))
        XCTAssertNil(page.items[1].ownerName)
        XCTAssertEqual(page.nextPageURL?.absoluteString, "https://api.spotify.com/v1/me/playlists?offset=50&limit=50")
        XCTAssertTrue(page.hasMore)
    }

    func testSpotifyTracksPageHandlesWrappedAndBareItems() {
        let wrapped = """
        {"items":[
          {"track":{"name":"Die With A Smile","type":"track","duration_ms":251668,"artists":[{"name":"Lady Gaga"},{"name":"Bruno Mars"}]}},
          {"track":{"name":"Some Episode","type":"episode","duration_ms":1}},
          {"track":{"name":"Local","type":"track","is_local":true}},
          {"track":null}
        ],"next":null}
        """
        let page = SpotifyAPI.parseTracksPage(Data(wrapped.utf8))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].title, "Die With A Smile")
        XCTAssertEqual(page.items[0].artist, "Lady Gaga, Bruno Mars")
        XCTAssertEqual(page.items[0].durationSeconds, 252)
        XCTAssertEqual(page.items[0].youtubeSearchQuery, "Die With A Smile Lady Gaga, Bruno Mars")
        XCTAssertNil(page.items[0].youtubeVideoID)
        XCTAssertFalse(page.hasMore)

        let album = """
        {"items":[{"name":"Track One","type":"track","duration_ms":60000,"artists":[{"name":"Band"}]}],"next":null}
        """
        XCTAssertEqual(SpotifyAPI.parseTracksPage(Data(album.utf8)).items.map(\.title), ["Track One"])
    }

    func testSpotifyAlbumSummaryAndRequestURLs() {
        let json = """
        {"id":"4aawyAB9vmqN3uQ7FjRGTy","name":"Global Warming","type":"album","album_type":"album","total_tracks":18,"artists":[{"name":"Pitbull"}]}
        """
        let summary = SpotifyAPI.parsePlaylistSummary(Data(json.utf8))
        XCTAssertEqual(summary?.kind, .album)
        XCTAssertEqual(summary?.ownerName, "Pitbull")
        XCTAssertEqual(summary?.trackCount, 18)

        XCTAssertEqual(SpotifyAPI.myPlaylistsURL.absoluteString, "https://api.spotify.com/v1/me/playlists?limit=50")
        XCTAssertEqual(SpotifyAPI.albumTracksURL(id: "x").absoluteString, "https://api.spotify.com/v1/albums/x/tracks?limit=50")
        XCTAssertTrue(SpotifyAPI.playlistTracksURL(id: "p").absoluteString.hasPrefix("https://api.spotify.com/v1/playlists/p/tracks?"))
    }

    // MARK: YouTube Data API

    func testYouTubePlaylistsAndItemsPages() {
        let playlists = """
        {"nextPageToken":"CAUQAA","items":[
          {"id":"PL123","snippet":{"title":"Road Trip","channelTitle":"Me"},"contentDetails":{"itemCount":12}},
          {"id":"LL","snippet":{"title":"Liked videos"},"contentDetails":{"itemCount":400}}
        ]}
        """
        let page = YouTubeDataAPI.parsePlaylistsPage(Data(playlists.utf8))
        XCTAssertEqual(page.nextPageToken, "CAUQAA")
        XCTAssertEqual(page.items[0], ServicePlaylistSummary(service: .youtube, sourceID: "PL123", kind: .playlist, name: "Road Trip", ownerName: "Me", trackCount: 12))
        XCTAssertEqual(page.items[1].kind, .likes)

        let items = """
        {"items":[
          {"snippet":{"title":"Song A","videoOwnerChannelTitle":"Artist A","resourceId":{"videoId":"dQw4w9WgXcQ"}},"contentDetails":{"videoId":"dQw4w9WgXcQ"}},
          {"snippet":{"title":"Deleted video"},"contentDetails":{"videoId":"aaaaaaaaaaa"}},
          {"snippet":{"title":"Dup"},"contentDetails":{"videoId":"dQw4w9WgXcQ"}},
          {"snippet":{"title":"Bad id"},"contentDetails":{"videoId":"short"}}
        ]}
        """
        let tracks = YouTubeDataAPI.parsePlaylistItemsPage(Data(items.utf8))
        XCTAssertEqual(tracks.items.count, 1)
        XCTAssertEqual(tracks.items[0].youtubeVideoID, "dQw4w9WgXcQ")
        XCTAssertEqual(tracks.items[0].title, "Song A")
        XCTAssertEqual(tracks.items[0].artist, "Artist A")
        XCTAssertEqual(tracks.items[0].youtubePlaylistItem, YouTubePlaylistItem(videoID: "dQw4w9WgXcQ", title: "Song A", author: "Artist A"))
        XCTAssertFalse(tracks.hasMore)

        let url = YouTubeDataAPI.playlistItemsURL(playlistID: "PL123", pageToken: "T").absoluteString
        XCTAssertTrue(url.contains("playlistId=PL123") && url.contains("pageToken=T") && url.contains("maxResults=50"))
    }

    func testISO8601Durations() {
        XCTAssertEqual(YouTubeDataAPI.parseISO8601Duration("PT3M33S"), 213)
        XCTAssertEqual(YouTubeDataAPI.parseISO8601Duration("PT1H2M3S"), 3723)
        XCTAssertEqual(YouTubeDataAPI.parseISO8601Duration("PT45S"), 45)
        XCTAssertEqual(YouTubeDataAPI.parseISO8601Duration("P0D"), 0)
        XCTAssertNil(YouTubeDataAPI.parseISO8601Duration("3:33"))

        let videos = """
        {"items":[{"id":"dQw4w9WgXcQ","contentDetails":{"duration":"PT3M33S"}}]}
        """
        XCTAssertEqual(YouTubeDataAPI.parseVideoDurations(Data(videos.utf8)), ["dQw4w9WgXcQ": 213])
    }

    // MARK: SoundCloud API

    func testSoundCloudPlaylistsEnvelopeAndBareArray() {
        let envelope = """
        {"collection":[
          {"urn":"soundcloud:playlists:1","id":1,"title":"Mix","track_count":7,"user":{"username":"dj"},"set_type":"","is_album":false,"permalink_url":"https://soundcloud.com/dj/sets/mix"},
          {"id":2,"title":"Album","track_count":10,"user":{"username":"band"},"set_type":"album"},
          {"urn":"soundcloud:playlists:4","title":"No permalink","permalink_url":"not a url"},
          {"id":3,"title":""}
        ],"next_href":"https://api.soundcloud.com/me/playlists?cursor=abc"}
        """
        let page = SoundCloudAPI.parsePlaylistsPage(Data(envelope.utf8))
        XCTAssertEqual(page.items.count, 3)
        // Permalink path is the identity when present — it's what a pasted link yields too.
        XCTAssertEqual(page.items[0], ServicePlaylistSummary(service: .soundcloud, sourceID: "dj/sets/mix", kind: .playlist, name: "Mix", ownerName: "dj", trackCount: 7))
        XCTAssertEqual(page.items[1].sourceID, "soundcloud:playlists:2")   // synthesised urn
        XCTAssertEqual(page.items[1].kind, .album)
        XCTAssertEqual(page.items[2].sourceID, "soundcloud:playlists:4")
        XCTAssertTrue(SoundCloudAPI.isURN("soundcloud:playlists:4"))
        XCTAssertFalse(SoundCloudAPI.isURN("dj/sets/mix"))
        XCTAssertEqual(page.nextPageURL?.absoluteString, "https://api.soundcloud.com/me/playlists?cursor=abc")

        let bare = """
        [{"id":9,"title":"Bare","track_count":1}]
        """
        let barePage = SoundCloudAPI.parsePlaylistsPage(Data(bare.utf8))
        XCTAssertEqual(barePage.items.map(\.name), ["Bare"])
        XCTAssertFalse(barePage.hasMore)
    }

    func testSoundCloudTracksAndResolve() {
        let tracks = """
        {"collection":[{"urn":"soundcloud:tracks:5","title":"Bicep - Glue","duration":240000,"user":{"username":"Ninja Tune"},"kind":"track"}]}
        """
        let page = SoundCloudAPI.parseTracksPage(Data(tracks.utf8))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].artist, "Ninja Tune")
        XCTAssertEqual(page.items[0].durationSeconds, 240)
        XCTAssertEqual(page.items[0].youtubeSearchQuery, "Bicep - Glue")

        let resolvedSet = """
        {"kind":"playlist","urn":"soundcloud:playlists:77","title":"Resolved","user":{"username":"x"},"tracks":[{"id":1,"kind":"track","title":"One","duration":1000}]}
        """
        guard case .playlist(let contents)? = SoundCloudAPI.parseResolved(Data(resolvedSet.utf8)) else {
            return XCTFail("expected playlist")
        }
        XCTAssertEqual(contents.summary.sourceID, "soundcloud:playlists:77")
        XCTAssertEqual(contents.summary.trackCount, 1)
        XCTAssertEqual(contents.tracks.map(\.title), ["One"])

        let resolvedTrack = """
        {"kind":"track","id":8,"title":"Solo","user":{"username":"y"}}
        """
        guard case .track(let track)? = SoundCloudAPI.parseResolved(Data(resolvedTrack.utf8)) else {
            return XCTFail("expected track")
        }
        XCTAssertEqual(track.title, "Solo")
        XCTAssertNil(SoundCloudAPI.parseResolved(Data(#"{"kind":"user"}"#.utf8)))

        let resolveURL = SoundCloudAPI.resolveURL(permalink: URL(string: "https://soundcloud.com/a/sets/b")!).absoluteString
        XCTAssertEqual(resolveURL, "https://api.soundcloud.com/resolve?url=https://soundcloud.com/a/sets/b")
    }

    // MARK: Shared types

    func testServiceTrackFromYouTubeItemAndDefaults() {
        let bare = ServiceTrack(YouTubePlaylistItem(videoID: "dQw4w9WgXcQ"))
        XCTAssertEqual(bare.title, "YouTube Video (dQw4w9)")
        XCTAssertEqual(bare.youtubeSearchQuery, "dQw4w9WgXcQ")

        let meta = ServiceTrack(title: "Song", artist: "Artist")
        XCTAssertEqual(meta.youtubeSearchQuery, "Song Artist")
        XCTAssertNil(meta.youtubePlaylistItem)

        let summary = ServicePlaylistSummary(service: .spotify, sourceID: "x", kind: .likes, name: "Liked Songs")
        XCTAssertEqual(summary.id, "spotify:likes:x")
    }
}
