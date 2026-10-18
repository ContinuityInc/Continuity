import ContinuityCore
import Domain
import Foundation
import SwiftData
import os

/// What a pasted link produced: a whole collection (its own playlist) or one song (added to the
/// service's shared "From …" playlist).
public enum ImportOutcome: Sendable {
    case playlist(Playlist)
    case track(Track)
}

extension PreparationQueue {

    // MARK: - Connected accounts (the signed-in path)

    /// The connected account's playlists, Liked collection first — for the import picker.
    public func connectedPlaylists(for service: MusicService) async throws -> [ServicePlaylistSummary] {
        guard let library = connectedLibraries[service] else { throw IngestError.notSignedIn(service) }
        return try await withServiceToken(service) { try await library.playlists(token: $0) }
    }

    /// Imports one collection picked from a connected account (or re-syncs it if it's already
    /// in the library).
    @discardableResult
    public func importConnectedPlaylist(_ summary: ServicePlaylistSummary, in context: ModelContext) async throws -> Playlist {
        guard let library = connectedLibraries[summary.service] else { throw IngestError.notSignedIn(summary.service) }
        let contents = try await withServiceToken(summary.service) { try await library.contents(of: summary, token: $0) }
        guard !contents.isEmpty else { throw IngestError.sourceUnavailable }
        return await importServicePlaylist(contents, in: context)
    }

    /// Runs an API call with a valid bearer token. A 401 earns one forced refresh + retry; a
    /// second rejection disconnects the account and surfaces `.notSignedIn`.
    func withServiceToken<T>(_ service: MusicService, _ body: (String) async throws -> T) async throws -> T {
        let token = try await serviceAuth.accessToken(for: service)
        do {
            return try await body(token)
        } catch IngestError.unauthorized {
            let fresh = try await serviceAuth.accessToken(for: service, forceRefresh: true)
            do {
                return try await body(fresh)
            } catch IngestError.unauthorized {
                serviceAuth.invalidate(service)
                throw IngestError.notSignedIn(service)
            }
        }
    }

    /// Resolves a pasted link through the connected account when there is one. Returns nil when
    /// the service isn't connected (the caller then uses the anonymous scrape) — but *propagates*
    /// an API failure for a connected account rather than silently degrading to the scrape, since
    /// the user chose to sign in for exactly the items the scrape can't see.
    func resolveViaConnectedAccount(_ service: MusicService, raw: String) async throws -> ResolvedServiceLink? {
        guard serviceAuth.isConnected(service), let library = connectedLibraries[service] else { return nil }
        return try await withServiceToken(service) { try await library.resolveLink(raw, token: $0) }
    }

    // MARK: - SoundCloud links

    /// Imports a SoundCloud link: a set becomes its own playlist; a single track lands in
    /// "From SoundCloud". Uses the connected account's API when signed in, else the page scrape.
    /// **Metadata only** either way — audio is re-sourced from YouTube.
    @discardableResult
    public func importSoundCloudLink(_ link: SoundCloudLink, sourceURL: String, in context: ModelContext) async throws -> ImportOutcome {
        let resolved: ResolvedServiceLink
        if let viaAPI = try await resolveViaConnectedAccount(.soundcloud, raw: sourceURL) {
            resolved = viaAPI
        } else {
            resolved = try await soundcloudResolver.resolve(link)
        }
        switch resolved {
        case .playlist(let contents):
            return .playlist(await importServicePlaylist(contents, in: context))
        case .track(let track):
            return .track(addServiceTrack(track, from: .soundcloud, sourceURL: sourceURL, in: context))
        }
    }

    // MARK: - Spotify single tracks

    /// Adds one Spotify track to "From Spotify" (API when signed in, embed page otherwise).
    @discardableResult
    public func importSpotifyTrack(_ link: SpotifyLink, sourceURL: String, in context: ModelContext) async throws -> Track {
        guard link.kind == .track else { throw IngestError.invalidURL }
        if case .track(let track)? = try await resolveViaConnectedAccount(.spotify, raw: sourceURL) {
            return addServiceTrack(track, from: .spotify, sourceURL: sourceURL, in: context)
        }
        let spotifyTrack = try await spotifyResolver.resolveTrack(link)
        return addServiceTrack(ServiceTrack(spotifyTrack), from: .spotify, sourceURL: sourceURL, in: context)
    }

    // MARK: - Shared creation

