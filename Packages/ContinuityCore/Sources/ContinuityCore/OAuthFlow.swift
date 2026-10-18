import Foundation

/// Everything one OAuth 2 provider needs for the Authorization Code + PKCE flow. Pure data;
/// `OAuthProviders` holds the per-service presets and the Ingest layer supplies the client ids.
public struct OAuthProviderConfig: Equatable, Sendable {
    public var service: MusicService
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var clientID: String
    /// Only providers that still demand a secret on the token exchange (SoundCloud). A shipped
    /// secret is a known trade-off; PKCE providers leave this nil.
    public var clientSecret: String?
    public var redirectURI: String
    public var scopes: [String]
    public var extraAuthorizationParameters: [String: String]

    public init(
        service: MusicService,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        clientID: String,
        clientSecret: String? = nil,
        redirectURI: String,
        scopes: [String],
        extraAuthorizationParameters: [String: String] = [:]
    ) {
        self.service = service
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.extraAuthorizationParameters = extraAuthorizationParameters
    }

    /// The custom scheme `ASWebAuthenticationSession` must intercept (`continuity` for
    /// `continuity://auth/spotify`, the reversed client id for Google).
    public var callbackScheme: String? {
        URLComponents(string: redirectURI)?.scheme
    }

    /// A config whose client id was never filled in can't start a flow — the UI shows "set up".
    public var isConfigured: Bool { !clientID.isEmpty }
}

/// Access + refresh tokens for one connected account. Stored in the Keychain by the Ingest layer.
public struct ServiceCredentials: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scope: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    public init(_ response: OAuthFlow.TokenResponse, now: Date = Date()) {
        self.init(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: response.expiresIn.map { now.addingTimeInterval($0) },
            scope: response.scope
        )
    }

    /// Whether the access token is (about to be) stale. Tokens without an expiry are trusted
    /// until the API rejects them.
    public func isExpiring(within leeway: TimeInterval = 60, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= leeway
    }

    /// Applies a refresh response. Providers may omit the refresh token on refresh (Google
    /// always, Spotify sometimes) — the old one stays valid, so it is kept.
    public func refreshed(with response: OAuthFlow.TokenResponse, now: Date = Date()) -> ServiceCredentials {
        ServiceCredentials(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            expiresAt: response.expiresIn.map { now.addingTimeInterval($0) },
            scope: response.scope ?? scope
        )
    }
}

/// Pure Authorization Code + PKCE mechanics: verifier/challenge, authorize URL, callback
/// parsing, token request bodies and token response parsing. No networking, no Keychain, no
/// crypto of its own — SHA-256 is injected so this stays Linux-testable without CryptoKit.
public enum OAuthFlow {

    public struct TokenResponse: Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresIn: TimeInterval?
        public var scope: String?

