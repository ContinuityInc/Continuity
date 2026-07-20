import SwiftUI
import Ingest
import Playback
import Domain

/// A playlist's track list. Tapping a track starts playback of the whole playlist from there.
struct PlaylistDetailView: View {
    @Bindable var playlist: Playlist
    @Environment(Player.self) private var player
    @Environment(PreparationQueue.self) private var prepQueue
    @Environment(MainPagerState.self) private var pagerState
    @Environment(\.modelContext) private var modelContext

    private var isSyncing: Bool { prepQueue.syncingPlaylistIDs.contains(playlist.id) }

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
                            pagerState.goToNowPlaying()
                        }
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

    private var header: some View {
        VStack(spacing: 12) {
            RemoteArtworkView(url: playlist.artworkURL, symbol: playlist.artworkSymbol, seed: playlist.gradientSeed, cornerRadius: 20)
                .frame(width: 180, height: 180)
                .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
            Text(playlist.title).font(.title2.bold())
            Text(playlist.subtitle).font(.subheadline).foregroundStyle(.secondary)
            Button {
                player.play(tracks: playlist.orderedTracks, startAt: 0)
                pagerState.goToNowPlaying()
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.glassProminent)
            .padding(.top, 4)

            // Source-backed playlists mirror a remote list: manual sync + the auto-sync opt-out.
            if playlist.isSourceBacked {
                HStack(spacing: 16) {
                    Button {
                        Task { await prepQueue.syncPlaylist(playlist, in: modelContext) }
                    } label: {
                        Label(isSyncing ? "Syncing…" : "Sync", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSyncing)

                    Toggle(isOn: $playlist.autoSyncEnabled) {
                        Text("Auto-sync")
                            .font(.subheadline)
                    }
                    .fixedSize()
                }
                .padding(.top, 2)

                if let synced = playlist.lastSyncedAt {
                    Text("Synced \(synced.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
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
