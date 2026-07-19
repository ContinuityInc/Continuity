import SwiftUI
import Ingest
import Domain
import SwiftData
import UniformTypeIdentifiers

/// Sheet for importing audio files from the Files app into the library. Picked files are
/// copied into the app's audio cache, their embedded metadata (title/artist/artwork) is read,
/// and the `PreparationQueue` runs BPM/key/loudness analysis in the background.
struct AddMusicView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PreparationQueue.self) private var preparationQueue

    @State private var showingFilePicker = false
    /// True while picked files are being copied + their metadata read.
    @State private var isImporting = false
    /// Post-import confirmation ("Imported 3 songs"), or a failure note.
    @State private var resultMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingFilePicker = true
                    } label: {
                        HStack {
                            if isImporting {
                                ProgressView()
                                Text("Importing…")
                            } else {
                                Label("Choose Files", systemImage: "folder.badge.plus")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(isImporting)
                } footer: {
                    footerContent
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Add Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isImporting)
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: true
            ) { result in
                handlePicked(result)
            }
        }
    }

    @ViewBuilder
    private var footerContent: some View {
        if let resultMessage {
            Label(resultMessage, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.footnote)
        } else {
            Text("Import songs from the Files app. Title, artist, and artwork are read from the file; tempo and key are analyzed automatically for seamless transitions.")
        }
    }

    /// Copies the picked files into the library, then shows how many made it.
    private func handlePicked(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        isImporting = true
        resultMessage = nil
        Task {
            let count = await preparationQueue.importLocalFiles(urls, in: modelContext)
            isImporting = false
            resultMessage = count == 1 ? "Imported 1 song" : "Imported \(count) songs"
        }
    }
}
