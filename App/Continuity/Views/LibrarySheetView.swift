import SwiftUI
import Ingest
import Playback

/// Library page in the vertical shell (above Now Playing): browse/add/delete playlists,
/// with a mini player that jumps back to the home page.
struct LibrarySheetView: View {
    @Environment(Player.self) private var player
    @Environment(MainPagerState.self) private var pagerState
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
                    .onTapGesture { pagerState.goToNowPlaying() }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .accessibilityHint("Opens Now Playing")
            } else {
                // No mini player when idle — still need a way back to the home page.
                Button {
                    pagerState.goToNowPlaying()
                } label: {
                    Image(systemName: "chevron.compact.down")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now Playing")
            }
        }
    }
}
