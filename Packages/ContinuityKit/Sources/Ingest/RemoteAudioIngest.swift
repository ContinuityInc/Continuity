import Foundation

/// Gates YouTube stream download and Spotify→YouTube audio matching.
///
/// Disabled on `release/external-testflight` and `release/app-store` so External TestFlight /
/// App Store builds cannot download YouTube audio (ToS / App Review). Demo tracks still play
/// via `ToneSynth`. Main keeps remote ingest enabled.
public enum RemoteAudioIngest {
    public static let isEnabled = false
}
