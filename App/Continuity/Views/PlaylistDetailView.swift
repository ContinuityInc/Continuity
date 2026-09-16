import SwiftUI
import Ingest
import Playback
import Domain

/// A playlist's track list. Tapping a track starts playback of the whole playlist from there.
struct PlaylistDetailView: View {
    @Bindable var playlist: Playlist
    @Environment(Player.self) private var player
    @Environment(MainPagerState.self) private var pagerState
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        // Resolved once per body evaluation: `orderedTracks` sorts and copies the whole
        // relationship array, and this body used to call it three times (rows, tap handler,
        // Play button) — plus once more per tap.
        let tracks = playlist.orderedTracks
        return List {
            // The header is a regular row — NOT a pinned section header, which in a plain list
            // floats transparently over the rows and lets them scroll underneath the Play button.
            // As a row it scrolls away with the content, Apple Music-style.
            header(tracks)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())

            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard track.prepState != .failed else { return }
                        player.play(tracks: tracks, startAt: index)
                        pagerState.goToNowPlaying()
                    }
                    .contextMenu {
                        Button {
                            player.playNext(track)
                        } label: {
                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            delete(track)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        // Pushed destinations don't inherit insets added outside the NavigationStack, so the
        // dock is attached here too — this is what keeps the bar off the last row.
        .miniPlayerDock()
    }

    /// Removes a track: the player drops it first (so no deck/queue reference dangles), then the
    /// model goes, then any cached files no other track shares.
    private func delete(_ track: Track) {
        let key = track.stemKey
        player.handleDeleted(trackIDs: [track.id])
        modelContext.delete(track)
        playlist.touch()    // membership changed → resort the library
        try? modelContext.save()
        LibraryCleanup.removeOrphanedFiles(keys: [key], in: modelContext)
    }

    private func header(_ tracks: [Track]) -> some View {
        VStack(spacing: 12) {
            RemoteArtworkView(url: playlist.artworkURL, symbol: playlist.artworkSymbol, seed: playlist.gradientSeed, cornerRadius: 20)
                .frame(width: 180, height: 180)
                .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
            Text(playlist.title).font(.title2.bold())
            Text(playlist.subtitle).font(.subheadline).foregroundStyle(.secondary)
            Button {
                player.play(tracks: tracks, startAt: 0)
                pagerState.goToNowPlaying()
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Play \(playlist.title)")
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

/// One track row. Reads the now-playing highlight itself rather than taking it as a parameter:
/// as a parameter, every track change invalidated `PlaylistDetailView.body` — which re-sorted
/// the entire playlist to rebuild the list.
private struct TrackRow: View {
    let track: Track
    @Environment(Player.self) private var player

    private var isCurrent: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            RemoteArtworkView(url: track.artworkURL, symbol: track.artworkSymbol, seed: track.gradientSeed, cornerRadius: 8)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title), \(track.artist)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
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
            // Missing audio in this build can't be re-fetched — re-import the file.
            Image(systemName: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityLabel("Unavailable")
        case .ready:
            EmptyView()
        }
    }
}
