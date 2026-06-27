import SwiftUI

/// Top-level shell: the library, with a Liquid Glass mini-player docked at the bottom that
/// expands into the full Now Playing sheet.
struct RootView: View {
    @Environment(Player.self) private var player
    @State private var showNowPlaying = false

    var body: some View {
        NavigationStack {
            LibraryView()
                .navigationTitle("Continuity")
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
    }
}
