import Foundation

/// A normalized description of one candidate audio stream. The app maps whatever the extraction
/// library returns (e.g. YouTubeKit `Stream`s) onto this, so the *selection policy* stays here in
/// ContinuityCore — library-agnostic and unit-tested.
public struct AudioStreamCandidate: Equatable, Sendable {
    public var itag: Int
    /// Container/extension, e.g. "mp4"/"m4a"/"webm".
    public var container: String
    /// Codec string if known, e.g. "mp4a.40.2" (AAC) or "opus".
    public var audioCodec: String?
    /// Average bitrate in bits per second (higher = better quality).
    public var averageBitrate: Int
    /// True if the stream carries audio and no video.
    public var isAudioOnly: Bool
    /// True if AVFoundation can decode it directly without an extra decoder (AAC/m4a). Opus/WebM
    /// is `false` because `AVAudioFile` can't open it without transcoding.
    public var isNativelyPlayable: Bool
    public var urlString: String

    public init(
        itag: Int,
        container: String,
        audioCodec: String? = nil,
        averageBitrate: Int,
        isAudioOnly: Bool,
        isNativelyPlayable: Bool,
        urlString: String
    ) {
        self.itag = itag
        self.container = container
        self.audioCodec = audioCodec
        self.averageBitrate = averageBitrate
        self.isAudioOnly = isAudioOnly
        self.isNativelyPlayable = isNativelyPlayable
        self.urlString = urlString
    }
}

/// Chooses which stream Continuity should download for a given track.
public enum AudioStreamSelector {

    /// The best stream for our pipeline.
    ///
    /// Policy, in order:
    ///   1. Audio-only streams only (we never want to download video).
    ///   2. Strongly prefer **natively playable** (AAC/m4a) so `AVAudioFile` can decode it with
    ///      no extra dependencies — even if a non-native (opus) stream has a higher bitrate.
    ///   3. Within the chosen tier, pick the highest average bitrate (ties → lower itag for
    ///      determinism).
    ///
    /// Returns `nil` if there are no audio-only candidates at all.
    public static func selectBest(from candidates: [AudioStreamCandidate]) -> AudioStreamCandidate? {
        let audioOnly = candidates.filter(\.isAudioOnly)
        guard !audioOnly.isEmpty else { return nil }

        let native = audioOnly.filter(\.isNativelyPlayable)
        let pool = native.isEmpty ? audioOnly : native
        return pool.max {
            if $0.averageBitrate != $1.averageBitrate {
                return $0.averageBitrate < $1.averageBitrate
            }
            // Higher itag loses the tie so selection is stable.
            return $0.itag > $1.itag
        }
    }

    /// Only natively-playable candidates (AAC/m4a). Useful when the caller wants to *require* a
    /// directly-decodable stream and treat "opus only" as a failure rather than download it.
    public static func selectBestNativelyPlayable(
        from candidates: [AudioStreamCandidate]
    ) -> AudioStreamCandidate? {
        let native = candidates.filter { $0.isAudioOnly && $0.isNativelyPlayable }
        return selectBest(from: native)
    }
}