        public init(accessToken: String, refreshToken: String? = nil, expiresIn: TimeInterval? = nil, scope: String? = nil) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresIn = expiresIn
            self.scope = scope
        }
    }

    public enum CallbackError: Error, Equatable, Sendable {
        /// The provider reported an error (`error=access_denied`, …).
        case providerError(String)
        /// `state` didn't round-trip — a forged or stale redirect.
        case stateMismatch
        case missingCode
    }

    /// RFC 7636 unreserved alphabet.
    private static let verifierAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// A fresh 64-character code verifier (RFC 7636 allows 43–128). Also used for `state`.
    public static func makeVerifier(length: Int = 64) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in verifierAlphabet.randomElement(using: &generator)! })
    }

    /// `S256` challenge: base64url(SHA-256(verifier)) with no padding.
    public static func challenge(verifier: String, sha256: (Data) -> Data) -> String {
        base64URL(sha256(Data(verifier.utf8)))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The URL to open in the auth session.
    public static func authorizationURL(config: OAuthProviderConfig, state: String, challenge: String) -> URL? {
        guard var comps = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false) else { return nil }
        var items = comps.queryItems ?? []
        items += [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if !config.scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")))
        }
        for (name, value) in config.extraAuthorizationParameters.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: name, value: value))
        }
        comps.queryItems = items
        return comps.url
    }

    /// Extracts the authorization code from the redirect, verifying `state`.
    public static func parseCallback(_ url: URL, expectedState: String) throws -> String {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Some providers put the parameters in the fragment; accept either.
        var items = comps?.queryItems ?? []
        if items.isEmpty, let fragment = comps?.fragment, let fragmentComps = URLComponents(string: "?" + fragment) {
            items = fragmentComps.queryItems ?? []
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            throw CallbackError.providerError(value("error_description") ?? error)
        }
        guard value("state") == expectedState else { throw CallbackError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw CallbackError.missingCode }
        return code
    }

    /// `application/x-www-form-urlencoded` body for the code → token exchange.
    public static func tokenRequestBody(config: OAuthProviderConfig, code: String, verifier: String) -> Data {
        var fields = [
            "grant_type": "authorization_code",
            "client_id": config.clientID,
            "code": code,
            "redirect_uri": config.redirectURI,
            "code_verifier": verifier,
        ]
        if let secret = config.clientSecret, !secret.isEmpty { fields["client_secret"] = secret }
        return Data(formEncode(fields).utf8)
    }

    /// Body for a refresh-token grant.
    public static func refreshRequestBody(config: OAuthProviderConfig, refreshToken: String) -> Data {
        var fields = [
            "grant_type": "refresh_token",
            "client_id": config.clientID,
            "refresh_token": refreshToken,
        ]
        if let secret = config.clientSecret, !secret.isEmpty { fields["client_secret"] = secret }
        return Data(formEncode(fields).utf8)
    }

    /// Parses a token endpoint reply; nil when there's no `access_token`.
    public static func parseTokenResponse(_ data: Data) -> TokenResponse? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = dict["access_token"] as? String, !accessToken.isEmpty else { return nil }
        let expires: TimeInterval?
        if let number = dict["expires_in"] as? NSNumber {
            expires = number.doubleValue
        } else if let string = dict["expires_in"] as? String, let seconds = Double(string) {
            expires = seconds
        } else {
            expires = nil
        }
        return TokenResponse(
            accessToken: accessToken,
            refreshToken: dict["refresh_token"] as? String,
            expiresIn: expires,
            scope: dict["scope"] as? String
        )
    }

    /// Form-encodes with the `application/x-www-form-urlencoded` rules (space → `+`, reserved
    /// characters escaped). Keys are sorted so bodies are deterministic for tests.
    public static func formEncode(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }
            .map { "\(formEscape($0.key))=\(formEscape($0.value))" }
            .joined(separator: "&")
    }

    private static let formAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._*")
        return set
    }()

    private static func formEscape(_ value: String) -> String {
        (value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value)
            .replacingOccurrences(of: "%20", with: "+")
    }
}

/// Per-service OAuth presets. Client ids come from the app's configuration (Info.plist keys set
/// from build settings) — empty ids mean "not set up", and the UI says so instead of failing.
public enum OAuthProviders {

    /// Spotify Authorization Code + PKCE. Public client — no secret.
    public static func spotify(clientID: String, redirectURI: String) -> OAuthProviderConfig {
        OAuthProviderConfig(
            service: .spotify,
            authorizationEndpoint: URL(string: "https://accounts.spotify.com/authorize")!,
            tokenEndpoint: URL(string: "https://accounts.spotify.com/api/token")!,
            clientID: clientID,
            redirectURI: redirectURI,
            scopes: ["playlist-read-private", "playlist-read-collaborative", "user-library-read"]
        )
    }

    /// Google (YouTube Data API) installed-app flow. iOS clients must redirect to the reversed
    /// client id scheme, which is derived here so only the id has to be configured.
    public static func google(clientID: String) -> OAuthProviderConfig {
        OAuthProviderConfig(
            service: .youtube,
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            clientID: clientID,
            redirectURI: googleRedirectURI(clientID: clientID),
            scopes: ["https://www.googleapis.com/auth/youtube.readonly"],
            extraAuthorizationParameters: ["access_type": "offline"]
        )
    }

    /// `1234-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.1234-abc:/oauth2redirect`.
    public static func googleRedirectURI(clientID: String) -> String {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return "" }
        let id = String(clientID.dropLast(suffix.count))
        return "com.googleusercontent.apps.\(id):/oauth2redirect"
    }

    /// SoundCloud Authorization Code + PKCE. SoundCloud still requires the client secret on the
    /// token exchange, so it's part of the configuration.
    public static func soundcloud(clientID: String, clientSecret: String?, redirectURI: String) -> OAuthProviderConfig {
        OAuthProviderConfig(
            service: .soundcloud,
            authorizationEndpoint: URL(string: "https://secure.soundcloud.com/authorize")!,
            tokenEndpoint: URL(string: "https://secure.soundcloud.com/oauth/token")!,
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI,
            scopes: []
        )
    }
}
