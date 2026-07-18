import Foundation
import SwiftData
import Ingest
import Domain
import ContinuityCore

/// Single home for link → import routing, shared by AddMusicView and the URL-scheme /
/// clipboard handlers so YouTube/Spotify classification lives in exactly one place.
@MainActor
enum LinkImporter {

    /// What a raw link resolves to.
    enum Link {
        case spotify(SpotifyLink)
        case youtubePlaylist(String)
        case youtubeVideo(String)

        /// Source name for confirmation UI ("Import from YouTube?").
        var sourceName: String {
            switch self {
            case .spotify: return "Spotify"
            case .youtubePlaylist, .youtubeVideo: return "YouTube"
            }
        }

        /// Whether this imports a whole playlist (vs. adding a single video).
        var isPlaylistImport: Bool {
            switch self {
            case .spotify, .youtubePlaylist: return true
            case .youtubeVideo: return false
            }
        }

        /// Noun used in error messages ("Couldn't import that …").
        var noun: String {
            switch self {
            case .spotify(let link): return "Spotify \(link.kind.rawValue)"
            case .youtubePlaylist: return "playlist"
            case .youtubeVideo: return "video"
            }
        }
    }

    /// Pure classification of pasted/shared text. Nil if no importable link is found.
    nonisolated static func classify(_ raw: String) -> Link? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let link = SpotifyURL.parse(trimmed) { return .spotify(link) }
        if let link = YouTubeURL.parse(trimmed) {
            if let playlistID = link.playlistID { return .youtubePlaylist(playlistID) }
            if let videoID = link.videoID { return .youtubeVideo(videoID) }
        }
        return nil
    }

    /// Kicks off the import for a classified link. Playlist imports resolve before returning;
    /// single videos enqueue instantly. Throws the raw resolver error — map it with
    /// `errorMessage(_:noun:)` for display.
    static func run(
        _ link: Link,
        sourceURL: String,
        queue: PreparationQueue,
        in modelContext: ModelContext
    ) async throws {
        guard RemoteAudioIngest.isEnabled else { throw IngestError.sourceUnavailable }
        switch link {
        case .spotify(let spotifyLink):
            _ = try await queue.importSpotifyPlaylist(spotifyLink, in: modelContext)
        case .youtubePlaylist(let playlistID):
            _ = try await queue.importPlaylist(playlistID: playlistID, in: modelContext)
        case .youtubeVideo(let videoID):
            addSingleVideo(videoID, sourceURL: sourceURL, queue: queue, in: modelContext)
        }
    }

    /// Maps a resolve failure to a message that names the actual cause. Retryable failures
    /// (network/rate-limit) already retried inside the resolver, so reaching here means they
    /// persisted — the message tells the user to try again rather than blaming their playlist.
    nonisolated static func errorMessage(_ error: Error, noun: String) -> String {
        switch error as? IngestError {
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        case .rateLimited:
            return "Too many requests right now — please try again in a minute."
        case .sourceUnavailable:
            if !RemoteAudioIngest.isEnabled {
                return "Importing music isn't available in this build."
            }
            return "That \(noun) looks private or empty. Make sure it's public and try again."
        default:
            return "Couldn't import that \(noun). Please try again."
        }
    }

    /// Builds a placeholder track in the shared "From YouTube" playlist and enqueues it.
    private static func addSingleVideo(
        _ videoID: String,
        sourceURL: String,
        queue: PreparationQueue,
        in modelContext: ModelContext
    ) {
        let playlist = findOrCreateYouTubePlaylist(in: modelContext)

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
            sourceURLString: sourceURL
        )

        playlist.tracks.append(track)
        modelContext.insert(track)
        playlist.touch()    // membership changed → resort the library

        queue.enqueue(track, in: modelContext)
    }

    /// Returns the shared "From YouTube" playlist, creating and inserting it if missing.
    private static func findOrCreateYouTubePlaylist(in modelContext: ModelContext) -> Playlist {
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
