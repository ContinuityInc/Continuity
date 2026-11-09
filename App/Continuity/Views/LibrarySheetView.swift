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
    @State private var isImportingLocal = false

    var body: some View {
        NavigationStack {
            LibraryView()
                .miniPlayerDock()
                .navigationTitle("Continuity")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .restorePagerSafeArea()
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
