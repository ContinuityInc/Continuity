import SwiftUI
import Ingest
import Domain
import SwiftData
import ContinuityCore

/// Sheet for pasting a music link and queueing it for ingestion. Detects the source locally and
/// routes it:
/// - **YouTube video** → added to the shared "From YouTube" playlist.
/// - **YouTube playlist** → imported as its own library playlist.
/// - **Spotify playlist/album** → its tracklist is imported as a new playlist, with each song's
///   audio re-sourced from YouTube (Spotify audio is DRM-protected and can't feed our engine).
///
/// Classification + import routing live in `LinkImporter` (shared with the URL-scheme and
/// clipboard handlers); the `PreparationQueue` does the resolving/searching/downloading.
struct AddMusicView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PreparationQueue.self) private var preparationQueue

    @State private var text = ""
    @State private var errorMessage: String?
    /// True while a playlist is being resolved (page fetch + track creation).
    @State private var isImporting = false

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the pasted text resolves to, if anything.
    private var detected: LinkImporter.Link? {
        LinkImporter.classify(trimmed)
    }

    /// Whether the detected input imports a whole playlist (vs. adding a single video).
    private var isImportAction: Bool {
        detected?.isPlaylistImport ?? false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("YouTube or Spotify link", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                        .onChange(of: text) { errorMessage = nil }
                } footer: {
                    footerContent
                }

                Section {
                    Button(action: add) {
                        HStack {
                            if isImporting {
                                ProgressView()
                                Text("Importing…")
                            } else {
                                Label(
                                    isImportAction ? "Import Playlist" : "Add",
                                    systemImage: isImportAction ? "music.note.list" : "arrow.down.circle.fill"
                                )
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(trimmed.isEmpty || isImporting)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Add Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isImporting)
                }
            }
        }
    }

    @ViewBuilder
    private var footerContent: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.footnote)
        } else {
            switch detected {
            case .spotify?:
                Text("Spotify playlist — each song is matched to YouTube for audio and imported as a new playlist.")
            case .youtubePlaylist?:
                Text("This is a playlist link — every track will be imported as a new playlist.")
            default:
                Text("Paste a YouTube video or playlist link, or a Spotify playlist/album link.")
            }
        }
    }

    /// Routes the pasted link through the shared importer, or shows an inline error. Shows the
    /// spinner while resolving, dismisses on success, and maps failures to a cause-specific
    /// message (so a transient network blip doesn't read as "private").
    private func add() {
        guard let link = detected else {
            errorMessage = "Couldn't find a YouTube or Spotify link in that text."
            return
        }
        isImporting = true
        errorMessage = nil
        let source = trimmed
        Task {
            defer { isImporting = false }
            do {
                try await LinkImporter.run(link, sourceURL: source, queue: preparationQueue, in: modelContext)
                dismiss()
            } catch {
                errorMessage = LinkImporter.errorMessage(error, noun: link.noun)
            }
        }
    }
}
