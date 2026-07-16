import SwiftUI
import Ingest
import Playback

/// The full library experience, presented as a sheet from the minimal Now Playing home:
/// browse/add/delete playlists, with the mini player and the detailed Now Playing sheet intact.
struct LibrarySheetView: View {
    @Environment(Player.self) private var player
    @Environment(PreparationQueue.self) private var prepQueue
    @Environment(\.modelContext) private var modelContext
    @State private var showNowPlaying = false
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            LibraryView()
                .navigationTitle("Continuity")
                .toolbar {
                    // Manual whole-library sync (source-backed playlists only).
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            prepQueue.syncAll(in: modelContext)
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .symbolEffect(.rotate, isActive: !prepQueue.syncingPlaylistIDs.isEmpty)
                        }
                        .disabled(!prepQueue.syncingPlaylistIDs.isEmpty)
                        .accessibilityLabel("Sync library")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAdd = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add music")
                    }
                }
        }
        .sheet(isPresented: $showingAdd) {
            AddMusicView()
        }
        .safeAreaInset(edge: .bottom) {
            if player.currentTrack != nil {
                MiniPlayerView()
                    .onTapGesture { showNowPlaying = true }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView(mode: .sheet)
                .presentationDragIndicator(.visible)
        }
    }
}
