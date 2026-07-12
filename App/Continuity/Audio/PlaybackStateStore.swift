import Foundation

/// The playback session persisted across launches: what was playing, where, the play history
/// (for unlimited previous-skips), and the remaining forward-skip budget.
struct PersistedPlaybackState: Codable, Equatable {
    var queueTrackIDs: [UUID]
    var currentIndex: Int
    var positionSeconds: Double
    var skipsRemaining: Int
    var historyTrackIDs: [UUID]
}

/// UserDefaults-backed persistence for `PersistedPlaybackState`. The state is a small JSON blob
/// (track UUIDs + a few numbers) written on playback changes and periodically during play, so a
/// relaunch resumes the same song at the same spot with history and skip budget intact.
enum PlaybackStateStore {
    private static let key = "playbackState.v1"

    static func load() -> PersistedPlaybackState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedPlaybackState.self, from: data)
    }

    static func save(_ state: PersistedPlaybackState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
