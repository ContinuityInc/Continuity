import Domain
import Foundation
import SwiftData

extension PreparationQueue {
    /// Adds one catalog search hit to the shared "From Search" playlist and enqueues it.
    /// Like Spotify imports, the track carries only a `searchQuery` — the ingest pipeline
    /// resolves it to real YouTube audio during preparation.
    @discardableResult
    public func addCatalogSong(_ song: CatalogSong, in context: ModelContext) -> Track {
        let playlist = findOrCreateSearchPlaylist(in: context)
        let track = Track(
            title: song.title,
            artist: song.artist,
            durationSeconds: song.durationSeconds,
            artworkSymbol: playlist.artworkSymbol,
            gradientSeed: playlist.gradientSeed * 100 + playlist.tracks.count,
            sortIndex: playlist.tracks.count,
            prepState: .pending,
            searchQuery: song.youtubeSearchQuery
        )
        playlist.tracks.append(track)
        context.insert(track)
        playlist.touch()    // membership changed → resort the library
        enqueue(track, in: context)
        try? context.save()
        return track
    }

    /// Imports a catalog album as its own playlist: looks up the album's tracklist, creates
    /// the `Playlist`, and enqueues one search-query `Track` per song (the same re-sourcing
    /// path Spotify imports use). Throws if the tracklist can't be fetched or is empty.
    @discardableResult
    public func importCatalogAlbum(_ album: CatalogAlbum, in context: ModelContext) async throws -> Playlist {
        let songs = try await MusicCatalog().albumSongs(albumID: album.id)
        guard !songs.isEmpty else { throw IngestError.sourceUnavailable }

        let seed = album.id % 90 + 10
        let playlist = Playlist(
            title: album.title,
            subtitle: "\(album.artist) · \(songs.count) tracks",
            artworkSymbol: "opticaldisc",
            gradientSeed: seed
        )
        context.insert(playlist)

        for (index, song) in songs.enumerated() {
            let track = Track(
                title: song.title,
                artist: song.artist,
                durationSeconds: song.durationSeconds,
                artworkSymbol: playlist.artworkSymbol,
                gradientSeed: seed * 100 + index,
                sortIndex: index,
                prepState: .pending,
                searchQuery: song.youtubeSearchQuery
            )
            playlist.tracks.append(track)
            context.insert(track)
            enqueue(track, in: context)
        }
        playlist.touch()    // creation + initial tracks count as a content change
        try? context.save()
        return playlist
    }

    /// Returns the shared "From Search" playlist, creating and inserting it if missing.
    private func findOrCreateSearchPlaylist(in context: ModelContext) -> Playlist {
        let title = "From Search"
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.title == title })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let playlist = Playlist(
            title: title,
            subtitle: "Added from catalog search",
            artworkSymbol: "magnifyingglass",
            gradientSeed: 37
        )
        context.insert(playlist)
        return playlist
    }
}
