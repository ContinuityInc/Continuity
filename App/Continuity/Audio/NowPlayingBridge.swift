import Foundation
import Domain
import MediaPlayer
import UIKit

/// Bridges the Player to the system's now-playing surfaces — lock screen, Control Center,
/// AirPods/headphone buttons, CarPlay. Publishes track info + playback state to
/// `MPNowPlayingInfoCenter` and routes `MPRemoteCommandCenter` commands back into the Player.
///
/// The lock screen's Next button respects the forward-skip budget: it's disabled at 0 skips,
/// exactly like the in-app button. Previous is always available (unlimited).
@MainActor
final class NowPlayingBridge {
    private weak var player: Player?

    /// Synchronous mirror of the skip budget — command handlers must answer the system
    /// immediately, without hopping actors.
    private var canSkipForward = true
    /// Artwork is fetched async per track and cached so periodic info updates don't refetch.
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    func configure(player: Player) {
        self.player = player
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.onMain { $0.remotePlay() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.onMain { $0.remotePause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onMain { $0.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.canSkipForward else { return .commandFailed }
            self.onMain { $0.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onMain { $0.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.onMain { $0.seek(to: event.positionTime) }
            return .success
        }
    }

    /// Publishes the current state. Called on every playback discontinuity (track change,
    /// play/pause, seek, skip-budget change) — the system interpolates elapsed time in between.
    func update(track: Track?, duration: TimeInterval, position: TimeInterval,
                isPlaying: Bool, skipsRemaining: Int) {
        canSkipForward = skipsRemaining > 0
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = canSkipForward

        guard let track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]

        if track.artworkURL == artworkURL {
            if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        } else {
            fetchArtwork(for: track)
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Loads the track's artwork once, then merges it into the live info dictionary.
    private func fetchArtwork(for track: Track) {
        artworkTask?.cancel()
        artwork = nil
        artworkURL = track.artworkURL
        guard let url = track.artworkURL else { return }

        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data), !Task.isCancelled else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            guard let self, self.artworkURL == url else { return }
            self.artwork = art
            // Merge rather than rebuild — playback state may have moved on since the fetch began.
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = art
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// Runs a Player call on the main actor from a (possibly off-main) command callback.
    private nonisolated func onMain(_ action: @escaping @MainActor (Player) -> Void) {
        Task { @MainActor [weak self] in
            guard let player = self?.player else { return }
            action(player)
        }
    }
}
