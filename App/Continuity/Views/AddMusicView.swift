import SwiftUI
import UniformTypeIdentifiers
import Ingest
import Domain
import SwiftData
import ContinuityCore

/// Sheet for adding music. On `main` (remote ingest enabled): paste a YouTube/Spotify link.
/// On External TestFlight / App Store builds: pick local audio files from Files.
struct AddMusicView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PreparationQueue.self) private var preparationQueue

    @State private var text = ""
    @State private var errorMessage: String?
    /// True while a playlist is being resolved (page fetch + track creation).
    @State private var isImporting = false
    @State private var showingFilePicker = false

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
            if RemoteAudioIngest.isEnabled {
                remoteImportForm
            } else {
                localImportForm
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
            allowsMultipleSelection: true
        ) { result in
            handlePickedFiles(result)
        }
    }

    // MARK: - Local files (External TF / App Store)

    private var localImportForm: some View {
        Form {
            Section {
                Text("Add songs from the Files app. Continuity copies them into its library — no YouTube download.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    showingFilePicker = true
                } label: {
                    HStack {
                        if isImporting {
                            ProgressView()
                            Text("Importing…")
                        } else {
                            Label("Choose Audio Files", systemImage: "folder.badge.plus")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(isImporting)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
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

    private func handlePickedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else { return }
            isImporting = true
            errorMessage = nil
            Task {
                defer { isImporting = false }
                do {
                    _ = try await preparationQueue.importLocalAudio(urls: urls, in: modelContext)
                    dismiss()
                } catch {
                    errorMessage = "Couldn't import those files. Try M4A, MP3, WAV, or AIFF."
                }
            }
        }
    }

    // MARK: - Remote links (main / private builds)

    private var remoteImportForm: some View {
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
                Button(action: addRemote) {
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

    private func addRemote() {
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
