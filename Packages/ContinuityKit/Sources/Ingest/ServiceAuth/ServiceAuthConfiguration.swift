import ContinuityCore
import Foundation

/// OAuth client ids for the sign-in providers. Read from the app's Info.plist
/// (`ContinuityServiceAuth` dictionary, populated from build settings in `project.yml`) so the
/// ids never live in source — a service with an empty id simply shows "not set up" in the UI.
///
/// Redirect URIs use the app's `continuity://` scheme (Spotify, SoundCloud); Google requires its
/// reversed-client-id scheme, derived from the id by `OAuthProviders.google`. Neither needs an
/// Info.plist URL type: `ASWebAuthenticationSession` intercepts the callback itself.
public struct ServiceAuthConfiguration: Sendable, Equatable {
    public var spotifyClientID: String
    public var googleClientID: String
    public var soundcloudClientID: String
    public var soundcloudClientSecret: String

    public static let spotifyRedirectURI = "continuity://auth/spotify"
    public static let soundcloudRedirectURI = "continuity://auth/soundcloud"

    public init(spotifyClientID: String = "", googleClientID: String = "", soundcloudClientID: String = "", soundcloudClientSecret: String = "") {
        self.spotifyClientID = spotifyClientID
        self.googleClientID = googleClientID
        self.soundcloudClientID = soundcloudClientID
        self.soundcloudClientSecret = soundcloudClientSecret
    }

    /// `Info.plist` → `ContinuityServiceAuth` → `{SpotifyClientID, GoogleClientID,
    /// SoundCloudClientID, SoundCloudClientSecret}`. Unexpanded `$(VAR)` placeholders (a build
    /// without the setting) count as empty.
    public static func fromBundle(_ bundle: Bundle = .main) -> ServiceAuthConfiguration {
        let dict = bundle.object(forInfoDictionaryKey: "ContinuityServiceAuth") as? [String: Any] ?? [:]
        func value(_ key: String) -> String {
            let raw = (dict[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.hasPrefix("$(") ? "" : raw
        }
        return ServiceAuthConfiguration(
            spotifyClientID: value("SpotifyClientID"),
            googleClientID: value("GoogleClientID"),
            soundcloudClientID: value("SoundCloudClientID"),
            soundcloudClientSecret: value("SoundCloudClientSecret")
        )
    }

    /// The provider preset for one service, with this build's ids filled in.
    public func provider(for service: MusicService) -> OAuthProviderConfig {
        switch service {
        case .spotify:
            return OAuthProviders.spotify(clientID: spotifyClientID, redirectURI: Self.spotifyRedirectURI)
        case .youtube:
            return OAuthProviders.google(clientID: googleClientID)
        case .soundcloud:
            return OAuthProviders.soundcloud(
                clientID: soundcloudClientID,
                clientSecret: soundcloudClientSecret.isEmpty ? nil : soundcloudClientSecret,
                redirectURI: Self.soundcloudRedirectURI
            )
        }
    }

    public func isConfigured(_ service: MusicService) -> Bool {
        provider(for: service).isConfigured
    }
}
