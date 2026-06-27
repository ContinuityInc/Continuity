import SwiftUI

/// A playlist's track list. Tapping a track starts playback of the whole playlist from there.
struct PlaylistDetailView: View {
    let playlist: Playlist
    @Environment(Player.self) private var player

    var body: some View {
        List {
            Section {
                ForEach(Array(playlist.orderedTracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track, isCurrent: player.currentTrack?.id == track.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.play(tracks: playlist.orderedTracks, startAt: index)
                        }
                }
            } header: {
                header
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(symbol: playlist.artworkSymbol, seed: playlist.gradientSeed, cornerRadius: 20)
                .frame(width: 180, height: 180)
            Text(playlist.title).font(.title2.bold())
            Text(playlist.subtitle).font(.subheadline).foregroundStyle(.secondary)
            Button {
                player.play(tracks: playlist.orderedTracks, startAt: 0)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.glassProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .textCase(nil)
    }
}

private struct TrackRow: View {
    let track: Track
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(symbol: track.artworkSymbol, seed: track.gradientSeed, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
            Text(Theme.time(track.durationSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
