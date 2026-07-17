import Foundation
import YouTubeKit
import ContinuityCore

/// Resolves a YouTube video ID to a single downloadable audio stream via the
/// `YouTubeKit` extraction library.
///
/// **Fragility note:** `YouTubeKit` scrapes/extracts stream URLs from YouTube's
/// player response, so it is inherently brittle — YouTube can change its player
/// at any time and break extraction without warning. Treat resolve failures as
/// expected, recoverable runtime errors rather than programmer errors.
///
/// This type deliberately contains *no* selection policy: it only maps every
/// `YouTubeKit.Stream` onto the library-agnostic `ContinuityCore.AudioStreamCandidate`
/// and delegates the actual "which stream do we download" decision to
/// `ContinuityCore.AudioStreamSelector`, which is unit-tested and free of any
/// dependency on YouTubeKit's (changeable) shape.
final class YouTubeStreamResolver: AudioStreamResolving {

    public init() {}

    func resolveAudio(videoID: String) async throws -> ResolvedAudio {
        // Extraction blips (timeouts, player-response churn) are the most common ingest failure;
        // playlist resolvers already retry — keep the per-track path consistent.
        try await Retry.run {
            try await self.resolveOnce(videoID: videoID)
        }
    }

    private func resolveOnce(videoID: String) async throws -> ResolvedAudio {
        let streams: [YouTubeKit.Stream]
        do {
            streams = try await YouTube(videoID: videoID).streams
        } catch {
            // YouTubeKit doesn't surface typed network vs. permanent failures. Treat library
            // throws as transient so Retry.run can absorb blips; a truly empty candidate list
            // still becomes `.noPlayableStream` below (non-retryable).
            throw IngestError.network(String(describing: error))
        }

        let candidates: [AudioStreamCandidate] = streams.enumerated().map { index, stream in
            // YouTubeKit's `ITag.itag` is internal, so the real itag number isn't reachable
            // from our module. `itag` is only used by the selector for deterministic
            // tie-breaking, so the stream's index is a fine, stable stand-in.
            return AudioStreamCandidate(
                itag: index,
                container: Self.containerString(for: stream),
                audioCodec: stream.audioCodec.map { String(describing: $0) },
                averageBitrate: stream.averageBitrate ?? stream.bitrate ?? 0,
                isAudioOnly: stream.includesAudioTrack && !stream.includesVideoTrack,
                // Our contract for `isNativelyPlayable` is specifically "AVAudioFile can decode
                // it" (AAC/m4a). YouTubeKit's `Stream.isNativelyPlayable` is the broader AVPlayer
                // notion and returns true for Dolby AC-3/EC-3 too, which AVAudioFile can't open —
                // so derive the flag straight from the AAC codec instead.
                isNativelyPlayable: stream.audioCodec == .mp4a,
                urlString: stream.url.absoluteString
            )
        }

        guard let best = AudioStreamSelector.selectBest(from: candidates) else {
            throw IngestError.noPlayableStream
        }

        guard let url = URL(string: best.urlString) else {
            throw IngestError.noPlayableStream
        }

        return ResolvedAudio(
            videoID: videoID,
            url: url,
            itag: best.itag,
            container: best.container,
            isNativelyPlayable: best.isNativelyPlayable,
            approxBitrate: best.averageBitrate
        )
    }

    /// Lowercased container/extension string (e.g. "m4a", "webm") derived from the
    /// stream's `fileExtension` enum.
    private static func containerString(for stream: YouTubeKit.Stream) -> String {
        // FileExtension is a String-backed enum, so rawValue is already e.g. "m4a"/"webm".
        stream.fileExtension.rawValue
    }
}
