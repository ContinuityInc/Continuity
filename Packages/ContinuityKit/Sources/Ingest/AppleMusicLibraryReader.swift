import ContinuityCore
import Foundation
import MediaPlayer

/// Reads the user's Apple Music / iTunes library through **MediaPlayer**, returning plain
/// metadata (title, artist, duration) — never audio.
///
/// Why MediaPlayer and not MusicKit: everything we need is title + artist for the YouTube
/// re-source, and `MPMediaQuery` needs only `NSAppleMusicUsageDescription`. MusicKit would
/// additionally require the MusicKit App Service enabled on the App ID, which changes the
/// provisioning profile — and the TestFlight pipeline signs in the cloud, where a capability
/// mismatch fails the build with "No profiles for 'com.sanylax.continuity'". If richer catalog
/// metadata is ever wanted, swap in a MusicKit implementation behind `AppleMusicLibraryReading`.
///
/// Stateless, so it's trivially `Sendable`; the library queries run off the main actor.
struct AppleMusicLibraryReader: AppleMusicLibraryReading {

    var access: AppleMusicAccess {
        Self.map(MPMediaLibrary.authorizationStatus())
    }

    func requestAccess() async -> AppleMusicAccess {
        // `requestAuthorization` invokes its handler immediately once the status has settled,
        // so this is also the cheap re-check path.
        let status = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        return Self.map(status)
    }

    func playlists() async throws -> [AppleMusicPlaylistContents] {
        try await read { query in
            (query.collections ?? []).compactMap { Self.contents(of: $0) }
        }
    }

    func playlist(persistentID: String) async throws -> AppleMusicPlaylistContents? {
        guard let id = MPMediaEntityPersistentID(persistentID) else { return nil }
        return try await read { query in
            query.addFilterPredicate(
                MPMediaPropertyPredicate(
                    value: NSNumber(value: id),
                    forProperty: MPMediaPlaylistPropertyPersistentID
                )
            )
            return (query.collections ?? []).compactMap { Self.contents(of: $0) }
        }.first
    }

    /// Runs a playlist query off the main actor and hands back Sendable value types — the
    /// `MPMedia*` objects never escape this closure.
    private func read(
        _ body: @escaping @Sendable (MPMediaQuery) -> [AppleMusicPlaylistContents]
    ) async throws -> [AppleMusicPlaylistContents] {
        guard access == .authorized else { throw IngestError.appleMusicAccessDenied }
        return await Task.detached(priority: .userInitiated) {
            body(MPMediaQuery.playlists())
        }.value
    }

    /// Converts one library playlist into value types, dropping the rows we can't use:
    /// folders (containers, no songs of their own) and empty or untitled playlists.
    private static func contents(of collection: MPMediaItemCollection) -> AppleMusicPlaylistContents? {
        guard let playlist = collection as? MPMediaPlaylist else { return nil }
        let tracks: [AppleMusicTrack] = playlist.items.compactMap { item in
            guard let title = item.title, !title.isEmpty else { return nil }
            let artist = item.artist.flatMap { $0.isEmpty ? nil : $0 }
            // A zero duration means Music hasn't got the metadata yet; leave it unknown so the
            // ingest pipeline fills it in from the downloaded file rather than persisting 0.
            let duration = item.playbackDuration > 0 ? Int(item.playbackDuration.rounded()) : nil
            return AppleMusicTrack(title: title, artist: artist, durationSeconds: duration)
        }
        guard !tracks.isEmpty else { return nil }

        let name = playlist.value(forProperty: MPMediaPlaylistPropertyName) as? String
        return AppleMusicPlaylistContents(
            persistentID: String(playlist.persistentID),
            name: name?.isEmpty == false ? name : nil,
            tracks: tracks
        )
    }

    private static func map(_ status: MPMediaLibraryAuthorizationStatus) -> AppleMusicAccess {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        // `.restricted` (Screen Time / MDM) is as final as `.denied` from our side.
        default: return .denied
        }
    }
}