    /// Creates (or re-syncs) the library playlist mirroring a resolved remote collection and
    /// enqueues one `Track` per song. YouTube items carry a video id and ingest directly;
    /// everything else carries a `searchQuery` the pipeline resolves to YouTube audio.
    @discardableResult
    func importServicePlaylist(_ contents: ServicePlaylistContents, in context: ModelContext) async -> Playlist {
        let summary = contents.summary
        let kind = Self.playlistSource(for: summary)

        // Re-importing something already mirrored updates it instead of duplicating it.
        if let existing = existingPlaylist(kind: kind, sourceID: summary.sourceID, in: context) {
            await syncPlaylist(existing, in: context)
            return existing
        }

        let seed = summary.sourceID.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 90 + 10
        let playlist = Playlist(
            title: summary.name.isEmpty ? "\(summary.service.displayName) \(summary.kind == .album ? "Album" : "Playlist")" : summary.name,
            subtitle: Self.subtitle(for: summary.service, count: contents.tracks.count),
            artworkSymbol: summary.kind == .likes ? "heart.fill" : "music.note.list",
            gradientSeed: seed
        )
        playlist.sourceKind = kind
        playlist.sourceID = summary.sourceID
        playlist.lastSyncedAt = Date()
        context.insert(playlist)

        for (index, remote) in contents.tracks.enumerated() {
            let track = Self.makeTrack(remote, playlist: playlist, seed: seed, index: index)
            playlist.tracks.append(track)
            context.insert(track)
            enqueue(track, in: context, saving: false)
        }
        playlist.touch()    // creation + initial tracks count as a content change
        try? context.save()
        return playlist
    }

    /// Adds one song to the service's shared "From Spotify" / "From SoundCloud" playlist.
    func addServiceTrack(_ remote: ServiceTrack, from service: MusicService, sourceURL: String, in context: ModelContext) -> Track {
        let playlist = findOrCreateSinglesPlaylist(for: service, in: context)
        let track = Self.makeTrack(remote, playlist: playlist, seed: playlist.gradientSeed, index: playlist.tracks.count)
        track.sourceURLString = sourceURL
        playlist.tracks.append(track)
        context.insert(track)
        playlist.touch()    // membership changed → resort the library
        enqueue(track, in: context)
        try? context.save()
        return track
    }

    static func makeTrack(_ remote: ServiceTrack, playlist: Playlist, seed: Int, index: Int) -> Track {
        Track(
            title: remote.title,
            artist: remote.artist ?? (remote.youtubeVideoID != nil ? "YouTube" : "Unknown Artist"),
            durationSeconds: Double(remote.durationSeconds ?? 0),
            artworkSymbol: playlist.artworkSymbol,
            gradientSeed: seed * 100 + index,
            sortIndex: index,
            prepState: .pending,
            youtubeVideoID: remote.youtubeVideoID,
            // Video-id tracks never search; metadata tracks must, so only one of the two is set.
            searchQuery: remote.youtubeVideoID == nil ? remote.youtubeSearchQuery : nil,
            sourceURLString: remote.youtubeVideoID.map { "https://www.youtube.com/watch?v=\($0)" }
        )
    }

    /// The already-imported playlist mirroring `(kind, sourceID)`, if any. Filtered in memory:
    /// `sourceKind` wraps a private raw column, so it isn't expressible in a `#Predicate`.
    func existingPlaylist(kind: PlaylistSource, sourceID: String, in context: ModelContext) -> Playlist? {
        try? context.fetch(FetchDescriptor<Playlist>()).first { $0.sourceKind == kind && $0.sourceID == sourceID }
    }

