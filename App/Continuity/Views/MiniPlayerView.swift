import SwiftUI
import Playback

/// Compact Liquid Glass now-playing bar docked above the bottom safe area.
struct MiniPlayerView: View {
    @Environment(Player.self) private var player

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(max(player.position / player.duration, 0), 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            if let track = player.currentTrack {
                RemoteArtworkView(url: track.artworkURL, symbol: track.artworkSymbol, seed: track.gradientSeed, cornerRadius: 8)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(player.skipsRemaining == 0)
                .opacity(player.skipsRemaining == 0 ? 0.35 : 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .continuityGlass(cornerRadius: 18)
        // Thin play-progress line hugging the bottom edge of the glass bar.
        .overlay(alignment: .bottomLeading) {
            GeometryReader { geo in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, geo.size.width * progress), height: 2.5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 2.5)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            .allowsHitTesting(false)
        }
    }
}
