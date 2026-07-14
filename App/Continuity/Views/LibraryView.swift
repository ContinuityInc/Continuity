import SwiftUI
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

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
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
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        PlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            delete(playlist)
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
    }
}

private struct PlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteArtworkView(url: playlist.artworkURL, symbol: playlist.artworkSymbol, seed: playlist.gradientSeed)
                .aspectRatio(1, contentMode: .fit)
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
