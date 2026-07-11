import SwiftUI

/// Compact Liquid Glass now-playing bar docked above the bottom safe area.
struct MiniPlayerView: View {
    @Environment(Player.self) private var player

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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .continuityGlass(cornerRadius: 18)
    }
}
