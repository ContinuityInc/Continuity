import SwiftUI
import SwiftData
import ContinuityCore

/// Sheet for pasting a YouTube link and queueing it for ingestion. Parses the link locally
/// (no networking here), creates a placeholder `Track` in a shared "From YouTube" playlist,
/// and hands it to the `PreparationQueue`, which resolves + downloads the audio in the
/// background and flips the track to `.ready`.
struct AddFromYouTubeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PreparationQueue.self) private var preparationQueue

    @State private var text = ""
    @State private var errorMessage: String?

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("YouTube link or video ID", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                        .onChange(of: text) { errorMessage = nil }
                } footer: {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    } else {
                        Text("Paste a youtube.com / youtu.be link, or an 11-character video ID.")
                    }
                }

                Section {
                    Button(action: add) {
                        Label("Add", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(trimmed.isEmpty)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Add from YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// Parses the link, builds a placeholder track in the "From YouTube" playlist, and
    /// enqueues it for preparation. Shows an inline error if no video ID can be found.
    private func add() {
        let link = YouTubeURL.parse(trimmed)
        guard let videoID = link?.videoID else {
            errorMessage = "Couldn't find a YouTube video in that link."
            return
        }

        let playlist = findOrCreateYouTubePlaylist()

        // NOTE: title/artist/duration/artwork are placeholders — fetching real video
        // metadata (oEmbed / player response) is a later ingestion task. For now we key
        // the title off the video ID so the row is recognisable before it's ready.
        let track = Track(
            title: "YouTube Video (\(videoID.prefix(6)))",
            artist: "YouTube",
            durationSeconds: 0,
            artworkSymbol: playlist.artworkSymbol,
            // Vary the gradient per track so rows are visually distinct.
            gradientSeed: playlist.gradientSeed * 100 + playlist.tracks.count,
            sortIndex: playlist.tracks.count,
            prepState: .pending,
            youtubeVideoID: videoID,
            sourceURLString: trimmed
        )

        playlist.tracks.append(track)
        modelContext.insert(track)

        preparationQueue.enqueue(track, in: modelContext)
        dismiss()
    }

    /// Returns the shared "From YouTube" playlist, creating and inserting it if missing.
    private func findOrCreateYouTubePlaylist() -> Playlist {
        let title = "From YouTube"
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.title == title })
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }

        let playlist = Playlist(
            title: title,
            subtitle: "Added from YouTube",
            artworkSymbol: "arrow.down.circle.fill",
            gradientSeed: 11
        )
        modelContext.insert(playlist)
        return playlist
    }
}
