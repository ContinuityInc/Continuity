import SwiftUI
import UniformTypeIdentifiers
import Ingest
import Playback

/// Library page in the vertical shell (above Now Playing): browse/add/delete playlists,
/// with a mini player that jumps back to the home page.
struct LibrarySheetView: View {
    @Environment(Player.self) private var player
    @Environment(PreparationQueue.self) private var prepQueue
    @Environment(MainPagerState.self) private var pagerState
    @Environment(\.modelContext) private var modelContext
    @State private var showingAdd = false
    @State private var showingSearch = false
    @State private var showingLocalImport = false
    @State private var showingAppleMusic = false
    /// Non-nil while a picked folder/files are being scanned + copied in.
    @State private var isImportingLocal = false

    var body: some View {
        NavigationStack {
            LibraryView()
                .navigationTitle("Continuity")
                .toolbar {
                    // Every action is a primaryAction so nothing collapses into a dead "…"
                    // overflow menu (secondaryAction items did, and looked broken).
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("Search music")
                    }
                    // Add-by-download: import from other services (YouTube, Spotify links).
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAdd = true
                        } label: {
                            AddBadgeIcon(base: "arrow.down")
                        }
                        .accessibilityLabel("Add from YouTube or Spotify")
                    }
                    // Add-by-library: import playlists from the user's Apple Music library.
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAppleMusic = true
                        } label: {
                            AddBadgeIcon(base: "music.note")
                        }
                        .accessibilityLabel("Import from Apple Music")
                    }
                    // Add-by-upload: import songs from the user's own files.
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingLocalImport = true
                        } label: {
                            if isImportingLocal {
                                ProgressView()
                            } else {
                                AddBadgeIcon(base: "arrow.up")
                            }
                        }
                        .disabled(isImportingLocal)
                        .accessibilityLabel("Import local files")
                    }
                }
        }
        .sheet(isPresented: $showingAdd) {
            AddMusicView()
        }
        .sheet(isPresented: $showingAppleMusic) {
            AppleMusicImportView()
        }
        // Full-screen: the page owns its whole layout (pill / results / custom keyboard).
        .fullScreenCover(isPresented: $showingSearch) {
            SearchView()
        }
        // Local import: pick audio files OR a whole folder — folders are scanned recursively
        // for music (audio type + song-sized) and imported in bulk into "Local Files".
        // iOS sandboxing means the app can't read the Files "music folder" unprompted; a
        // folder grant through this picker is the sanctioned way to scan it.
        .fileImporter(
            isPresented: $showingLocalImport,
            allowedContentTypes: [.audio, .folder],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            isImportingLocal = true
            Task {
                _ = await prepQueue.importLocalFiles(urls, in: modelContext)
                isImportingLocal = false
            }
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

/// A toolbar glyph composed of a base symbol (arrow.down / arrow.up) with a small plus badge —
/// "add by downloading" vs "add by uploading". SF Symbols has no built-in plus-badged arrows,
/// so the badge is drawn as an overlay.
private struct AddBadgeIcon: View {
    let base: String

    var body: some View {
        Image(systemName: base)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .heavy))
                    .offset(x: 7, y: -4)
            }
            .padding(.trailing, 4)   // room for the badge inside the tap target
    }
}
