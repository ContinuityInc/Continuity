import SwiftUI
import SwiftData

/// Minimal library: a grid of playlist/album cards. Tap a card to open its track list.
struct LibraryView: View {
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]

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
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct PlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(symbol: playlist.artworkSymbol, seed: playlist.gradientSeed)
                .aspectRatio(1, contentMode: .fit)
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
