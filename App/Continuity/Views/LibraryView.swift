import SwiftUI
import Ingest
import Playback
import Domain
import SwiftData

/// Minimal library: a grid of playlist/album cards. Tap a card to open its track list;
/// long-press for management actions (delete). Pull down to search every track and playlist.
struct LibraryView: View {
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]
    @Environment(Player.self) private var player
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    /// Playlist awaiting destructive confirmation — set from the context menu, cleared on dismiss.
    @State private var playlistPendingDelete: Playlist?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// Most-recently-edited first; pre-`updatedAt` rows fall back to creation date. Sorted
    /// in-view (grid-sized collections) to sidestep optional-key sort quirks in the query layer.
    private var sortedPlaylists: [Playlist] {
        playlists.sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
    }

    var body: some View {
        Group {
            if trimmedSearch.isEmpty {
                grid
            } else {
                SearchResultsView(playlists: playlists, query: trimmedSearch)
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Songs, artists, playlists")
        .confirmationDialog(
            "Delete Playlist?",
            isPresented: Binding(
                get: { playlistPendingDelete != nil },
                set: { if !$0 { playlistPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: playlistPendingDelete
        ) { playlist in
            Button("Delete \"\(playlist.title)\"", role: .destructive) {
                delete(playlist)
                playlistPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                playlistPendingDelete = nil
            }
        } message: { playlist in
            let count = playlist.tracks.count
            Text("Removes \(count) track\(count == 1 ? "" : "s") and their cached audio. This can’t be undone.")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(sortedPlaylists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        PlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            playlistPendingDelete = playlist
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    /// Removes a playlist and its tracks: the player drops them first (so no deck/queue
    /// reference dangles), then the models go (cascade), then any cached files that no
    /// surviving track shares.
    private func delete(_ playlist: Playlist) {
        let trackIDs = Set(playlist.tracks.map(\.id))
        let videoIDs = playlist.tracks.compactMap(\.youtubeVideoID)
        player.handleDeleted(trackIDs: trackIDs)
        modelContext.delete(playlist)   // cascade deletes its tracks
        try? modelContext.save()
        LibraryCleanup.removeOrphanedFiles(videoIDs: videoIDs, in: modelContext)
    }
}

/// Flat search results across the whole library: matching playlists first, then matching tracks.
/// Tapping a track plays it inside its playlist (so transitions continue into its neighbors).
private struct SearchResultsView: View {
    let playlists: [Playlist]
    let query: String
    @Environment(Player.self) private var player
    @Environment(MainPagerState.self) private var pagerState

    private var matchingPlaylists: [Playlist] {
        playlists.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// Track matches by title or artist, capped so pathological queries stay snappy.
    private var matchingTracks: [Track] {
        var results: [Track] = []
        for playlist in playlists {
            for track in playlist.orderedTracks
            where track.title.localizedCaseInsensitiveContains(query)
                || track.artist.localizedCaseInsensitiveContains(query) {
                results.append(track)
                if results.count >= 100 { return results }
            }
        }
        return results
    }

    var body: some View {
        List {
            let playlistMatches = matchingPlaylists
            if !playlistMatches.isEmpty {
                Section("Playlists") {
                    ForEach(playlistMatches) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            HStack(spacing: 12) {
                                RemoteArtworkView(url: playlist.artworkURL, symbol: playlist.artworkSymbol,
                                                  seed: playlist.gradientSeed, cornerRadius: 8)
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.title).lineLimit(1)
                                    Text(playlist.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }

            let trackMatches = matchingTracks
            if !trackMatches.isEmpty {
                Section("Songs") {
                    ForEach(trackMatches) { track in
                        Button {
                            play(track)
                        } label: {
                            HStack(spacing: 12) {
                                RemoteArtworkView(url: track.artworkURL, symbol: track.artworkSymbol,
                                                  seed: track.gradientSeed, cornerRadius: 8)
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .foregroundStyle(player.currentTrack?.id == track.id
                                                         ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                                        .lineLimit(1)
                                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(Theme.time(track.durationSeconds))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                player.playNext(track)
                            } label: {
                                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                        }
                    }
                }
            }

            if playlistMatches.isEmpty && trackMatches.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Plays the tapped track in its playlist context, so what follows is its real neighbors.
    private func play(_ track: Track) {
        guard let playlist = track.playlist else { return }
        let queue = playlist.orderedTracks
        guard let index = queue.firstIndex(where: { $0.id == track.id }) else { return }
        player.play(tracks: queue, startAt: index)
        pagerState.goToNowPlaying()
    }
}

private struct PlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteArtworkView(url: playlist.artworkURL, symbol: playlist.artworkSymbol, seed: playlist.gradientSeed)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                .overlay(alignment: .topLeading) {
                    if playlist.isDemo {
                        Text("DEMO")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
            Text(playlist.title)
                .font(.headline)
                .lineLimit(1)
            Text(playlist.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
