import SwiftUI
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
/// The `PreparationQueue` does the resolving/searching/downloading in the background.
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
    private enum Detected {
        case spotify(SpotifyLink)
        case youtubePlaylist(String)
        case youtubeVideo(String)
        case none
    }

    private var detected: Detected {
        if let link = SpotifyURL.parse(trimmed) { return .spotify(link) }
        if let link = YouTubeURL.parse(trimmed) {
            if let playlistID = link.playlistID { return .youtubePlaylist(playlistID) }
            if let videoID = link.videoID { return .youtubeVideo(videoID) }
        }
        return .none
    }

    /// Whether the detected input imports a whole playlist (vs. adding a single video).
    private var isImportAction: Bool {
        switch detected {
        case .spotify, .youtubePlaylist: return true
        case .youtubeVideo, .none: return false
        }
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
            case .spotify:
                Text("Spotify playlist — each song is matched to YouTube for audio and imported as a new playlist.")
            case .youtubePlaylist:
                Text("This is a playlist link — every track will be imported as a new playlist.")
            default:
                Text("Paste a YouTube video or playlist link, or a Spotify playlist/album link.")
            }
        }
    }

    /// Routes the pasted link to the right import path, or shows an inline error.
    private func add() {
        switch detected {
        case .spotify(let link):
            importSpotify(link)
        case .youtubePlaylist(let playlistID):
            importYouTubePlaylist(playlistID)
        case .youtubeVideo(let videoID):
            addSingleVideo(videoID)
        case .none:
            errorMessage = "Couldn't find a YouTube or Spotify link in that text."
        }
    }

    /// Imports a Spotify playlist/album — tracklist from Spotify, audio from YouTube.
    private func importSpotify(_ link: SpotifyLink) {
        runImport(noun: "Spotify \(link.kind.rawValue)") {
            try await preparationQueue.importSpotifyPlaylist(link, in: modelContext)
        }
    }

    /// Imports a YouTube playlist as its own library playlist.
    private func importYouTubePlaylist(_ playlistID: String) {
        runImport(noun: "playlist") {
            try await preparationQueue.importPlaylist(playlistID: playlistID, in: modelContext)
        }
    }

    /// Shared async import runner: shows the spinner, dismisses on success, shows an accurate,
    /// cause-specific error otherwise (so a transient network blip doesn't read as "private").
    private func runImport(noun: String, _ work: @escaping () async throws -> Playlist) {
        isImporting = true
        errorMessage = nil
        Task {
            defer { isImporting = false }
            do {
                _ = try await work()
                dismiss()
            } catch {
                errorMessage = Self.importErrorMessage(error, noun: noun)
            }
        }
    }

    /// Maps a resolve failure to a message that names the actual cause. Retryable failures
    /// (network/rate-limit) already retried inside the resolver, so reaching here means they
    /// persisted — the message tells the user to try again rather than blaming their playlist.
    private static func importErrorMessage(_ error: Error, noun: String) -> String {
        switch error as? IngestError {
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        case .rateLimited:
            return "Too many requests right now — please try again in a minute."
        case .sourceUnavailable:
            return "That \(noun) looks private or empty. Make sure it's public and try again."
        default:
            return "Couldn't import that \(noun). Please try again."
        }
    }

    /// Builds a placeholder track in the shared "From YouTube" playlist and enqueues it.
    private func addSingleVideo(_ videoID: String) {
        let playlist = findOrCreateYouTubePlaylist()

        // Title/artist/duration start as placeholders so the row appears instantly; the
        // ingest pipeline replaces them with the real oEmbed title/channel + decoded duration.
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
