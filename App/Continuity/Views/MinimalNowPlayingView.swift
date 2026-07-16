import SwiftUI
import Ingest
import Playback

/// The app's home: a deliberately minimal Now Playing surface. Blurred album art fills the
/// background; the only controls are previous / play-pause / next, with the remaining
/// forward-skip budget shown under Next (previous is unlimited). A small corner button opens
/// the library for browsing and adding music.
struct MinimalNowPlayingView: View {
    @Environment(Player.self) private var player
    @State private var showingLibrary = false
    @State private var showingUpNext = false

    var body: some View {
        ZStack {
            backdrop

            // Title/artist + transport, as one vertically-centred column.
            VStack(spacing: 34) {
                trackLabel
                transport
            }
            .padding(.horizontal, 24)
        }
        .overlay(alignment: .topTrailing) {
            libraryButton
                .padding(.top, 8)
                .padding(.trailing, 20)
        }
        .overlay(alignment: .topLeading) {
            upNextButton
                .padding(.top, 8)
                .padding(.leading, 20)
        }
        .sheet(isPresented: $showingLibrary) {
            LibrarySheetView()
        }
        .sheet(isPresented: $showingUpNext) {
            UpNextView()
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Background

    /// The current track's album art, blurred edge-to-edge behind a depth scrim (black when idle).
    private var backdrop: some View {
        Group {
            if let track = player.currentTrack {
                AlbumBackdrop(url: track.artworkURL, seed: track.gradientSeed)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
    }

    // MARK: Now-playing label

    /// What's playing, kept quiet so the controls stay the focus.
    private var trackLabel: some View {
        VStack(spacing: 5) {
            Text(player.currentTrack?.title ?? "Not Playing")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(player.currentTrack?.artist ?? " ")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
        .animation(.easeInOut(duration: 0.3), value: player.currentTrack?.id)
    }

    // MARK: Controls

    /// How far through the track we are (0…1), drives the ring around Play.
    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(max(player.position / player.duration, 0), 1)
    }

    private var transport: some View {
        HStack(spacing: 48) {
            // Previous — unlimited, so no counter.
            controlGlyph("backward.fill") { player.previous() }

            playButton

            // Next — spends one of the limited forward skips; the remaining count rides below it.
            controlGlyph("forward.fill") { player.next() }
                .disabled(player.skipsRemaining == 0)
                .opacity(player.skipsRemaining == 0 ? 0.3 : 1)
                .overlay(alignment: .bottom) { skipBadge.offset(y: 30) }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }

    /// Play/pause: accent disc with a soft glow, wrapped by a thin track-progress ring.
    private var playButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.78)],
                        startPoint: .top, endPoint: .bottom))
                    .padding(9)
                    .shadow(color: Color.accentColor.opacity(0.55), radius: 18, y: 6)
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .offset(x: player.isPlaying ? 0 : 2)   // optically centre the play triangle
            }
            .frame(width: 108, height: 108)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    /// A plain white transport glyph with a comfortable tap target.
    private func controlGlyph(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 30, weight: .medium))
                .frame(width: 60, height: 60)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// Remaining forward skips, as a subtle glass pill under Next.
    private var skipBadge: some View {
        Text("\(player.skipsRemaining)")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .accessibilityLabel("\(player.skipsRemaining) skips remaining")
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

    /// Mirrors the library button in the opposite corner: the queue is browsing's counterpart.
    private var upNextButton: some View {
        Button {
            showingUpNext = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 40, height: 40)
                .continuityGlass(cornerRadius: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Up Next")
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
