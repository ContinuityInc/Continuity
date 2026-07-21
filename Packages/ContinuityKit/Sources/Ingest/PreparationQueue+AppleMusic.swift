import ContinuityCore
import Domain
import Foundation
import SwiftData

extension PreparationQueue {

    /// Current Apple Music library permission, without prompting.
    public var appleMusicAccess: AppleMusicAccess { appleMusicLibrary.access }

    /// Prompts for Apple Music library access (first call) and returns the settled status.
    public func requestAppleMusicAccess() async -> AppleMusicAccess {
        await appleMusicLibrary.requestAccess()
    }

    /// Every non-empty playlist in the user's Apple Music library, for the import picker.
    /// Throws `IngestError.appleMusicAccessDenied` if permission was never granted.
    public func appleMusicPlaylists() async throws -> [AppleMusicPlaylistContents] {
        try await appleMusicLibrary.playlists()
    }

    /// Imports one Apple Music library playlist: creates a matching library `Playlist` and
    /// enqueues one `Track` per song. **Metadata only** — Apple Music catalog audio is
    /// DRM-protected and can't feed our engine, so each track carries a `searchQuery` and the
    /// ingest pipeline re-sources the audio from YouTube (identical to the Spotify path).
    ///
    /// Re-importing the same playlist updates the existing one instead of creating a duplicate,
    /// since the persistent ID is stable across imports.
    @discardableResult
    public func importAppleMusicPlaylist(
        _ contents: AppleMusicPlaylistContents,
        in context: ModelContext
    ) async throws -> Playlist {
        guard !contents.isEmpty else { throw IngestError.sourceUnavailable }

        if let existing = existingAppleMusicPlaylist(persistentID: contents.persistentID, in: context) {
            await syncPlaylist(existing, in: context)
            return existing
        }

        let title = contents.name?.isEmpty == false ? contents.name! : "Apple Music Playlist"
        // Deterministic gradient seed from the persistent ID so the card colour is stable.
        let seed = contents.persistentID.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 90 + 10

        let playlist = Playlist(
            title: title,
            subtitle: Self.appleMusicSubtitle(count: contents.tracks.count),
            artworkSymbol: "music.note.list",
            gradientSeed: seed
        )
        playlist.sourceKind = .appleMusic
        playlist.sourceID = contents.persistentID
        playlist.lastSyncedAt = Date()
        context.insert(playlist)

        for (index, song) in contents.tracks.enumerated() {
            let track = Track(
                title: song.title,
                artist: song.artist ?? "Unknown Artist",
                durationSeconds: Double(song.durationSeconds ?? 0),
                artworkSymbol: playlist.artworkSymbol,
                gradientSeed: seed * 100 + index,
                sortIndex: index,
                prepState: .pending,
                // No video ID yet — the pipeline finds the audio on YouTube from this query.
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

    /// The already-imported playlist mirroring `persistentID`, if any.
    func existingAppleMusicPlaylist(persistentID: String, in context: ModelContext) -> Playlist? {
        // Filter in memory: `sourceKind` is a computed wrapper over a private raw column, so it
        // isn't expressible in a SwiftData #Predicate.
        try? context.fetch(FetchDescriptor<Playlist>()).first {
            $0.sourceKind == .appleMusic && $0.sourceID == persistentID
        }
    }

    static func appleMusicSubtitle(count: Int) -> String {
        "From Apple Music · \(count) tracks"
    }
}
