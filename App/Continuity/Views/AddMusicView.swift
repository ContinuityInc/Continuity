import SwiftUI
import UniformTypeIdentifiers
import Ingest
import Domain
import SwiftData

/// Sheet for adding music: pick local audio files from Files. (On `main` this sheet instead
/// takes a YouTube/Spotify link; this branch ships without remote ingest.)
struct AddMusicView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PreparationQueue.self) private var preparationQueue

    @State private var errorMessage: String?
    @State private var isImporting = false
    @State private var showingFilePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Add songs from the Files app. Continuity copies them into its library.")
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
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
            allowsMultipleSelection: true
        ) { result in
            handlePickedFiles(result)
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
}
