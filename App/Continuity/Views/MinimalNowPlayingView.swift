import SwiftUI

/// The app's home: a deliberately minimal Now Playing surface. Blurred album art fills the
/// background; the only controls are previous / play-pause / next, with the remaining
/// forward-skip budget shown under Next (previous is unlimited). A small corner button opens
/// the library for browsing and adding music.
struct MinimalNowPlayingView: View {
    @Environment(Player.self) private var player
    @State private var showingLibrary = false

    var body: some View {
        ZStack {
            backdrop

            // Transport sits dead-center on the artwork.
            transport
        }
        .overlay(alignment: .topTrailing) {
            libraryButton
                .padding(.top, 8)
                .padding(.trailing, 20)
        }
        .sheet(isPresented: $showingLibrary) {
            LibrarySheetView()
        }
    }

    // MARK: Background

    /// The current track's album art, blurred edge-to-edge (gradient fallback for demo tracks).
    private var backdrop: some View {
        GeometryReader { proxy in
            Group {
                if let track = player.currentTrack {
                    if let url = track.artworkURL {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Theme.gradient(seed: track.gradientSeed)
                            }
                        }
                    } else {
                        Theme.gradient(seed: track.gradientSeed)
                    }
                } else {
                    Color.black
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .blur(radius: 55, opaque: true)
            .overlay(Color.black.opacity(0.35))   // keep white controls legible on bright art
        }
        .ignoresSafeArea()
    }

    // MARK: Controls

    private var transport: some View {
        HStack(alignment: .top, spacing: 56) {
            // Previous — unlimited, so no counter.
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 32))
                    .frame(width: 64, height: 64)
            }

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(Color.accentColor))   // accent circle behind play
            }

            // Next — spends one of the limited forward skips; the count sits underneath.
            VStack(spacing: 6) {
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 32))
                        .frame(width: 64, height: 64)
                }
                .disabled(player.skipsRemaining == 0)
                .opacity(player.skipsRemaining == 0 ? 0.35 : 1)

                Text("\(player.skipsRemaining)")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityLabel("\(player.skipsRemaining) skips remaining")
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .buttonStyle(.plain)
    }

    private var libraryButton: some View {
        Button {
            showingLibrary = true
        } label: {
            Image(systemName: "music.note.list")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 40, height: 40)
                .continuityGlass(cornerRadius: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Library")
    }
}

/// The full library experience, presented as a sheet from the minimal Now Playing home:
/// browse/add/delete playlists, with the mini player and the detailed Now Playing sheet intact.
private struct LibrarySheetView: View {
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
            NowPlayingView()
                .presentationDragIndicator(.visible)
        }
    }
}
