import SwiftUI

/// A playlist's track list. Tapping a track starts playback of the whole playlist from there.
struct PlaylistDetailView: View {
    let playlist: Playlist
    @Environment(Player.self) private var player
    @Environment(PreparationQueue.self) private var prepQueue
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            // The header is a regular row — NOT a pinned section header, which in a plain list
            // floats transparently over the rows and lets them scroll underneath the Play button.
            // As a row it scrolls away with the content, Apple Music-style.
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())

            ForEach(Array(playlist.orderedTracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, isCurrent: player.currentTrack?.id == track.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // A failed ingest can't be played — tapping it retries instead.
                        if track.prepState == .failed {
                            prepQueue.enqueue(track, in: modelContext)
                        } else {
                            player.play(tracks: playlist.orderedTracks, startAt: index)
                        }
                    }
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
            if track.isDemo {
                Text("DEMO")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            prepIndicator
            Text(Theme.time(track.durationSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// Subtle trailing badge reflecting the track's ingest state. Ready tracks show nothing.
    @ViewBuilder
    private var prepIndicator: some View {
        switch track.prepState {
        case .pending, .preparing:
            // Downloading/resolving — a quiet spinner sized to match the caption row.
            ProgressView()
                .controlSize(.mini)
        case .failed:
            // Tapping the row retries a failed ingest — the retry glyph signals it's actionable.
            Image(systemName: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case .ready:
            EmptyView()
        }
    }
}
