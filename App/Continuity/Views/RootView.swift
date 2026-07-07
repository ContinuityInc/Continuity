import SwiftUI

/// Top-level shell: the library, with a Liquid Glass mini-player docked at the bottom that
/// expands into the full Now Playing sheet.
struct RootView: View {
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
            NowPlayingView()
                .presentationDragIndicator(.visible)
        }
        // On launch, pick up any ingestion left unfinished by a previous run (interrupted
        // imports, evicted files, half-separated stems).
        .task {
            prepQueue.resumePreparation(in: modelContext)
        }
    }
}