    private func findOrCreateSinglesPlaylist(for service: MusicService, in context: ModelContext) -> Playlist {
        let title = "From \(service.displayName)"
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.title == title })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first { return existing }
        let playlist = Playlist(
            title: title,
            subtitle: "Added from \(service.displayName)",
            artworkSymbol: "arrow.down.circle.fill",
            gradientSeed: service == .spotify ? 29 : 71
        )
        context.insert(playlist)
        return playlist
    }

    // MARK: - Source mapping

    static func playlistSource(for summary: ServicePlaylistSummary) -> PlaylistSource {
        switch (summary.service, summary.kind) {
        case (.spotify, .likes): return .spotifyLiked
        case (.spotify, .album): return .spotifyAlbum
        case (.spotify, .playlist): return .spotifyPlaylist
        case (.youtube, _): return .youtube
        case (.soundcloud, .likes): return .soundcloudLikes
        case (.soundcloud, _): return .soundcloudPlaylist
        }
    }

    /// The remote identity of a source-backed playlist, for re-fetching through the API.
    static func summary(kind: PlaylistSource, sourceID: String) -> ServicePlaylistSummary? {
        switch kind {
        case .youtube:
            return ServicePlaylistSummary(service: .youtube, sourceID: sourceID, kind: sourceID == YouTubeDataAPI.likedVideosPlaylistID ? .likes : .playlist, name: "")
        case .spotifyPlaylist: return ServicePlaylistSummary(service: .spotify, sourceID: sourceID, kind: .playlist, name: "")
        case .spotifyAlbum: return ServicePlaylistSummary(service: .spotify, sourceID: sourceID, kind: .album, name: "")
        case .spotifyLiked: return ServicePlaylistSummary(service: .spotify, sourceID: SpotifyAPI.likedSongsID, kind: .likes, name: "")
        case .soundcloudPlaylist: return ServicePlaylistSummary(service: .soundcloud, sourceID: sourceID, kind: .playlist, name: "")
        case .soundcloudLikes: return ServicePlaylistSummary(service: .soundcloud, sourceID: SoundCloudAPI.likesID, kind: .likes, name: "")
        case .appleMusic: return nil
        }
    }

    static func subtitle(for service: MusicService, count: Int) -> String {
        "From \(service.displayName) · \(count) tracks"
    }

    // MARK: - Remote fetch (import + sync share this)

    /// Fetches the current remote tracklist for a source-backed playlist. Signed-in accounts go
    /// through the official API (full length, private items); otherwise the anonymous scrape.
    /// Account-only sources (`Liked …`) throw `.notSignedIn` without an account.
    func fetchRemoteContents(kind: PlaylistSource, sourceID: String, fallbackName: String? = nil) async throws -> ServicePlaylistContents {
        guard let summary = Self.summary(kind: kind, sourceID: sourceID) else { throw IngestError.sourceUnavailable }
        let service = summary.service

        if serviceAuth.isConnected(service), let library = connectedLibraries[service] {
            do {
                var contents = try await withServiceToken(service) { try await library.contents(of: summary, token: $0) }
                if contents.summary.name.isEmpty, let fallbackName { contents.summary.name = fallbackName }
                return contents
            } catch let error as IngestError where !kind.requiresSignIn && !error.isRetryable {
                // The API said no to a public item (quota, scope, a list the account can't
                // read) — the anonymous path may still work. Account-only sources can't fall back.
                Logger.sync.notice("\(service.rawValue, privacy: .public) API failed for \(sourceID, privacy: .public), falling back to scrape: \(String(describing: error), privacy: .public)")
            }
        } else if kind.requiresSignIn {
            throw IngestError.notSignedIn(service)
        }

        switch kind {
        case .youtube:
            // YouTube's page scrape can't see Liked videos (private) — only the API can.
            guard sourceID != YouTubeDataAPI.likedVideosPlaylistID else { throw IngestError.notSignedIn(.youtube) }
            let resolved = try await playlistResolver.resolvePlaylist(playlistID: sourceID)
            var named = summary
            named.name = resolved.title?.isEmpty == false ? resolved.title! : (fallbackName ?? "YouTube Playlist")
            named.trackCount = resolved.items.count
            return ServicePlaylistContents(summary: named, tracks: resolved.items.map(ServiceTrack.init))
        case .spotifyPlaylist, .spotifyAlbum:
            let link = SpotifyLink(kind: kind == .spotifyAlbum ? .album : .playlist, id: sourceID)
            let resolved = try await spotifyResolver.resolvePlaylist(link)
            var named = summary
            named.name = resolved.name?.isEmpty == false ? resolved.name! : (fallbackName ?? "Spotify \(link.kind.rawValue.capitalized)")
            named.trackCount = resolved.tracks.count
            return ServicePlaylistContents(summary: named, tracks: resolved.tracks.map(ServiceTrack.init))
        case .soundcloudPlaylist:
            // A URN identity came from the API and has no public page.
            guard !SoundCloudAPI.isURN(sourceID) else { throw IngestError.notSignedIn(.soundcloud) }
            guard case .playlist(let contents) = try await soundcloudResolver.resolve(SoundCloudLink(kind: .playlist, path: sourceID)) else {
                throw IngestError.sourceUnavailable
            }
            return contents
        case .spotifyLiked, .soundcloudLikes:
            throw IngestError.notSignedIn(service)
        case .appleMusic:
            throw IngestError.sourceUnavailable
        }
    }
}
