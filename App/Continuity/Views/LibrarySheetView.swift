import SwiftUI
import UniformTypeIdentifiers
import Ingest
import Playback

/// Library page in the vertical shell (above Now Playing): browse/add/delete playlists,
/// with a mini player that jumps back to the home page.
struct LibrarySheetView: View {
    @Environment(PreparationQueue.self) private var prepQueue
    @Environment(\.modelContext) private var modelContext
    @State private var showingLocalImport = false
    /// Non-nil while a picked folder/files are being scanned + copied in.
    @State private var isImportingLocal = false

    var body: some View {
        NavigationStack {
            LibraryView()
                .miniPlayerDock()
                .navigationTitle("Continuity")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingLocalImport = true
                        } label: {
                            if isImportingLocal {
                                ProgressView()
                            } else {
                                Image(systemName: "plus")
                            }
                        }
                        .disabled(isImportingLocal)
                        .accessibilityLabel("Import local files")
                    }
                }
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
    }
}
