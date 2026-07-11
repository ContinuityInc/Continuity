import SwiftUI
import SwiftData

/// Minimal library: a grid of playlist/album cards. Tap a card to open its track list;
/// long-press for management actions (delete).
struct LibraryView: View {
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]
    @Environment(Player.self) private var player
    @Environment(\.modelContext) private var modelContext

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
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
